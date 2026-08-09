// 外出し SPEC_ORACLE フォーマットの試作（docs/test-spec-assets.md の C、2026-08-09）。
//
// borrowings_schedule note_type を対象に、期待値を Swift コード中のハードコード値ではなく
// `smoke/statement_notes_borrowings_schedule_expected.json` へ外出しし、実装（Swift）を消しても
// 仕様（期待JSON）だけで合否が書けることを確認する試作。比較は resolver の出力を REST/MCP と
// 同じ snake_case JSON（`BorrowingsComponentPayload.jsonObject()`）へ変換したうえで、期待JSONと
// バイト単位（正規化キー順）で突き合わせる。これにより期待値の形は公開契約（statement-notes
// REST/MCP レスポンス）とも一致し、L0 資産として言語非依存に持ち運べる。
//
// `content_hash` は開示HTMLから決定的に導出される値で「仕様」ではないため、期待JSONには含めない。
//
// これは1 note_type分の試作であり、`RealXbrlStatementNotesTests.swift` の既存ハードコード golden
// テストを置き換えるものではない（docID・実データ検証の来歴コメントは移行元にそのまま残る）。
// フォーマットが定着すれば、他 note_type・他ロジックへの本移行は別途判断する。
//
// 対象docIDは fixture 内の3件（S100JRT9・S100R1LR・S100YHZG）のみ。他ファイルの `cacheAvailable`
// 慣習に合わせ、docID ごとに個別 `@Test` + `.enabled(if:)` でキャッシュ無しを静かに SKIP する
// （CI にキャッシュが無い場合でも赤くならない。ループ1本＋「1件も無ければ Issue.record」構成は
// キャッシュ皆無の CI 実行を毎回失敗させてしまうため採用しなかった）。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct StatementNotesOracleFormatTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func cacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: xbrlDir(docID).path)
    }

    private static let expectedFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("smoke/statement_notes_borrowings_schedule_expected.json")

    private static func loadExpectedEntry(docID: String) throws -> [String: Any] {
        let data = try Data(contentsOf: expectedFileURL)
        let raw = try JSONSerialization.jsonObject(with: data)
        let all = try #require(raw as? [String: [String: Any]])
        return try #require(all[docID])
    }

    private static func canonicalJSON(_ obj: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    private func assertMatchesOracle(docID: String) throws {
        let expectedEntry = try Self.loadExpectedEntry(docID: docID)
        let result = StatementNotesResolver.resolveBorrowingsSchedule(xbrlDir: Self.xbrlDir(docID))
        guard case .resolved(let payload, let source, _) = result else {
            Issue.record("docID=\(docID): expected .resolved, got \(result)")
            return
        }

        #expect(source == (expectedEntry["source"] as? String))

        let actualComponents = payload.borrowingsComponents?.map { $0.jsonObject() } ?? []
        let expectedComponents = expectedEntry["components"] as? [[String: Any]] ?? []
        let actualJSON = try Self.canonicalJSON(actualComponents)
        let expectedJSON = try Self.canonicalJSON(expectedComponents)
        #expect(actualJSON == expectedJSON)
    }

    // MARK: - S100JRT9（リース負債のみの明細表・千円単位）

    @Test(.enabled(if: cacheAvailable("S100JRT9"), "XBRL cache S100JRT9 not available"))
    func borrowingsScheduleMatchesExternalizedOracleLeaseOnly() throws {
        try assertMatchesOracle(docID: "S100JRT9")
    }

    // MARK: - S100R1LR（SOMPO、平均利率・百万円単位）

    @Test(.enabled(if: cacheAvailable("S100R1LR"), "XBRL cache S100R1LR not available"))
    func borrowingsScheduleMatchesExternalizedOracleWithInterestRates() throws {
        try assertMatchesOracle(docID: "S100R1LR")
    }

    // MARK: - S100YHZG（三菱重工業、自社拡張タグ・非借入項目を含む全体構造化）

    @Test(.enabled(if: cacheAvailable("S100YHZG"), "XBRL cache S100YHZG not available"))
    func borrowingsScheduleMatchesExternalizedOracleCompanySpecificTags() throws {
        try assertMatchesOracle(docID: "S100YHZG")
    }
}
