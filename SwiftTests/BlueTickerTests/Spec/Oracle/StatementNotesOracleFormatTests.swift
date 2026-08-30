// 外出し SPEC_ORACLE フォーマット（.agents/skills/xbrl-development/SKILL.md、2026-08-09）。
//
// borrowings_schedule note_type を対象に、期待値を Swift コード中のハードコード値ではなく
// `smoke/statement_notes_borrowings_schedule_expected.json` へ外出しし、実装（Swift）を消しても
// 仕様（期待JSON）だけで合否が書けることを確認する。比較は resolver の出力を REST/MCP と
// 同じ snake_case JSON（`BorrowingsComponentPayload.jsonObject()`）へ変換したうえで、期待JSONと
// バイト単位（正規化キー順）で突き合わせる。これにより期待値の形は公開契約（statement-notes
// REST/MCP レスポンス）とも一致し、L0 資産として言語非依存に持ち運べる。
//
// `content_hash` は開示HTMLから決定的に導出される値で「仕様」ではないため、期待JSONには含めない。
//
// `RealXbrlStatementNotesTests.swift` の既存ハードコード golden テストを置き換えるものではない
// （docID・実データ検証の来歴コメントは移行元にそのまま残る）。フォーマットが定着すれば、
// 他 note_type・他ロジックへの本移行は別途判断する。
//
// 対象:
// - 試作3件（S100JRT9・S100R1LR・S100YHZG）: analysis_cache 経路（従来どおり）
// - smoke 固定11社: SmokeCacheSupport（`tmp_cache/edinet`）経路。年次スモークの次元床に
//   borrowings_schedule を載せる（2026-08-09）。US-GAAP 2社は巨大注記 HTML から内訳を取る
//   （2026-08-12。附属明細表タグはクロスリファレンスのみ）。
//
// 他ファイルの `cacheAvailable` 慣習に合わせ、docID ごとに個別 `@Test` + `.enabled(if:)` で
// キャッシュ無しを静かに SKIP する（CI にキャッシュが無い場合でも赤くならない）。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct StatementNotesOracleFormatTests {
    private static func analysisXbrlDir(_ docID: String) -> URL {
        StatementNotesOracleSupport.analysisXbrlDir(docID)
    }

    private static func analysisCacheAvailable(_ docID: String) -> Bool {
        StatementNotesOracleSupport.analysisCacheAvailable(docID)
    }

    private static let expectedFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("smoke/statement_notes_borrowings_schedule_expected.json")

    private func assertMatchesOracle(docID: String, xbrlDir: URL) throws {
        let result = StatementNotesResolver.resolveBorrowingsSchedule(xbrlDir: xbrlDir)
        let items: [[String: Any]]?
        if case .resolved(let payload, _, _) = result {
            items = payload.borrowingsComponents?.map { $0.jsonObject() }
        } else {
            items = nil
        }
        try StatementNotesOracleSupport.assertMatchesOracle(
            docID: docID, expectedFileURL: Self.expectedFileURL, result: result,
            itemsKey: "components", items: items)
    }

    /// smoke 床: 鍵があれば不足分を取得し、それでも無ければ静かに SKIP（SmokeTests と同型）。
    private func withSmokeCache(_ docID: String, _ body: (URL) throws -> Void) async throws {
        try await StatementNotesOracleSupport.withSmokeCache(docID, body)
    }

    // MARK: - 試作3件（analysis_cache）

    // MARK: - S100JRT9（リース負債のみの明細表・千円単位）

    @Test(.enabled(if: analysisCacheAvailable("S100JRT9"), "XBRL cache S100JRT9 not available"))
    func borrowingsScheduleMatchesExternalizedOracleLeaseOnly() throws {
        try assertMatchesOracle(docID: "S100JRT9", xbrlDir: Self.analysisXbrlDir("S100JRT9"))
    }

    // MARK: - S100R1LR（SOMPO、平均利率・百万円単位）

    @Test(.enabled(if: analysisCacheAvailable("S100R1LR"), "XBRL cache S100R1LR not available"))
    func borrowingsScheduleMatchesExternalizedOracleWithInterestRates() throws {
        try assertMatchesOracle(docID: "S100R1LR", xbrlDir: Self.analysisXbrlDir("S100R1LR"))
    }

    // MARK: - S100YHZG（三菱重工業、自社拡張タグ・非借入項目を含む全体構造化）

    @Test(.enabled(if: analysisCacheAvailable("S100YHZG"), "XBRL cache S100YHZG not available"))
    func borrowingsScheduleMatchesExternalizedOracleCompanySpecificTags() throws {
        try assertMatchesOracle(docID: "S100YHZG", xbrlDir: Self.analysisXbrlDir("S100YHZG"))
    }

    // MARK: - smoke 床11社（tmp_cache / SmokeCacheSupport）

    @Test
    func smokeBorrowingsAjinomotoMatchesOracle() async throws {
        try await withSmokeCache("S100VXJA") {
            try assertMatchesOracle(docID: "S100VXJA", xbrlDir: $0)
        }
    }

    @Test
    func smokeBorrowingsNichireiMatchesOracle() async throws {
        try await withSmokeCache("S100VYA0") {
            try assertMatchesOracle(docID: "S100VYA0", xbrlDir: $0)
        }
    }

    @Test
    func smokeBorrowingsAZplanningMatchesOracle() async throws {
        try await withSmokeCache("S100VU4O") {
            try assertMatchesOracle(docID: "S100VU4O", xbrlDir: $0)
        }
    }

    @Test
    func smokeBorrowingsFujifilmMatchesOracle() async throws {
        try await withSmokeCache("S100W3XJ") {
            try assertMatchesOracle(docID: "S100W3XJ", xbrlDir: $0)
        }
    }

    @Test
    func smokeBorrowingsOkumaMatchesOracle() async throws {
        try await withSmokeCache("S100W043") {
            try assertMatchesOracle(docID: "S100W043", xbrlDir: $0)
        }
    }

    @Test
    func smokeBorrowingsKubotaMatchesOracle() async throws {
        try await withSmokeCache("S100XR0M") {
            try assertMatchesOracle(docID: "S100XR0M", xbrlDir: $0)
        }
    }

    @Test
    func smokeBorrowingsSuzukiMatchesOracle() async throws {
        try await withSmokeCache("S100W4MT") {
            try assertMatchesOracle(docID: "S100W4MT", xbrlDir: $0)
        }
    }

    @Test
    func smokeBorrowingsTohoRemacMatchesOracle() async throws {
        try await withSmokeCache("S100XRD8") {
            try assertMatchesOracle(docID: "S100XRD8", xbrlDir: $0)
        }
    }

    @Test
    func smokeBorrowingsCanonMatchesOracle() async throws {
        try await withSmokeCache("S100XTLJ") {
            try assertMatchesOracle(docID: "S100XTLJ", xbrlDir: $0)
        }
    }

    @Test
    func smokeBorrowingsMUFGMatchesOracle() async throws {
        try await withSmokeCache("S100W4FB") {
            try assertMatchesOracle(docID: "S100W4FB", xbrlDir: $0)
        }
    }

    @Test
    func smokeBorrowingsSMFGMatchesOracle() async throws {
        try await withSmokeCache("S100W0S7") {
            try assertMatchesOracle(docID: "S100W0S7", xbrlDir: $0)
        }
    }
}
