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
}
