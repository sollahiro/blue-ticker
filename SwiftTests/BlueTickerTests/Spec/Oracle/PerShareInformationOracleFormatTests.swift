// 外出し SPEC_ORACLE フォーマット（`StatementNotesOracleFormatTests.swift`=borrowings_schedule と同型、
// 2026-08-11 note_type横展開）。期待値は `RealXbrlStatementNotesTests.swift` の既存golden
// （goldenPerShareLaserTecJGAAP/goldenPerShareHitachiIFRS、ユーザー実データ確認済み）をそのまま
// `smoke/statement_notes_per_share_information_expected.json` へ転記したもので、新規の実データ
// レビューは行っていない。既存ハードコードgoldenテストを置き換えるものではなく併存させる。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct PerShareInformationOracleFormatTests {
    private static let expectedFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("smoke/statement_notes_per_share_information_expected.json")

    private func assertMatchesOracle(docID: String, xbrlDir: URL) throws {
        let result = StatementNotesResolver.resolvePerShareInformation(xbrlDir: xbrlDir)
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

    // MARK: - S100JRT9（レーザーテック、J-GAAP）

    @Test(.enabled(if: StatementNotesOracleSupport.analysisCacheAvailable("S100JRT9"), "XBRL cache S100JRT9 not available"))
    func perShareMatchesExternalizedOracleLaserTecJGAAP() throws {
        try assertMatchesOracle(docID: "S100JRT9", xbrlDir: StatementNotesOracleSupport.analysisXbrlDir("S100JRT9"))
    }

    // MARK: - S100QZT0（日立、IFRS・BPSは誤タグ名経由）

    @Test(.enabled(if: StatementNotesOracleSupport.analysisCacheAvailable("S100QZT0"), "XBRL cache S100QZT0 not available"))
    func perShareMatchesExternalizedOracleHitachiIFRS() throws {
        try assertMatchesOracle(docID: "S100QZT0", xbrlDir: StatementNotesOracleSupport.analysisXbrlDir("S100QZT0"))
    }
}
