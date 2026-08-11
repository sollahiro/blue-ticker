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
// **smoke固定11社でのSMFG(8316)のdocID選定について**: 三井住友FGの2025年3月期有価証券報告書には
// 提出履歴上3つのdocIDが存在する: 原本S100W0S7（2025-06-20、構造化タグ13/70件のみで大幅に不完全）、
// 訂正報告書①S100WRZH（2025-09-30、70/70件で完全）、訂正報告書②S100X7DX（2025-11-28、EDINET上
// 「最新」だが13/70件に後退・再発）。前々期(S100TPKY)・最新期(S100YERK)の原本はいずれも完全なため、
// この不完全タグ付けは三井住友FG固有の恒常的な問題ではなく、この2文書（S100W0S7・S100X7DX）に限定
// された欠損と判断した。**本ファイルのsmokeテストはS100WRZHを使用し、S100X7DX（EDINET上の最新訂正）
// は既知の欠損として特例的にsmoke対象から明示的に除外する**（`SmokeTests.swift`のBS/PL/CF等の
// docIDマッピングは`8316_2025-03-31`→S100W0S7のままだが、これは他note_typeでは問題が確認されておらず
// 本note_type固有の対応としてこのファイル内でのみdocIDを差し替える）。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct PolicyHoldingSecuritiesOracleFormatTests {
    private static let expectedFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("smoke/statement_notes_policy_holding_securities_expected.json")

    private func assertMatchesOracle(docID: String, xbrlDir: URL) throws {
        let result = StatementNotesResolver.resolvePolicyHoldingSecurities(xbrlDir: xbrlDir)
        let items: [[String: Any]]?
        if case .resolved(let payload, _, _) = result {
            items = payload.securities?.map { $0.jsonObject() }
        } else {
            items = nil
        }
        try StatementNotesOracleSupport.assertMatchesOracle(
            docID: docID, expectedFileURL: Self.expectedFileURL, result: result,
            itemsKey: "securities", items: items)
    }

    private func withSmokeCache(_ docID: String, _ body: (URL) throws -> Void) async throws {
        try await StatementNotesOracleSupport.withSmokeCache(docID, body)
    }

    // MARK: - S100VWVY（トヨタ自動車）

    @Test(.enabled(if: StatementNotesOracleSupport.analysisCacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func securitiesMatchesExternalizedOracleToyota() throws {
        try assertMatchesOracle(docID: "S100VWVY", xbrlDir: StatementNotesOracleSupport.analysisXbrlDir("S100VWVY"))
    }

    // MARK: - smoke 床11社（tmp_cache / SmokeCacheSupport）。SMFG(8316)はS100WRZH（訂正・完全版）。

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

    @Test
    func smokePolicyHoldingSMFGMatchesOracle() async throws {
        // 原本S100W0S7・最新訂正S100X7DXは構造化タグが大幅に不完全な既知の欠損（ファイル冒頭コメント
        // 参照）のため、完全版の訂正報告書S100WRZHを使用する。
        try await withSmokeCache("S100WRZH") {
            try assertMatchesOracle(docID: "S100WRZH", xbrlDir: $0)
        }
    }

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
