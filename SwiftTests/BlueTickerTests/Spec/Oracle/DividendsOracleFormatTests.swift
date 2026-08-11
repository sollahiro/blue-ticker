// 外出し SPEC_ORACLE フォーマット（`StatementNotesOracleFormatTests.swift`=borrowings_schedule と同型、
// 2026-08-11 note_type横展開）。
//
// S100JRT9（レーザーテック）は`goldenDividendsLaserTec`が`DividendEventPayload`の全4フィールド
// （resolution_date/resolution_body/dividend_per_share/total_amount）を2件のイベント両方について
// スポットチェックしており、既存golden自体が payload を完全に特定している。したがってこのマシンに
// キャッシュが無くても既存golden値からそのまま安全に転記できる（新規の実データレビューではない）。
// S100RX8V（メルカリ、無配当）はnotApplicableでstatus+reasonのみのため同様に安全。
//
// S100R24O（あおぞら銀行）はresolutionBodyが既存goldenでスポットチェックされておらず、
// 安全に転記できないため今回は見送り（キャッシュも無い）。
//
// smoke固定11社（2026-08-11、capexと同日に横展開）: `DateOfResolutionDividendsOfSurplus`・
// `ResolutionDividendsOfSurplus`・`DividendPerShareDividendsOfSurplus`・
// `TotalAmountOfDividendsDividendsOfSurplus` の生タグ値をtmp_cache/edinet直読みで11社すべて
// 目視確認し、resolver出力と完全一致することを確認済み（決議日・決議機関・1株配当・総額の
// 4項目×全イベント）。タグ透明性フィールド（dividend_per_share_tag/total_amount_tag）は
// 11社ともDividendPerShareDividendsOfSurplus/TotalAmountOfDividendsDividendsOfSurplusで固定
// （フォールバック候補なし）。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct DividendsOracleFormatTests {
    private static let expectedFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("smoke/statement_notes_dividends_expected.json")

    private func assertMatchesOracle(docID: String, xbrlDir: URL) throws {
        let result = StatementNotesResolver.resolveDividends(xbrlDir: xbrlDir)
        let items: [[String: Any]]?
        if case .resolved(let payload, _, _) = result {
            items = payload.dividendEvents?.map { $0.jsonObject() }
        } else {
            items = nil
        }
        try StatementNotesOracleSupport.assertMatchesOracle(
            docID: docID, expectedFileURL: Self.expectedFileURL, result: result,
            itemsKey: "dividend_events", items: items)
    }

    private func withSmokeCache(_ docID: String, _ body: (URL) throws -> Void) async throws {
        try await StatementNotesOracleSupport.withSmokeCache(docID, body)
    }

    // MARK: - S100JRT9（レーザーテック）

    @Test(.enabled(if: StatementNotesOracleSupport.analysisCacheAvailable("S100JRT9"), "XBRL cache S100JRT9 not available"))
    func dividendsMatchesExternalizedOracleLaserTec() throws {
        try assertMatchesOracle(docID: "S100JRT9", xbrlDir: StatementNotesOracleSupport.analysisXbrlDir("S100JRT9"))
    }

    // MARK: - S100RX8V（メルカリ、無配当でnotApplicable）

    @Test(.enabled(if: StatementNotesOracleSupport.analysisCacheAvailable("S100RX8V"), "XBRL cache S100RX8V not available"))
    func dividendsMatchesExternalizedOracleMercariNotApplicable() throws {
        try assertMatchesOracle(docID: "S100RX8V", xbrlDir: StatementNotesOracleSupport.analysisXbrlDir("S100RX8V"))
    }

    // MARK: - smoke 床11社（tmp_cache / SmokeCacheSupport）

    @Test
    func smokeDividendsAZplanningMatchesOracle() async throws {
        try await withSmokeCache("S100VU4O") {
            try assertMatchesOracle(docID: "S100VU4O", xbrlDir: $0)
        }
    }

    @Test
    func smokeDividendsAjinomotoMatchesOracle() async throws {
        try await withSmokeCache("S100VXJA") {
            try assertMatchesOracle(docID: "S100VXJA", xbrlDir: $0)
        }
    }

    @Test
    func smokeDividendsNichireiMatchesOracle() async throws {
        try await withSmokeCache("S100VYA0") {
            try assertMatchesOracle(docID: "S100VYA0", xbrlDir: $0)
        }
    }

    @Test
    func smokeDividendsOkumaMatchesOracle() async throws {
        try await withSmokeCache("S100W043") {
            try assertMatchesOracle(docID: "S100W043", xbrlDir: $0)
        }
    }

    @Test
    func smokeDividendsSMFGMatchesOracle() async throws {
        try await withSmokeCache("S100W0S7") {
            try assertMatchesOracle(docID: "S100W0S7", xbrlDir: $0)
        }
    }

    @Test
    func smokeDividendsFujifilmMatchesOracle() async throws {
        try await withSmokeCache("S100W3XJ") {
            try assertMatchesOracle(docID: "S100W3XJ", xbrlDir: $0)
        }
    }

    @Test
    func smokeDividendsMUFGMatchesOracle() async throws {
        try await withSmokeCache("S100W4FB") {
            try assertMatchesOracle(docID: "S100W4FB", xbrlDir: $0)
        }
    }

    @Test
    func smokeDividendsSuzukiMatchesOracle() async throws {
        try await withSmokeCache("S100W4MT") {
            try assertMatchesOracle(docID: "S100W4MT", xbrlDir: $0)
        }
    }

    @Test
    func smokeDividendsKubotaMatchesOracle() async throws {
        try await withSmokeCache("S100XR0M") {
            try assertMatchesOracle(docID: "S100XR0M", xbrlDir: $0)
        }
    }

    @Test
    func smokeDividendsTohoRemacMatchesOracle() async throws {
        try await withSmokeCache("S100XRD8") {
            try assertMatchesOracle(docID: "S100XRD8", xbrlDir: $0)
        }
    }

    @Test
    func smokeDividendsCanonMatchesOracle() async throws {
        try await withSmokeCache("S100XTLJ") {
            try assertMatchesOracle(docID: "S100XTLJ", xbrlDir: $0)
        }
    }
}
