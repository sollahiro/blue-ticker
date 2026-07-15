import ArgumentParser
import Foundation
import Testing

@testable import BlueTickerCore

/// CLI 配線の仕様: サブコマンド登録・引数パース・デフォルト値・実行前バリデーション。
/// run() のサービス呼び出し・ネットワークには踏み込まない（ロジックは Services/Analysis 層のテストが担う）。
@Suite struct CLIWiringTests {

    // MARK: - サブコマンド登録

    @Test func rootRegistersAllDocumentedSubcommands() {
        let names = Set(Ticker.configuration.subcommands.compactMap { $0.configuration.commandName })
        let expected: Set = [
            "search", "analyze", "summarize", "config", "login",
            "filings", "filing", "sector", "skill",
        ]
        #expect(names == expected)
    }

    /// TickerDev（配布しない開発用ローカル解析 CLI）側のサブコマンド登録。
    @Test func devRootRegistersAllDocumentedSubcommands() {
        let names = Set(DevCLIEntry.configuration.subcommands.compactMap { $0.configuration.commandName })
        let expected: Set = ["search", "analyze", "summarize", "cache", "filings", "filing"]
        #expect(names == expected)
    }

    @Test func parsingAnalyzeFromRootDispatchesToAnalyzeCommand() throws {
        let parsed = try Ticker.parseAsRoot(["analyze", "7203"])
        let cmd = try #require(parsed as? AnalyzeCommand)
        #expect(cmd.code == "7203")
    }

    @Test func parsingSearchFromRootDispatchesToSearchCommandWithQuery() throws {
        let parsed = try Ticker.parseAsRoot(["search", "トヨタ"])
        let cmd = try #require(parsed as? SearchCommand)
        #expect(cmd.query == "トヨタ")
    }

    @Test func cacheWithoutSubcommandDefaultsToStatus() throws {
        let cmd = try DevCLIEntry.parseAsRoot(["cache"])
        #expect(cmd is CacheStatus)
    }

    // MARK: - analyze の引数パース

    @Test func analyzeDefaultsMatchApiConstantsAndFlagsAreOff() throws {
        let cmd = try AnalyzeCommand.parse(["7203"])
        #expect(cmd.years == Api.analyzeDefaultYears)
        #expect(!cmd.json)
        #expect(!cmd.half)
    }

    @Test func analyzeParsesLongOptionsAndFlags() throws {
        let cmd = try AnalyzeCommand.parse(["7203", "--years", "3", "--json", "--half"])
        #expect(cmd.years == 3)
        #expect(cmd.json)
        #expect(cmd.half)
    }

    @Test func analyzeAcceptsShortYearsOption() throws {
        let cmd = try AnalyzeCommand.parse(["7203", "-y", "4"])
        #expect(cmd.years == 4)
    }

    @Test func analyzeWithoutCodeFailsToParse() {
        #expect(throws: (any Error).self) {
            _ = try AnalyzeCommand.parse([])
        }
    }

    // MARK: - filings / filing の引数パース

    @Test func filingsDefaultsMatchApiConstants() throws {
        let cmd = try FilingsCommand.parse(["7203"])
        #expect(cmd.years == Api.filingsDefaultYears)
        #expect(!cmd.json)
    }

    @Test func filingParsesMultipleSectionsUpToNextOption() throws {
        let cmd = try FilingCommand.parse(["7203", "--sections", "mda", "segments", "--json"])
        #expect(cmd.sections == ["mda", "segments"])
        #expect(cmd.json)
        #expect(cmd.docId == nil)
    }

    @Test func filingParsesDocIdOption() throws {
        let cmd = try FilingCommand.parse(["7203", "--doc-id", "S100ABC1"])
        #expect(cmd.docId == "S100ABC1")
        #expect(cmd.sections.isEmpty)
    }

    /// ヘルプテキストに列挙している全セクションキーが実際のバリデーション集合に存在する
    /// （ヘルプと実装のドリフト検知）。
    @Test func documentedSectionKeysAreAllAccepted() {
        let valid = Set(xbrlSections.keys).union(SegmentExtractor.specialSectionKeys)
        let documented: Set = [
            "business_risks", "mda", "capex_overview", "major_facilities",
            "facility_plans", "research_and_development", "segments", "geography",
            "management_policy",
        ]
        #expect(documented.isSubset(of: valid))
    }

    /// 不明なセクション指定はネットワーク・バックエンド解決に入る前に失敗する。
    @Test func filingRunRejectsUnknownSectionBeforeAnyFetch() async throws {
        let cmd = try FilingCommand.parse(["7203", "--sections", "bogus_section"])
        await #expect(throws: ExitCode.failure) {
            try await cmd.run()
        }
    }

    // MARK: - cache clean / config set の引数パース

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

    @Test func configSetParsesServerUrlOption() throws {
        let cmd = try ConfigSet.parse(["--server-url", "https://example.com"])
        #expect(cmd.serverUrl == "https://example.com")
    }

    // MARK: - 表示列ラベル（analyze / summarize の列見出し）

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
