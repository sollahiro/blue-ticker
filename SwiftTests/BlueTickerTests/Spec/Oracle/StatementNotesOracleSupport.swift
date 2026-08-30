// 財務諸表注記取り込み: 外出しoracle JSON突合テスト（`.agents/skills/xbrl-development/SKILL.md` の SPEC_ORACLE）の
// note_type共通ヘルパー。`StatementNotesOracleFormatTests.swift`（borrowings_schedule、最初の導入）と
// 同じ経路・比較方式を他note_typeにも展開する際の重複を避けるため切り出した。
//
// note_typeごとの差分は「どのresolverを呼ぶか」「payloadのどのフィールドを`.jsonObject()`で配列化するか」
// だけなので、キャッシュパス解決・canonicalJSON比較・期待値ロード・突合ロジック自体はここに集約する。

import Foundation
import Testing
@testable import BlueTickerCore

enum StatementNotesOracleSupport {
    static let analysisXbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    static func analysisXbrlDir(_ docID: String) -> URL {
        analysisXbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    static func smokeXbrlDir(_ docID: String) -> URL {
        SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
    }

    static func analysisCacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: analysisXbrlDir(docID).path)
    }

    static func smokeCacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: smokeXbrlDir(docID).path)
    }

    static func canonicalJSON(_ obj: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    static func loadExpectedEntry(fileURL: URL, docID: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fileURL)
        let raw = try JSONSerialization.jsonObject(with: data)
        let all = try #require(raw as? [String: [String: Any]])
        return try #require(all[docID])
    }

    /// smoke 床: 鍵があれば不足分を取得し、それでも無ければ静かに SKIP（`SmokeTests` と同型）。
    static func withSmokeCache(_ docID: String, _ body: (URL) throws -> Void) async throws {
        await SmokeCacheSupport.ensureCached([docID])
        guard smokeCacheAvailable(docID) else { return }
        try body(smokeXbrlDir(docID))
    }

    /// note_type共通のoracle突合。`itemsKey`は期待JSON内の配列キー名（例:
    /// "components"/"items"/"securities"/"dividend_events"）。`content_hash`は開示HTMLから決定的に
    /// 導出される値で「仕様」ではないため期待JSONには含めない（比較対象外）。
    static func assertMatchesOracle(
        docID: String, expectedFileURL: URL, result: StatementNoteResolveResult,
        itemsKey: String, items: [[String: Any]]?
    ) throws {
        let expectedEntry = try loadExpectedEntry(fileURL: expectedFileURL, docID: docID)

        let status = expectedEntry["status"] as? String
        if status == "not_applicable" {
            let expectedReason = try #require(expectedEntry["reason"] as? String)
            guard case .notApplicable(let reason) = result else {
                Issue.record("docID=\(docID): expected .notApplicable(\(expectedReason)), got \(result)")
                return
            }
            #expect(reason == expectedReason)
            return
        }

        guard case .resolved(_, let source, _) = result else {
            Issue.record("docID=\(docID): expected .resolved, got \(result)")
            return
        }

        #expect(source == (expectedEntry["source"] as? String))

        let actualItems = items ?? []
        let expectedItems = expectedEntry[itemsKey] as? [[String: Any]] ?? []
        // 両者が偶然空配列同士で一致してしまう（比較が空振りする）ことを防ぐ。
        #expect(!expectedItems.isEmpty)
        let actualJSON = try canonicalJSON(actualItems)
        let expectedJSON = try canonicalJSON(expectedItems)
        #expect(actualJSON == expectedJSON)
    }
}
