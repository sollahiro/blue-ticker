// 外出し SPEC_ORACLE フォーマット（`StatementNotesOracleFormatTests.swift`=borrowings_schedule と同型）。
//
// property_plant_equipment_schedule は意図的に IFRS 連結企業限定（ユーザー判断、2026-08-12）。
// smoke 固定11社の実データ検証: IFRS連結3社（味の素・クボタ・スズキ）は resolved。非IFRS8社は
// 会計基準で理由が分かれる（`StatementNotesResolver.resolvePropertyPlantEquipmentSchedule` 参照）:
// - J-GAAP6社（ニチレイ・AZplanning・オークマ・東邦レマック・三菱UFJ・三井住友）は
//   `available_via_statement`（`statement`本体のBSに区分別タグが構造化済み）
// - US-GAAP2社（富士フイルム・キヤノン）は `us_gaap_unsupported`（`ix:nonFraction`が無く構造化
//   タグで判定できない。実データ確認済み: 富士フイルムは連結BS本表に区分内訳が載るが、キヤノンは
//   BS本表が合計1行のみで内訳は別注記「注５有形固定資産」のHTML表にしかなく、`statement`のUS-GAAP
//   HTML抽出（BS本表のみ読む）でも拾えない。会社ごとに開示形式が違い判別もできないため
//   `available_via_statement`は誤りうる）
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

    // MARK: - smoke 床11社 - 非IFRS8社は available_via_statement で notApplicable

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
