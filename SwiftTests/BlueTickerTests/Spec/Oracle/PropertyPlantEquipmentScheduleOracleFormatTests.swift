// 外出し SPEC_ORACLE フォーマット（`StatementNotesOracleFormatTests.swift`=borrowings_schedule と同型）。
//
// property_plant_equipment_schedule: IFRS 注記 role で resolved、それ以外は lease と同型の
// BS 区分タグ当期値判定（`Xbrl.propertyPlantEquipmentScheduleBSTags`）。
// smoke 固定11社（2026-08-16）:
// - IFRS連結3社（味の素・クボタ・スズキ）は resolved
// - J-GAAP6社は BS 区分タグあり → `available_via_statement`
// - US-GAAP2社（富士フイルム・キヤノン）は `us_gaap_unsupported`（連結 HTML 経路と
//   fieldSet の NonConsolidated 落としのため BS タグ判定では案内しない）
// 京セラ(S100TSIJ)・トヨタ(S100VWVY)は既存の `RealXbrlStatementNotesTests.swift` 側の
// ハードコードgoldenを維持し、本ファイルには重複追加しない。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct PropertyPlantEquipmentScheduleOracleFormatTests {
    private static let expectedFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("smoke/statement_notes_property_plant_equipment_schedule_expected.json")

    private func assertMatchesOracle(docID: String, xbrlDir: URL) throws {
        let result = StatementNotesResolver.resolvePropertyPlantEquipmentSchedule(xbrlDir: xbrlDir)
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

    // MARK: - smoke 床11社（tmp_cache / SmokeCacheSupport） - IFRS連結3社は resolved

    @Test
    func smokePPEScheduleAjinomotoMatchesOracle() async throws {
        try await withSmokeCache("S100VXJA") {
            try assertMatchesOracle(docID: "S100VXJA", xbrlDir: $0)
        }
    }

    @Test
    func smokePPEScheduleKubotaMatchesOracle() async throws {
        try await withSmokeCache("S100XR0M") {
            try assertMatchesOracle(docID: "S100XR0M", xbrlDir: $0)
        }
    }

    @Test
    func smokePPEScheduleSuzukiMatchesOracle() async throws {
        try await withSmokeCache("S100W4MT") {
            try assertMatchesOracle(docID: "S100W4MT", xbrlDir: $0)
        }
    }

    // MARK: - smoke 床11社 - J-GAAP6社は BS 区分タグ当期値あり → available_via_statement

    @Test
    func smokePPEScheduleNichireiNotApplicable() async throws {
        try await withSmokeCache("S100VYA0") {
            try assertMatchesOracle(docID: "S100VYA0", xbrlDir: $0)
        }
    }

    @Test
    func smokePPEScheduleAZplanningNotApplicable() async throws {
        try await withSmokeCache("S100VU4O") {
            try assertMatchesOracle(docID: "S100VU4O", xbrlDir: $0)
        }
    }

    @Test
    func smokePPEScheduleOkumaNotApplicable() async throws {
        try await withSmokeCache("S100W043") {
            try assertMatchesOracle(docID: "S100W043", xbrlDir: $0)
        }
    }

    @Test
    func smokePPEScheduleFujifilmNotApplicable() async throws {
        try await withSmokeCache("S100W3XJ") {
            try assertMatchesOracle(docID: "S100W3XJ", xbrlDir: $0)
        }
    }

    @Test
    func smokePPEScheduleTohoRemacNotApplicable() async throws {
        try await withSmokeCache("S100XRD8") {
            try assertMatchesOracle(docID: "S100XRD8", xbrlDir: $0)
        }
    }

    @Test
    func smokePPEScheduleCanonNotApplicable() async throws {
        try await withSmokeCache("S100XTLJ") {
            try assertMatchesOracle(docID: "S100XTLJ", xbrlDir: $0)
        }
    }

    @Test
    func smokePPEScheduleMUFGNotApplicable() async throws {
        try await withSmokeCache("S100W4FB") {
            try assertMatchesOracle(docID: "S100W4FB", xbrlDir: $0)
        }
    }

    @Test
    func smokePPEScheduleSMFGNotApplicable() async throws {
        try await withSmokeCache("S100W0S7") {
            try assertMatchesOracle(docID: "S100W0S7", xbrlDir: $0)
        }
    }
}
