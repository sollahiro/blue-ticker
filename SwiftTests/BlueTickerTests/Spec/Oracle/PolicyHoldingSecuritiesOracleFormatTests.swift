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

    // MARK: - S100VWVY（トヨタ自動車）

    @Test(.enabled(if: StatementNotesOracleSupport.analysisCacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func securitiesMatchesExternalizedOracleToyota() throws {
        try assertMatchesOracle(docID: "S100VWVY", xbrlDir: StatementNotesOracleSupport.analysisXbrlDir("S100VWVY"))
    }
}
