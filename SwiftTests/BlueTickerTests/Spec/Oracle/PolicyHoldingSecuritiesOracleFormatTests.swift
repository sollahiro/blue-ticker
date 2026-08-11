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
// 有価証券報告書には提出履歴上3つのdocIDが存在する: 原本S100W0S7（2025-06-20、構造化タグ13/70件のみで
// 大幅に不完全）、訂正報告書①S100WRZH（2025-09-30、70/70件で完全）、訂正報告書②S100X7DX
// （2025-11-28、EDINET上「最新」だが13/70件に後退・再発）。`SmokeTests.swift`のBS/PL/CF等のdocID
// マッピングは`8316_2025-03-31`→S100W0S7（本note_type以外では問題なし）だが、実際のingest（本番
// パイプライン）がこの3docIDのうちどれを最終的に採用するかは`EdinetDiscovery`側のロジックに依存し、
// 本PRでは調査・変更していない。S100WRZHは実データとして完全ではあるが、smoke固定11社の趣旨
// （実際にingestされる文書に対する回帰ガード）とは無関係に人為的に選んだ「都合の良いdocID」に
// なってしまうため、smoke床には含めない（S100WRZH・S100X7DXいずれもsmoke対象外。本note_typeの
// resolverロジック自体はどのdocIDのXBRLを渡されても同一であり、本PRはこのロジックとテストファイル
// のみを変更する。ingestの実際のdocID選定ロジックには一切手を入れていない）。前々期(S100TPKY)・
// 最新期(S100YERK)の原本はいずれも完全なため、三井住友FG固有の恒常的な問題ではなくS100W0S7・
// S100X7DXの2文書に限定された欠損と判断している。将来的にsmokeへ追加する場合は、ingestが実際に
// 採用するdocIDを確認したうえで、その文書の実データ（欠損があればそれを含めた形）で追加する必要が
// ある。

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
