import ArgumentParser
import Foundation
import Testing

@testable import BlueTickerCore

/// TickerDev（開発用 CLI）配線の仕様: サブコマンド登録・引数パース・デフォルト値。
/// run() のサービス呼び出し・ネットワークには踏み込まない。
@Suite struct CLIWiringTests {

    // MARK: - サブコマンド登録

    @Test func devRootRegistersAllDocumentedSubcommands() {
        let names = Set(DevCLIEntry.configuration.subcommands.compactMap { $0.configuration.commandName })
        let expected: Set = [
            "search", "waterfall", "summary", "cache", "filings", "filing", "breakdown", "statement",
            "statement-feasibility",
        ]
        #expect(names == expected)
    }

    @Test func cacheWithoutSubcommandDefaultsToStatus() throws {
        let cmd = try DevCLIEntry.parseAsRoot(["cache"])
        #expect(cmd is CacheStatus)
    }

    @Test func parsingWaterfallFromDevRootDispatchesToDevWaterfallCommand() throws {
        let parsed = try DevCLIEntry.parseAsRoot(["waterfall", "7203"])
        let cmd = try #require(parsed as? DevWaterfallCommand)
        #expect(cmd.code == "7203")
    }

    @Test func parsingSearchFromDevRootDispatchesToDevSearchCommandWithQuery() throws {
        let parsed = try DevCLIEntry.parseAsRoot(["search", "トヨタ"])
        let cmd = try #require(parsed as? DevSearchCommand)
        #expect(cmd.query == "トヨタ")
    }

    // MARK: - Dev waterfall の引数パース

    @Test func devWaterfallDefaultsFlagsAreOff() throws {
        let cmd = try DevWaterfallCommand.parse(["7203"])
        #expect(!cmd.json)
    }

    @Test func devWaterfallParsesLongOptionsAndFlags() throws {
        let cmd = try DevWaterfallCommand.parse(["7203", "--json", "--years", "4"])
        #expect(cmd.json)
        #expect(cmd.years == 4)
    }

    @Test func devWaterfallWithoutCodeFailsToParse() {
        #expect(throws: (any Error).self) {
            _ = try DevWaterfallCommand.parse([])
        }
    }

    // MARK: - Dev filings / filing

    @Test func devFilingsDefaultsMatchApiConstants() throws {
        let cmd = try DevFilingsCommand.parse(["7203"])
        #expect(cmd.years == Api.filingsDefaultYears)
        #expect(!cmd.json)
    }

    @Test func devFilingParsesMultipleSectionsUpToNextOption() throws {
        let cmd = try DevFilingCommand.parse(["7203", "--sections", "mda", "segments", "--json"])
        #expect(cmd.sections == ["mda", "segments"])
        #expect(cmd.json)
        #expect(cmd.docId == nil)
    }

    @Test func devFilingParsesDocIdOption() throws {
        let cmd = try DevFilingCommand.parse(["7203", "--doc-id", "S100ABC1"])
        #expect(cmd.docId == "S100ABC1")
        #expect(cmd.sections.isEmpty)
    }

    /// ヘルプテキストに列挙している全セクションキーが実際のバリデーション集合に存在する
    /// （ヘルプと実装のドリフト検知）。
    @Test func documentedSectionKeysAreAllAccepted() {
        let valid = Set(xbrlSections.keys).union(BreakdownExtractor.specialSectionKeys)
        let documented: Set = [
            "business_risks", "mda", "capex_overview", "major_facilities",
            "facility_plans", "research_and_development", "segments", "geography",
            "management_policy",
        ]
        #expect(documented.isSubset(of: valid))
    }

    /// 不明なセクション指定はネットワーク・バックエンド解決に入る前に失敗する。
    @Test func devFilingRunRejectsUnknownSectionBeforeAnyFetch() async throws {
        let cmd = try DevFilingCommand.parse(["7203", "--sections", "bogus_section"])
        await #expect(throws: ExitCode.failure) {
            try await cmd.run()
        }
    }

    // MARK: - cache clean

    @Test func cacheCleanParsesRetentionOptionsAndDryRun() throws {
        let cmd = try CacheClean.parse([
            "--dry-run",
            "--edinet-search-days", "30",
            "--edinet-xbrl-days", "90",
            "--edinet-doc-index-years", "0",
        ])
        #expect(cmd.dryRun)
        #expect(cmd.edinetSearchDays == 30)
        #expect(cmd.edinetXbrlDays == 90)
        #expect(cmd.edinetDocIndexYears == 0)
    }

    @Test func cacheCleanRetentionOptionsDefaultToNilAndKeepYearsConstant() throws {
        let cmd = try CacheClean.parse([])
        #expect(!cmd.dryRun)
        #expect(cmd.edinetSearchDays == nil)
        #expect(cmd.edinetXbrlDays == nil)
        #expect(cmd.edinetDocIndexYears == Api.documentIndexKeepYears)
    }

    // MARK: - 表示列ラベル（waterfall / summary の列見出し）

    private func entry(fyEnd: String?, perType: String? = nil) -> YearEntry {
        var raw = RawData()
        raw.curPerType = perType
        return YearEntry(fyEnd: fyEnd, financialPeriod: "", rawData: raw, calculatedData: CalculatedData())
    }

    @Test func yearColumnLabelFormatsFiscalYearEndAsTwoDigitYearSlashMonth() {
        #expect(MetricsTable.yearColumnLabel(entry(fyEnd: "2023-03-31")) == "23/03")
    }

    @Test func yearColumnLabelAppends2QMarkerForInterimPeriod() {
        #expect(MetricsTable.yearColumnLabel(entry(fyEnd: "2024-09-30", perType: "2Q")) == "24/09(2Q)")
    }

    @Test func yearColumnLabelFallsBackWhenFyEndIsMissing() {
        #expect(MetricsTable.yearColumnLabel(entry(fyEnd: nil)) == "不明")
    }
}
