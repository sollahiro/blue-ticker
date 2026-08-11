// 外出し SPEC_ORACLE フォーマット（`StatementNotesOracleFormatTests.swift`=borrowings_schedule と同型、
// 2026-08-11 note_type横展開）。
//
// トヨタ自動車(S100VWVY)は`toyotaHasNoGoodwillNoteIsNotApplicableNotAFailure`（notApplicable、
// のれん明細に対応する法定附属明細表自体が無い）と完全に対応する。notApplicableはstatus+reasonのみで
// 完結するため、キャッシュ無しでも安全に転記できる（実際にはこのマシンに一時的にキャッシュが
// あったため実行結果でも確認済み）。
//
// 京セラ(S100TSIJ、resolved・正味帳簿価額の種類別明細)はこのマシンにキャッシュが無く見送り。
// キャッシュが揃い次第追加する。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct GoodwillAndIntangiblesOracleFormatTests {
    private static let expectedFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("smoke/statement_notes_goodwill_and_intangibles_expected.json")

    private func assertMatchesOracle(docID: String, xbrlDir: URL) throws {
        let result = StatementNotesResolver.resolveGoodwillAndIntangibles(xbrlDir: xbrlDir)
        let items: [[String: Any]]?
        if case .resolved(let payload, _, _) = result {
            items = payload.items?.map { $0.jsonObject() }
        } else {
            items = nil
        }
        try StatementNotesOracleSupport.assertMatchesOracle(
            docID: docID, expectedFileURL: Self.expectedFileURL, result: result,
            itemsKey: "items", items: items)
    }

    // MARK: - S100VWVY（トヨタ自動車、のれん明細に対応する附属明細表なし）

    @Test(.enabled(if: StatementNotesOracleSupport.analysisCacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func goodwillMatchesExternalizedOracleToyotaNotApplicable() throws {
        try assertMatchesOracle(docID: "S100VWVY", xbrlDir: StatementNotesOracleSupport.analysisXbrlDir("S100VWVY"))
    }
}
