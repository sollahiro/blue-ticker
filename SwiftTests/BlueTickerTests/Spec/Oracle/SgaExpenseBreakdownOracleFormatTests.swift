// 外出し SPEC_ORACLE（`sga_expense_breakdown` note_type）。
//
// smoke 固定11社の実データ検証（2026-08-27）:
// - resolved: オークマ・アズ企画・スズキ・味の素・東邦レマック・ニチレイ（構造化 *SGA / IFRS 費目）
// - not_found: クボタ・三菱UFJ・三井住友（連結に費目タグ無し。個別注記のみは拾わない）
// - us_gaap_unsupported: 富士フイルム・キヤノン
//
// 発生支出（ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities）は含めない。
// スズキの販管費内 R&D は ResearchAndDevelopmentExpenditureRecognizedAsExpenseDuringPeriodIFRS。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct SgaExpenseBreakdownOracleFormatTests {
    private static let expectedFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("smoke/statement_notes_sga_expense_breakdown_expected.json")

    private func assertMatchesOracle(docID: String, xbrlDir: URL) throws {
        let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
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
    func smokeSgaOkumaMatchesOracle() async throws {
        try await withSmokeCache("S100W043") {
            try assertMatchesOracle(docID: "S100W043", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaAzPlanningMatchesOracle() async throws {
        try await withSmokeCache("S100VU4O") {
            try assertMatchesOracle(docID: "S100VU4O", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaSuzukiMatchesOracle() async throws {
        try await withSmokeCache("S100W4MT") {
            try assertMatchesOracle(docID: "S100W4MT", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaAjinomotoMatchesOracle() async throws {
        try await withSmokeCache("S100VXJA") {
            try assertMatchesOracle(docID: "S100VXJA", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaTohoRemacMatchesOracle() async throws {
        try await withSmokeCache("S100XRD8") {
            try assertMatchesOracle(docID: "S100XRD8", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaNichireiMatchesOracle() async throws {
        try await withSmokeCache("S100VYA0") {
            try assertMatchesOracle(docID: "S100VYA0", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaKubotaNotFound() async throws {
        try await withSmokeCache("S100XR0M") {
            try assertMatchesOracle(docID: "S100XR0M", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaSmfgNotFound() async throws {
        try await withSmokeCache("S100W0S7") {
            try assertMatchesOracle(docID: "S100W0S7", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaMufgNotFound() async throws {
        try await withSmokeCache("S100W4FB") {
            try assertMatchesOracle(docID: "S100W4FB", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaFujifilmUSGAAPUnsupported() async throws {
        try await withSmokeCache("S100W3XJ") {
            try assertMatchesOracle(docID: "S100W3XJ", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaCanonUSGAAPUnsupported() async throws {
        try await withSmokeCache("S100XTLJ") {
            try assertMatchesOracle(docID: "S100XTLJ", xbrlDir: $0)
        }
    }

    // MARK: - BLT-46 golden（発生支出と販管費内 R&D の区別）

    @Test
    func goldenOkumaSgaRdDistinctFromOccurrenceSpend() async throws {
        try await withSmokeCache("S100YFQC") { xbrlDir in
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
            guard case .resolved(let payload, _, _) = result else {
                Issue.record("expected resolved, got \(result)")
                return
            }
            let byTag = Dictionary(uniqueKeysWithValues: (payload.items ?? []).map { ($0.tag, $0) })
            #expect(byTag["ResearchAndDevelopmentExpensesSGA"]?.value == 2_097_000_000)
            #expect(byTag["ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities"] == nil)
            #expect(
                byTag[
                    "ResearchAndDevelopmentExpensesIncludedInGeneralAndAdministrativeExpensesAndManufacturingCostForCurrentPeriod"
                ] == nil)
            #expect(byTag["FreightageAndPackingExpensesSGA"]?.value == 12_834_000_000)
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.isTotal == true)
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.value == 53_796_000_000)
        }
    }

    @Test
    func goldenSuzukiSgaRdMatchesNotesNotOccurrenceSpend() async throws {
        try await withSmokeCache("S100YFG2") { xbrlDir in
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
            guard case .resolved(let payload, _, _) = result else {
                Issue.record("expected resolved, got \(result)")
                return
            }
            let byTag = Dictionary(uniqueKeysWithValues: (payload.items ?? []).map { ($0.tag, $0) })
            #expect(
                byTag["ResearchAndDevelopmentExpenditureRecognizedAsExpenseDuringPeriodIFRS"]?.value
                    == 271_082_000_000)
            #expect(byTag["ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities"] == nil)
            #expect(byTag["SellingGeneralAndAdministrativeExpensesIFRS"]?.value == 1_012_493_000_000)
            let components = (payload.items ?? []).filter { !$0.isTotal }.map(\.value)
            #expect(abs(components.reduce(0, +) - 1_012_493_000_000) < 3_000_000)
        }
    }

    /// `DUMP_SGA_ORACLE=1` のとき smoke 11社の実結果を expected JSON に書き出す（床の初期生成用）。
    @Test
    func dumpSgaOracleIfRequested() async throws {
        guard ProcessInfo.processInfo.environment["DUMP_SGA_ORACLE"] == "1" else { return }
        let docIDs = [
            "S100W043", "S100VU4O", "S100W4MT", "S100VXJA", "S100XRD8", "S100VYA0",
            "S100XR0M", "S100W0S7", "S100W4FB", "S100W3XJ", "S100XTLJ",
        ]
        await SmokeCacheSupport.ensureCached(docIDs)
        var out: [String: Any] = [:]
        for docID in docIDs {
            guard StatementNotesOracleSupport.smokeCacheAvailable(docID) else {
                Issue.record("missing cache \(docID)")
                continue
            }
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(
                xbrlDir: StatementNotesOracleSupport.smokeXbrlDir(docID))
            switch result {
            case .notApplicable(let reason):
                out[docID] = ["status": "not_applicable", "reason": reason]
            case .failed:
                out[docID] = ["status": "failed"]
            case .resolved(let payload, let source, _):
                var entry: [String: Any] = ["status": "resolved", "source": source]
                if let items = payload.items {
                    entry["items"] = items.map { $0.jsonObject() }
                }
                out[docID] = entry
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.expectedFileURL)
        print("DUMPED \(Self.expectedFileURL.path)")
    }
}
