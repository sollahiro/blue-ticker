// 外出し SPEC_ORACLE フォーマット（`StatementNotesOracleFormatTests.swift`=borrowings_schedule と同型）。
//
// smoke 固定11社の実データ検証（2026-08-12）:
// - IFRS TextBlock: 味の素（支払期日別 CL+NCL）、クボタ（現在価値 83,336。ROU 87,946は対象外）、
//   スズキ（帳簿価額。満期別内訳は注記にあるが複数表ラベル衝突のため未抽出）
// - J-GAAP BS タグ: ニチレイ・AZplanning（`LeaseObligationsCL`/`NCL`）
// - not_found: オークマ（リース債務は借入金等明細表＝`borrowings_schedule`側。PPE不可）、
//   東邦レマック、銀行2社
// - US-GAAP: 富士フイルム・キヤノン → available_via_statement（BS上の値は statement 責務。notesに二重取得しない）

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct LeaseLiabilitiesOracleFormatTests {
    private static let expectedFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("smoke/statement_notes_lease_liabilities_expected.json")

    private func assertMatchesOracle(docID: String, xbrlDir: URL) throws {
        let result = StatementNotesResolver.resolveLeaseLiabilities(xbrlDir: xbrlDir)
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

    @Test
    func smokeLeaseAjinomotoMatchesOracle() async throws {
        try await withSmokeCache("S100VXJA") {
            try assertMatchesOracle(docID: "S100VXJA", xbrlDir: $0)
        }
    }

    @Test
    func smokeLeaseNichireiMatchesOracle() async throws {
        try await withSmokeCache("S100VYA0") {
            try assertMatchesOracle(docID: "S100VYA0", xbrlDir: $0)
        }
    }

    @Test
    func smokeLeaseAzPlanningMatchesOracle() async throws {
        try await withSmokeCache("S100VU4O") {
            try assertMatchesOracle(docID: "S100VU4O", xbrlDir: $0)
        }
    }

    @Test
    func smokeLeaseFujifilmAvailableViaStatement() async throws {
        try await withSmokeCache("S100W3XJ") {
            try assertMatchesOracle(docID: "S100W3XJ", xbrlDir: $0)
        }
    }

    @Test
    func smokeLeaseOkumaNotApplicable() async throws {
        try await withSmokeCache("S100W043") {
            try assertMatchesOracle(docID: "S100W043", xbrlDir: $0)
        }
    }

    @Test
    func smokeLeaseKubotaMatchesOracle() async throws {
        try await withSmokeCache("S100XR0M") {
            try assertMatchesOracle(docID: "S100XR0M", xbrlDir: $0)
        }
    }

    @Test
    func smokeLeaseSuzukiMatchesOracle() async throws {
        try await withSmokeCache("S100W4MT") {
            try assertMatchesOracle(docID: "S100W4MT", xbrlDir: $0)
        }
    }

    @Test
    func smokeLeaseTohoRemacNotApplicable() async throws {
        try await withSmokeCache("S100XRD8") {
            try assertMatchesOracle(docID: "S100XRD8", xbrlDir: $0)
        }
    }

    @Test
    func smokeLeaseCanonAvailableViaStatement() async throws {
        try await withSmokeCache("S100XTLJ") {
            try assertMatchesOracle(docID: "S100XTLJ", xbrlDir: $0)
        }
    }

    @Test
    func smokeLeaseMufgNotApplicable() async throws {
        try await withSmokeCache("S100W4FB") {
            try assertMatchesOracle(docID: "S100W4FB", xbrlDir: $0)
        }
    }

    @Test
    func smokeLeaseSmfgNotApplicable() async throws {
        try await withSmokeCache("S100W0S7") {
            try assertMatchesOracle(docID: "S100W0S7", xbrlDir: $0)
        }
    }
}
