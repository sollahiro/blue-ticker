// 外出し SPEC_ORACLE フォーマット（borrowings_schedule / per_share_information と同型）。
//
// `issued_shares_and_capital` は 2026-08-11 に as_of_period_end（離散タグ）＋ events（textblock表）の二段へ拡張。
// smoke 固定11社を床に載せる。期待JSONは resolver 実出力を外出ししたもの（as_of.issued_shares は
// smoke_expected.per_share.issued_shares と一致することをスポット確認済み）。
// 既存ハードコード golden は深さ用に併存。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct IssuedSharesAndCapitalOracleFormatTests {
    private static let expectedFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("smoke/statement_notes_issued_shares_and_capital_expected.json")

    private func assertMatchesOracle(docID: String, xbrlDir: URL) throws {
        let result = StatementNotesResolver.resolveIssuedSharesAndCapital(xbrlDir: xbrlDir)
        let items: [[String: Any]]?
        if case .resolved(let payload, _, _) = result {
            items = payload.issuedSharesEvents?.map { $0.jsonObject() }
        } else {
            items = nil
        }
        try StatementNotesOracleSupport.assertMatchesOracle(
            docID: docID, expectedFileURL: Self.expectedFileURL, result: result,
            itemsKey: "issued_shares_events", items: items)

        // as_of_period_end も突合（events だけだと表丸めに引きずられる）
        let expectedEntry = try StatementNotesOracleSupport.loadExpectedEntry(
            fileURL: Self.expectedFileURL, docID: docID)
        guard case .resolved(let payload, _, _) = result else { return }
        let actualAsOf = payload.issuedSharesAsOf?.jsonObject() ?? [:]
        let expectedAsOf = expectedEntry["as_of_period_end"] as? [String: Any] ?? [:]
        #expect(!expectedAsOf.isEmpty)
        let actualJSON = try StatementNotesOracleSupport.canonicalJSON(actualAsOf)
        let expectedJSON = try StatementNotesOracleSupport.canonicalJSON(expectedAsOf)
        #expect(actualJSON == expectedJSON)
    }

    private func withSmokeCache(_ docID: String, _ body: (URL) throws -> Void) async throws {
        try await StatementNotesOracleSupport.withSmokeCache(docID, body)
    }

    // MARK: - smoke 床11社

    @Test
    func smokeIssuedSharesAndCapitalAZplanningMatchesOracle() async throws {
        try await withSmokeCache("S100VU4O") { try assertMatchesOracle(docID: "S100VU4O", xbrlDir: $0) }
    }

    @Test
    func smokeIssuedSharesAndCapitalAjinomotoMatchesOracle() async throws {
        try await withSmokeCache("S100VXJA") { try assertMatchesOracle(docID: "S100VXJA", xbrlDir: $0) }
    }

    @Test
    func smokeIssuedSharesAndCapitalNichireiMatchesOracle() async throws {
        try await withSmokeCache("S100VYA0") { try assertMatchesOracle(docID: "S100VYA0", xbrlDir: $0) }
    }

    @Test
    func smokeIssuedSharesAndCapitalOkumaMatchesOracle() async throws {
        try await withSmokeCache("S100W043") { try assertMatchesOracle(docID: "S100W043", xbrlDir: $0) }
    }

    @Test
    func smokeIssuedSharesAndCapitalSMFGMatchesOracle() async throws {
        try await withSmokeCache("S100W0S7") { try assertMatchesOracle(docID: "S100W0S7", xbrlDir: $0) }
    }

    @Test
    func smokeIssuedSharesAndCapitalFujifilmMatchesOracle() async throws {
        try await withSmokeCache("S100W3XJ") { try assertMatchesOracle(docID: "S100W3XJ", xbrlDir: $0) }
    }

    @Test
    func smokeIssuedSharesAndCapitalMUFGMatchesOracle() async throws {
        try await withSmokeCache("S100W4FB") { try assertMatchesOracle(docID: "S100W4FB", xbrlDir: $0) }
    }

    @Test
    func smokeIssuedSharesAndCapitalSuzukiMatchesOracle() async throws {
        try await withSmokeCache("S100W4MT") { try assertMatchesOracle(docID: "S100W4MT", xbrlDir: $0) }
    }

    @Test
    func smokeIssuedSharesAndCapitalKubotaMatchesOracle() async throws {
        try await withSmokeCache("S100XR0M") { try assertMatchesOracle(docID: "S100XR0M", xbrlDir: $0) }
    }

    @Test
    func smokeIssuedSharesAndCapitalTohoRemacMatchesOracle() async throws {
        try await withSmokeCache("S100XRD8") { try assertMatchesOracle(docID: "S100XRD8", xbrlDir: $0) }
    }

    @Test
    func smokeIssuedSharesAndCapitalCanonMatchesOracle() async throws {
        try await withSmokeCache("S100XTLJ") { try assertMatchesOracle(docID: "S100XTLJ", xbrlDir: $0) }
    }
}
