import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct ManualXbrlOverrideTests {
    @Test func rejectsUnknownItem() {
        #expect(throws: ManualXbrlOverrideValidationError.self) {
            try parseManualXbrlOverrideItem("revenue")
        }
    }

    @Test func closedItemSetIsCapex() {
        #expect(ManualXbrlOverrideItem.allCases.map(\.rawValue) == ["capex"])
    }

    @Test func capexPayloadRequiresYenUnitAndScale() throws {
        let payload = try parseCapexManualOverridePayload(
            ["value": 370_500, "unit": "JPY", "scale": 6])
        #expect(payload.yen == 370_500_000_000)
        #expect(payload.millionYen == 370_500)
    }

    @Test func capexRejectsUnknownKeysAndBadUnit() {
        #expect(throws: ManualXbrlOverrideValidationError.self) {
            try parseCapexManualOverridePayload(
                ["value": 1, "unit": "JPY", "scale": 0, "extra": true])
        }
        #expect(throws: ManualXbrlOverrideValidationError.self) {
            try parseCapexManualOverridePayload(["value": 1, "unit": "USD", "scale": 0])
        }
        #expect(throws: ManualXbrlOverrideValidationError.self) {
            try parseCapexManualOverridePayload(["value": 1, "unit": "JPY", "scale": 99])
        }
    }

    @Test func addFileRequiresSourcePageAndReason() {
        let json = """
            {"edinet_code":"E03614","period_end":"2025-03-31","item":"capex",
             "payload":{"value":1,"unit":"JPY","scale":0},"created_by":"t"}
            """
        #expect(throws: ManualXbrlOverrideValidationError.self) {
            try parseManualXbrlOverrideAddFile(Data(json.utf8))
        }
    }

    @Test func addFileParsesCapexAndRejectsUnknownTopLevelKeys() throws {
        let json = """
            {
              "edinet_code": "E03614",
              "period_end": "2025-03-31",
              "item": "capex",
              "source_doc_id": "S100WRZH",
              "source_page": "設備の状況",
              "reason": "decimals -6 vs 億円",
              "created_by": "sorahiro",
              "payload": { "value": 370500, "unit": "JPY", "scale": 6 }
            }
            """
        let record = try parseManualXbrlOverrideAddFile(Data(json.utf8))
        #expect(record.edinetCode == "E03614")
        #expect(record.item == .capex)
        #expect(record.sourceDocID == "S100WRZH")
        guard case .capex(let capex) = record.payload else {
            Issue.record("expected capex payload")
            return
        }
        #expect(capex.millionYen == 370_500)

        let extra = """
            {
              "edinet_code": "E03614", "period_end": "2025-03-31", "item": "capex",
              "source_doc_id": "S100WRZH", "source_page": "p", "reason": "r",
              "created_by": "t", "payload": {"value":1,"unit":"JPY","scale":0},
              "comment": "nope"
            }
            """
        #expect(throws: ManualXbrlOverrideValidationError.self) {
            try parseManualXbrlOverrideAddFile(Data(extra.utf8))
        }
    }

    @Test func applyAfterOverlayClearsOnlyCoveredItem() throws {
        let overlayWarning =
            "overlay_regression:row_loss:S100X7DX:orig=S100W0S7:tag=Holding:before=70:after=13"
        let before = ManualXbrlCompanyYearState(
            capexMillionYen: 3_705, capexNeedsReview: true,
            capexWarnings: [overlayWarning], otherNeedsReview: true)
        let capex = ManualXbrlOverrideRecord(
            edinetCode: "E03614", periodEnd: "2025-03-31", item: .capex,
            payload: .capex(CapexManualOverridePayload(value: 370_500, unit: "JPY", scale: 6)),
            sourceDocID: "S100WRZH", sourcePage: "設備の状況", reason: "scale", createdBy: "t")

        let once = applyManualXbrlOverrides(to: before, overrides: [capex])
        #expect(once.capexMillionYen == 370_500)
        #expect(once.capexNeedsReview == false)
        #expect(once.otherNeedsReview == true)
        #expect(!once.capexWarnings.contains { $0.hasPrefix(xbrlOverlayRegressionWarningPrefix) })
        #expect(once.capexWarnings.contains { $0.hasPrefix(manualXbrlOverrideWarningPrefix) })

        let twice = applyManualXbrlOverrides(to: once, overrides: [capex])
        #expect(twice.capexMillionYen == once.capexMillionYen)
        #expect(twice.capexNeedsReview == once.capexNeedsReview)
        #expect(twice.otherNeedsReview == once.otherNeedsReview)
        #expect(twice.capexWarnings == once.capexWarnings)
    }

    @Test func revokedOverridesAreIgnoredWhenNotPassed() {
        let before = ManualXbrlCompanyYearState(
            capexMillionYen: 3_705, capexNeedsReview: true, otherNeedsReview: true)
        let after = applyManualXbrlOverrides(to: before, overrides: [])
        #expect(after.capexMillionYen == 3_705)
        #expect(after.capexNeedsReview == true)
        #expect(after.otherNeedsReview == true)
    }

    @Test func smfgSyntheticFixtureClearsCapexReview() throws {
        // S100W0S7 / WRZH / X7DX packages are not checked in on main; this is the
        // 8316 FY2025 shape (wrong 3,705M capex + overlay needs_review).
        let overlay = ManualXbrlCompanyYearState(
            capexMillionYen: 3_705, capexNeedsReview: true, otherNeedsReview: true)
        let applied = applyManualXbrlOverrides(
            to: overlay,
            overrides: [
                ManualXbrlOverrideRecord(
                    edinetCode: "E03614", periodEnd: "2025-03-31", item: .capex,
                    payload: .capex(
                        CapexManualOverridePayload(value: 370_500, unit: "JPY", scale: 6)),
                    sourceDocID: "S100WRZH", sourcePage: "設備の状況", reason: "億円", createdBy: "t")
            ])
        #expect(applied.capexMillionYen == 370_500)
        #expect(applied.capexNeedsReview == false)
        #expect(applied.otherNeedsReview == true)
    }
}
