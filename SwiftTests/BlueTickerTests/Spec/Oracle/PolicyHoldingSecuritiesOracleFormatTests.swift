// 外出し SPEC_ORACLE フォーマット（`StatementNotesOracleFormatTests.swift`=borrowings_schedule と同型、
// 2026-08-11 note_type横展開）。
//
// 期待値はトヨタ自動車(S100VWVY)についてresolverを実際に実行した出力をそのまま外出ししたもの。
// `RealXbrlStatementNotesTests.swift`の既存golden（goldenSecuritiesToyota）はissuer_name/
// number_of_shares/carrying_amountのみをスポットチェックしており（purposeは未検証）、本ファイルの
// 期待値もその値と完全一致することを確認済み。purposeを含む全フィールドはresolver出力をそのまま
// 採用しており、新規の実データレビュー（開示HTMLとの再照合）は行っていない。
//
// 他社（S100L0TZ・S100VW4E・S100QXRZ・S100R218・S100VGBM）はこのマシンにキャッシュが無く、
// スポットチェックのみのgoldenのため安全に転記できず今回は見送り。キャッシュが揃い次第追加する。
//
// **みなし保有株式（DeemedHoldings）タグ対応（2026-08-11 追加）**: 特定投資株式に加えてみなし保有株式
// （退職給付信託等、議決権行使を指図する権限のみ保有するケース）も同一securities配列に
// `is_deemed_holding` フラグ付きで連結するようになった。トヨタは43->61件（みなし保有18件追加）に
// 期待値が変化している（`RealXbrlStatementNotesTests.goldenSecuritiesToyota` も同時に更新済み）。
//
// **smoke固定11社のうちSMFG(8316)は本note_typeでは除外（10社のみ）**: 三井住友FGの2025年3月期
// 有価証券報告書には提出履歴上、原本S100W0S7（2025-06-20、構造化タグ13/70件のみで不完全）と
// 全文XBRL訂正S100WRZH（2025-09-30、70/70件）と、同じ親の通常訂正S100X7DX（2025-11-28、
// 13/70件に後退）がある。ingest は identity を S100W0S7 のまま、訂正 130 を提出順に
// fact overlay する（行メンバー表は訂正がその表を含めば行ごと置換。後勝ち）。
// smoke 床は `SmokeTests` と同じ原本 S100W0S7 を渡す経路なので、不完全パッケージの
// 抽出結果を床にしない（対象外のまま）。選定・overlay の回帰は `XbrlAmendmentSourceTests`。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct PolicyHoldingSecuritiesOracleFormatTests {
    private static let expectedFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("smoke/statement_notes_policy_holding_securities_expected.json")

    private func assertMatchesOracle(docID: String, xbrlDir: URL) throws {
        let result = StatementNotesResolver.resolvePolicyHoldingSecurities(xbrlDir: xbrlDir)
        let items: [[String: Any]]?
        var summary: [String: Any]?
        if case .resolved(let payload, _, _) = result {
            items = payload.securities?.map { $0.jsonObject() }
            summary = payload.policyHoldingSummary?.jsonObject()
        } else {
            items = nil
            summary = nil
        }
        try StatementNotesOracleSupport.assertMatchesOracle(
            docID: docID, expectedFileURL: Self.expectedFileURL, result: result,
            itemsKey: "securities", items: items)

        // 銘柄数及び貸借対照表計上額の合計額（`securities`とは別の集計、`assertMatchesOracle`の
        // itemsKey比較の対象外なのでここで個別に比較する）。
        let expectedEntry = try StatementNotesOracleSupport.loadExpectedEntry(
            fileURL: Self.expectedFileURL, docID: docID)
        let expectedSummary = expectedEntry["policy_holding_summary"] as? [String: Any]
        switch (summary, expectedSummary) {
        case (nil, nil):
            break
        case (let actual?, let expected?):
            let actualJSON = try StatementNotesOracleSupport.canonicalJSON(actual)
            let expectedJSON = try StatementNotesOracleSupport.canonicalJSON(expected)
            #expect(actualJSON == expectedJSON)
        default:
            Issue.record("policy_holding_summary mismatch: actual=\(String(describing: summary)) expected=\(String(describing: expectedSummary))")
        }
    }

    private func withSmokeCache(_ docID: String, _ body: (URL) throws -> Void) async throws {
        try await StatementNotesOracleSupport.withSmokeCache(docID, body)
    }

    // MARK: - S100VWVY（トヨタ自動車）

    @Test(.enabled(if: StatementNotesOracleSupport.analysisCacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func securitiesMatchesExternalizedOracleToyota() throws {
        try assertMatchesOracle(docID: "S100VWVY", xbrlDir: StatementNotesOracleSupport.analysisXbrlDir("S100VWVY"))
    }

    // MARK: - smoke 床10社（tmp_cache / SmokeCacheSupport）。SMFG(8316)は対象外（ファイル冒頭コメント参照）。

    @Test
    func smokePolicyHoldingAZplanningMatchesOracle() async throws {
        try await withSmokeCache("S100VU4O") {
            try assertMatchesOracle(docID: "S100VU4O", xbrlDir: $0)
        }
    }

    @Test
    func smokePolicyHoldingAjinomotoMatchesOracle() async throws {
        try await withSmokeCache("S100VXJA") {
            try assertMatchesOracle(docID: "S100VXJA", xbrlDir: $0)
        }
    }

    @Test
    func smokePolicyHoldingNichireiMatchesOracle() async throws {
        try await withSmokeCache("S100VYA0") {
            try assertMatchesOracle(docID: "S100VYA0", xbrlDir: $0)
        }
    }

    @Test
    func smokePolicyHoldingOkumaMatchesOracle() async throws {
        try await withSmokeCache("S100W043") {
            try assertMatchesOracle(docID: "S100W043", xbrlDir: $0)
        }
    }

    // SMFG(8316)はsmoke対象外（ファイル冒頭コメント参照）。

    @Test
    func smokePolicyHoldingFujifilmMatchesOracle() async throws {
        try await withSmokeCache("S100W3XJ") {
            try assertMatchesOracle(docID: "S100W3XJ", xbrlDir: $0)
        }
    }

    @Test
    func smokePolicyHoldingMUFGMatchesOracle() async throws {
        try await withSmokeCache("S100W4FB") {
            try assertMatchesOracle(docID: "S100W4FB", xbrlDir: $0)
        }
    }

    @Test
    func smokePolicyHoldingSuzukiMatchesOracle() async throws {
        try await withSmokeCache("S100W4MT") {
            try assertMatchesOracle(docID: "S100W4MT", xbrlDir: $0)
        }
    }

    @Test
    func smokePolicyHoldingKubotaMatchesOracle() async throws {
        try await withSmokeCache("S100XR0M") {
            try assertMatchesOracle(docID: "S100XR0M", xbrlDir: $0)
        }
    }

    @Test
    func smokePolicyHoldingTohoRemacMatchesOracle() async throws {
        try await withSmokeCache("S100XRD8") {
            try assertMatchesOracle(docID: "S100XRD8", xbrlDir: $0)
        }
    }

    @Test
    func smokePolicyHoldingCanonMatchesOracle() async throws {
        try await withSmokeCache("S100XTLJ") {
            try assertMatchesOracle(docID: "S100XTLJ", xbrlDir: $0)
        }
    }
}
