import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct ManualXbrlOverrideTests {
    @Test func rejectsUnknownItem() {
        #expect(throws: ManualXbrlOverrideValidationError.self) {
            try parseManualXbrlOverrideItem("revenue")
        }
    }

    @Test func closedItemSetIsCapexAndPolicyHoldings() {
        #expect(
            ManualXbrlOverrideItem.allCases.map(\.rawValue).sorted()
                == ["capex", "policy_holding_securities"])
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

    @Test func policyHoldingsRejectsUnknownRowKeys() {
        #expect(throws: ManualXbrlOverrideValidationError.self) {
            try parsePolicyHoldingManualOverridePayload(
                [
                    "securities": [
                        [
                            "issuer_name": "A",
                            "ticker": "7203",
                        ]
                    ]
                ])
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
        var holdings: [PolicyHoldingSecurityPayload] = []
        for i in 1...70 {
            holdings.append(
                PolicyHoldingSecurityPayload(
                    issuerName: "Issuer\(i)", numberOfShares: Double(i), carryingAmount: Double(i * 10),
                    purpose: "policy", isDeemedHolding: false))
        }
        let before = ManualXbrlCompanyYearState(
            capexMillionYen: 3_705, capexNeedsReview: true,
            capexWarnings: [overlayWarning],
            policyHoldings: StatementNotePayload(
                securities: Array(holdings.prefix(13)), needsReview: true,
                warnings: [overlayWarning]),
            policyHoldingsNeedsReview: true, policyHoldingsWarnings: [overlayWarning],
            otherNeedsReview: true)
        let capex = ManualXbrlOverrideRecord(
            edinetCode: "E03614", periodEnd: "2025-03-31", item: .capex,
            payload: .capex(CapexManualOverridePayload(value: 370_500, unit: "JPY", scale: 6)),
            sourceDocID: "S100WRZH", sourcePage: "設備の状況", reason: "scale", createdBy: "t")
        let rows = ManualXbrlOverrideRecord(
            edinetCode: "E03614", periodEnd: "2025-03-31", item: .policyHoldingSecurities,
            payload: .policyHoldingSecurities(
                PolicyHoldingSecuritiesManualOverridePayload(
                    securities: holdings, policyHoldingSummary: nil)),
            sourceDocID: "S100WRZH", sourcePage: "提出会社の状況", reason: "retag", createdBy: "t")

        let once = applyManualXbrlOverrides(to: before, overrides: [capex, rows])
        #expect(once.capexMillionYen == 370_500)
        #expect(once.capexNeedsReview == false)
        #expect(once.policyHoldings?.securities?.count == 70)
        #expect(once.policyHoldingsNeedsReview == false)
        #expect(once.otherNeedsReview == true)
        #expect(!once.capexWarnings.contains { $0.hasPrefix(xbrlOverlayRegressionWarningPrefix) })
        #expect(
            once.policyHoldingsWarnings.contains {
                $0.hasPrefix(manualXbrlOverrideWarningPrefix)
            })
        #expect(
            !isPubliclyServableStatementNote(
                needsReview: before.policyHoldingsNeedsReview,
                warnings: before.policyHoldingsWarnings))
        #expect(
            isPubliclyServableStatementNote(
                needsReview: once.policyHoldingsNeedsReview,
                warnings: once.policyHoldingsWarnings))

        let twice = applyManualXbrlOverrides(to: once, overrides: [capex, rows])
        #expect(twice.capexMillionYen == once.capexMillionYen)
        #expect(twice.capexNeedsReview == once.capexNeedsReview)
        #expect(twice.policyHoldings?.securities?.count == once.policyHoldings?.securities?.count)
        #expect(twice.policyHoldingsNeedsReview == once.policyHoldingsNeedsReview)
        #expect(twice.otherNeedsReview == once.otherNeedsReview)
        #expect(twice.policyHoldingsWarnings == once.policyHoldingsWarnings)
    }

    @Test func revokedOverridesAreIgnoredWhenNotPassed() {
        let before = ManualXbrlCompanyYearState(
            capexMillionYen: 3_705, capexNeedsReview: true, otherNeedsReview: true)
        let after = applyManualXbrlOverrides(to: before, overrides: [])
        #expect(after.capexMillionYen == 3_705)
        #expect(after.capexNeedsReview == true)
        #expect(after.otherNeedsReview == true)
    }

    @Test func policyHoldingOverrideAppliesAfterOverlayStampedNote() {
        let overlayWarning =
            "overlay_regression:scale_jump:S100X7DX:orig=S100W0S7:tag=Capex"
        let stamped = StatementNoteResolveResult.resolved(
            payload: StatementNotePayload(
                securities: [
                    PolicyHoldingSecurityPayload(
                        issuerName: "partial", numberOfShares: 1, carryingAmount: 1, purpose: nil)
                ],
                needsReview: true, warnings: [overlayWarning]),
            source: statementNoteSourceXbrlFacts, contentHash: "h")
        let override = ManualXbrlOverrideRecord(
            edinetCode: "E03614", periodEnd: "2025-03-31", item: .policyHoldingSecurities,
            payload: .policyHoldingSecurities(
                PolicyHoldingSecuritiesManualOverridePayload(
                    securities: [
                        PolicyHoldingSecurityPayload(
                            issuerName: "full", numberOfShares: 2, carryingAmount: 2, purpose: "p")
                    ],
                    policyHoldingSummary: nil)),
            sourceDocID: "S100WRZH", sourcePage: "p", reason: "r", createdBy: "t")
        let applied = applyManualPolicyHoldingOverride(to: stamped, override: override)
        guard case .resolved(let payload, let source, _) = applied else {
            Issue.record("expected resolved")
            return
        }
        #expect(source == statementNoteSourceManualOverride)
        #expect(payload.needsReview == false)
        #expect(payload.securities?.first?.issuerName == "full")
        #expect(!hasOverlayRegressionWarning(payload.warnings))
        #expect(
            isPubliclyServableStatementNote(needsReview: payload.needsReview, warnings: payload.warnings)
        )
    }

    @Test func smfgSyntheticFixtureClearsCapexAndHoldingsReview() throws {
        // S100W0S7 / WRZH / X7DX packages are not checked in on main; this is the
        // 8316 FY2025 shape (wrong 3,705M capex + overlay needs_review, 70 WRZH rows).
        var rows: [PolicyHoldingSecurityPayload] = []
        for i in 1...70 {
            rows.append(
                PolicyHoldingSecurityPayload(
                    issuerName: "Name\(i)", numberOfShares: 1, carryingAmount: 1, purpose: "p"))
        }
        let overlay = ManualXbrlCompanyYearState(
            capexMillionYen: 3_705, capexNeedsReview: true,
            policyHoldings: StatementNotePayload(securities: rows, needsReview: true),
            policyHoldingsNeedsReview: true, otherNeedsReview: true)
        let applied = applyManualXbrlOverrides(
            to: overlay,
            overrides: [
                ManualXbrlOverrideRecord(
                    edinetCode: "E03614", periodEnd: "2025-03-31", item: .capex,
                    payload: .capex(
                        CapexManualOverridePayload(value: 370_500, unit: "JPY", scale: 6)),
                    sourceDocID: "S100WRZH", sourcePage: "設備の状況", reason: "億円", createdBy: "t"),
                ManualXbrlOverrideRecord(
                    edinetCode: "E03614", periodEnd: "2025-03-31", item: .policyHoldingSecurities,
                    payload: .policyHoldingSecurities(
                        PolicyHoldingSecuritiesManualOverridePayload(
                            securities: rows, policyHoldingSummary: nil)),
                    sourceDocID: "S100WRZH", sourcePage: "提出会社の状況", reason: "70 names",
                    createdBy: "t"),
            ])
        #expect(applied.capexMillionYen == 370_500)
        #expect(applied.capexNeedsReview == false)
        #expect(applied.policyHoldings?.securities?.count == 70)
        #expect(applied.policyHoldingsNeedsReview == false)
        #expect(applied.otherNeedsReview == true)
    }
}
