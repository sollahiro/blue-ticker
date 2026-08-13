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
//
// smoke 固定11社の実データ検証・目視確認（2026-08-12）: IFRS連結3社のうち味の素(S100VXJA)・
// クボタ(S100XR0M)は resolved で、開示HTML（のれん・無形資産の帳簿価額増減表）の実数値と
// 完全一致をユーザー確認済み（golden化承認）。スズキ(S100W4MT)は notApplicable(not_found) だが、
// これは実装ギャップではなくスズキの開示自体に `GoodwillIFRS` タグが一切存在しない（のれんの
// 重要性が無いため、注記見出しも標準タクソノミの別ロール `NotesIntangibleAssetsConsolidatedFinancial
// StatementsIFRS`＝「のれん」を含まない無形資産のみの注記になっている）ことをユーザーが確認済み。
// 非IFRS8社は想定通り notApplicable(not_found)（法定附属明細表自体が無い）。

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

    private func withSmokeCache(_ docID: String, _ body: (URL) throws -> Void) async throws {
        try await StatementNotesOracleSupport.withSmokeCache(docID, body)
    }

    // MARK: - S100VWVY（トヨタ自動車、のれん明細に対応する附属明細表なし）

    @Test(.enabled(if: StatementNotesOracleSupport.analysisCacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func goodwillMatchesExternalizedOracleToyotaNotApplicable() throws {
        try assertMatchesOracle(docID: "S100VWVY", xbrlDir: StatementNotesOracleSupport.analysisXbrlDir("S100VWVY"))
    }

    // MARK: - smoke 床11社（tmp_cache / SmokeCacheSupport）

    @Test
    func smokeGoodwillAjinomotoMatchesOracle() async throws {
        try await withSmokeCache("S100VXJA") {
            try assertMatchesOracle(docID: "S100VXJA", xbrlDir: $0)
        }
    }

    @Test
    func smokeGoodwillKubotaMatchesOracle() async throws {
        try await withSmokeCache("S100XR0M") {
            try assertMatchesOracle(docID: "S100XR0M", xbrlDir: $0)
        }
    }

    @Test
    func smokeGoodwillSuzukiNotApplicable() async throws {
        try await withSmokeCache("S100W4MT") {
            try assertMatchesOracle(docID: "S100W4MT", xbrlDir: $0)
        }
    }

    // MARK: - smoke 床11社 - 非IFRS8社は not_found（法定附属明細表自体が無い）

    @Test
    func smokeGoodwillNichireiNotApplicable() async throws {
        try await withSmokeCache("S100VYA0") {
            try assertMatchesOracle(docID: "S100VYA0", xbrlDir: $0)
        }
    }

    @Test
    func smokeGoodwillAZplanningNotApplicable() async throws {
        try await withSmokeCache("S100VU4O") {
            try assertMatchesOracle(docID: "S100VU4O", xbrlDir: $0)
        }
    }

    @Test
    func smokeGoodwillFujifilmNotApplicable() async throws {
        try await withSmokeCache("S100W3XJ") {
            try assertMatchesOracle(docID: "S100W3XJ", xbrlDir: $0)
        }
    }

    @Test
    func smokeGoodwillOkumaNotApplicable() async throws {
        try await withSmokeCache("S100W043") {
            try assertMatchesOracle(docID: "S100W043", xbrlDir: $0)
        }
    }

    @Test
    func smokeGoodwillTohoRemacNotApplicable() async throws {
        try await withSmokeCache("S100XRD8") {
            try assertMatchesOracle(docID: "S100XRD8", xbrlDir: $0)
        }
    }

    @Test
    func smokeGoodwillCanonNotApplicable() async throws {
        try await withSmokeCache("S100XTLJ") {
            try assertMatchesOracle(docID: "S100XTLJ", xbrlDir: $0)
        }
    }

    @Test
    func smokeGoodwillMUFGNotApplicable() async throws {
        try await withSmokeCache("S100W4FB") {
            try assertMatchesOracle(docID: "S100W4FB", xbrlDir: $0)
        }
    }

    @Test
    func smokeGoodwillSMFGNotApplicable() async throws {
        try await withSmokeCache("S100W0S7") {
            try assertMatchesOracle(docID: "S100W0S7", xbrlDir: $0)
        }
    }
}
