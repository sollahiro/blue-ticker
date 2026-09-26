import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct XbrlOverlayRegressionTests {
    private let holdingTag =
        "NumberOfSharesHeldDetailsOfSpecifiedInvestmentEquitySecuritiesHeldForPurposesOtherThanPureInvestmentReportingCompany"
    private let originalDocID = "S100W0S7"

    private func rowMembers(_ count: Int, value: Double = 1) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: (1...count).map {
            ("CurrentYearInstant_Row\($0)Member", value)
        })
    }

    /// 8316: 後の訂正が ~13 行で ~70 行表を置換しようとすると表だけ戻し、70 を残す。
    @Test func smfgShapeKeepsSeventyRowsWhenLaterCorrectionHasThirteen() throws {
        let original: [String: [String: Double]] = [holdingTag: rowMembers(13)]
        let wrzh: [String: [String: Double]] = [holdingTag: rowMembers(70)]
        let x7dx: [String: [String: Double]] = [holdingTag: rowMembers(13)]
        let (facts, skipped) = applyGuardedXbrlOverlays(
            base: original,
            layers: [
                (correctionDocID: "S100WRZH", facts: wrzh),
                (correctionDocID: "S100X7DX", facts: x7dx),
            ],
            originalDocID: originalDocID)
        #expect(facts[holdingTag]?.filter({ isRowMemberContext($0.key) }).count == 70)
        #expect(skipped.contains { $0.kind == xbrlOverlayRegressionKindRowLoss })
        #expect(skipped.contains { $0.correctionDocID == "S100X7DX" })
        #expect(skipped.allSatisfy { $0.correctionDocID != "S100WRZH" })
        let loss = try #require(skipped.first { $0.kind == xbrlOverlayRegressionKindRowLoss })
        #expect(loss.beforeCount == 70)
        #expect(loss.afterCount == 13)
        #expect(loss.originalDocID == originalDocID)
    }

    /// 8316 WRZH: 100 倍の設備投資訂正と 70 行表が同じレイヤなら両方採用する。
    @Test func smfgShapeAppliesCapexScaleChangeAndSeventyRowTable() throws {
        let capex = "CapitalExpendituresOverviewOfCapitalExpendituresEtc"
        let original: [String: [String: Double]] = [
            holdingTag: rowMembers(13),
            capex: ["CurrentYearDuration": 3_705_000_000],
        ]
        let wrzh: [String: [String: Double]] = [
            holdingTag: rowMembers(70),
            capex: ["CurrentYearDuration": 370_500_000_000],
        ]
        let x7dx: [String: [String: Double]] = [
            holdingTag: rowMembers(13),
            "NetSales": ["CurrentYearDuration": 99],
        ]
        let (facts, skipped) = applyGuardedXbrlOverlays(
            base: original,
            layers: [
                (correctionDocID: "S100WRZH", facts: wrzh),
                (correctionDocID: "S100X7DX", facts: x7dx),
            ],
            originalDocID: originalDocID)
        #expect(facts[holdingTag]?.filter({ isRowMemberContext($0.key) }).count == 70)
        #expect(facts[capex]?["CurrentYearDuration"] == 370_500_000_000)
        #expect(facts["NetSales"]?["CurrentYearDuration"] == 99)
        #expect(skipped.contains { $0.kind == xbrlOverlayRegressionKindRowLoss })
        #expect(skipped.contains { $0.correctionDocID == "S100X7DX" })
        #expect(
            skipped.allSatisfy {
                $0.kind != xbrlOverlayRegressionKindScaleJump
            })
        #expect(skipped.allSatisfy { $0.correctionDocID != "S100WRZH" })
    }

    @Test func smallRowLossStillApplies() {
        let before: [String: [String: Double]] = [holdingTag: rowMembers(10)]
        let after: [String: [String: Double]] = [holdingTag: rowMembers(8)]
        let found = xbrlOverlayRegressions(
            before: before, after: after, originalDocID: originalDocID, correctionDocID: "S100X7DX")
        #expect(found.isEmpty)
        let (facts, skipped) = applyGuardedXbrlOverlays(
            base: before, layers: [(correctionDocID: "S100X7DX", facts: after)],
            originalDocID: originalDocID)
        #expect(skipped.isEmpty)
        #expect(facts[holdingTag]?.count == 8)
    }

    @Test func scaleJumpExplicitReplacementIsApplied() {
        let before: [String: [String: Double]] = [
            "NetSales": ["CurrentYearDuration": 100],
        ]
        let after: [String: [String: Double]] = [
            "NetSales": ["CurrentYearDuration": 1_000],
        ]
        let (facts, skipped) = applyGuardedXbrlOverlays(
            base: before, layers: [(correctionDocID: "S100X7DX", facts: after)],
            originalDocID: originalDocID)
        #expect(facts["NetSales"]?["CurrentYearDuration"] == 1_000)
        #expect(skipped.isEmpty)
    }

    @Test func scaleJumpInconsistentRelatedContextsRevertsOnlyThatFact() {
        let before: [String: [String: Double]] = [
            "NetSales": ["CurrentYearDuration": 100, "Prior1YearDuration": 90],
            "OperatingIncome": ["CurrentYearDuration": 20],
        ]
        let overlay: [String: [String: Double]] = [
            "NetSales": ["CurrentYearDuration": 1_000, "Prior1YearDuration": 90],
            "OperatingIncome": ["CurrentYearDuration": 21],
        ]
        let (facts, skipped) = applyGuardedXbrlOverlays(
            base: before, layers: [(correctionDocID: "S100X7DX", facts: overlay)],
            originalDocID: originalDocID)
        #expect(facts["NetSales"]?["CurrentYearDuration"] == 100)
        #expect(facts["NetSales"]?["Prior1YearDuration"] == 90)
        #expect(facts["OperatingIncome"]?["CurrentYearDuration"] == 21)
        #expect(skipped.contains { $0.kind == xbrlOverlayRegressionKindScaleJump })
        #expect(skipped.contains { $0.tag == "NetSales" && $0.contextRef == "CurrentYearDuration" })
    }

    @Test func brokenReconcileRevertsTableAndKeepsOtherFacts() {
        let stem = "CurrentYearInstant"
        let before: [String: [String: Double]] = [
            holdingTag: [
                stem: 60,
                "\(stem)_Row1Member": 10,
                "\(stem)_Row2Member": 20,
                "\(stem)_Row3Member": 30,
            ],
            "NetSales": ["CurrentYearDuration": 100],
        ]
        let after: [String: [String: Double]] = [
            holdingTag: [
                stem: 60,
                "\(stem)_Row1Member": 10,
                "\(stem)_Row2Member": 20,
                "\(stem)_Row3Member": 40,
            ],
            "NetSales": ["CurrentYearDuration": 105],
        ]
        let (facts, skipped) = applyGuardedXbrlOverlays(
            base: before, layers: [(correctionDocID: "S100X7DX", facts: after)],
            originalDocID: originalDocID)
        #expect(facts[holdingTag]?["\(stem)_Row3Member"] == 30)
        #expect(facts["NetSales"]?["CurrentYearDuration"] == 105)
        #expect(skipped.contains { $0.kind == xbrlOverlayRegressionKindReconcile })
    }

    @Test func recordingOverlayRegressionsMarksNoteNeedsReview() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blt-overlay-reg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let regression = XbrlOverlayRegression(
            originalDocID: originalDocID, correctionDocID: "S100X7DX",
            kind: xbrlOverlayRegressionKindRowLoss, tag: holdingTag, beforeCount: 70,
            afterCount: 13)
        writeOverlayRegressions([regression], originalDocID: originalDocID, to: dir)
        let stamped = statementNoteByRecordingOverlayRegressions(
            .resolved(
                payload: StatementNotePayload(
                    securities: [
                        PolicyHoldingSecurityPayload(
                            issuerName: "A", numberOfShares: 1, carryingAmount: 1, purpose: nil)
                    ],
                    needsReview: false),
                source: statementNoteSourceXbrlFacts, contentHash: "h"),
            xbrlDir: dir)
        guard case .resolved(let payload, _, _) = stamped else {
            Issue.record("expected resolved note")
            return
        }
        #expect(payload.needsReview)
        #expect(hasOverlayRegressionWarning(payload.warnings))
        #expect(payload.securities?.count == 1)
        #expect(
            !isPubliclyServableStatementNote(
                needsReview: payload.needsReview, warnings: payload.warnings))
        let parsed = try #require(parseXbrlOverlayRegressionWarning(payload.warnings[0]))
        #expect(parsed.kind == xbrlOverlayRegressionKindRowLoss)
        #expect(parsed.correctionDocID == "S100X7DX")
        #expect(parsed.originalDocID == originalDocID)
        #expect(parsed.tag == holdingTag)
        #expect(parsed.before == "70")
        #expect(parsed.after == "13")
        #expect(
            xbrlOverlayRegressionLogMessage(
                code: "8316", fy: "2025-03-31", originalDocID: originalDocID,
                correctionDocID: "S100X7DX", reason: parsed.kind)
                .contains("code=8316"))
        let unrelated = statementNoteByRecordingOverlayRegressions(
            .resolved(
                payload: StatementNotePayload(value: 12.3, unit: "yen_per_share"),
                source: statementNoteSourceXbrlFacts, contentHash: "eps"),
            xbrlDir: dir)
        guard case .resolved(let other, _, _) = unrelated else {
            Issue.record("expected resolved unrelated note")
            return
        }
        #expect(!other.needsReview)
        #expect(!hasOverlayRegressionWarning(other.warnings))
    }

    @Test func recordingOverlayRegressionsHidesXbrlFactsBreakdown() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blt-overlay-reg-bd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        writeOverlayRegressions(
            [
                XbrlOverlayRegression(
                    originalDocID: originalDocID, correctionDocID: "S100WRZH",
                    kind: xbrlOverlayRegressionKindScaleJump,
                    tag: "CapitalExpendituresOverviewOfCapitalExpendituresEtc",
                    contextRef: "CurrentYearDuration", beforeValue: 3_705_000_000,
                    afterValue: 370_500_000_000)
            ], originalDocID: originalDocID, to: dir)
        let stamped = breakdownByRecordingOverlayRegressions(
            .resolved(
                payload: BreakdownSnapshotPayload(
                    axis: breakdownAxisCapitalExpendituresOverview, denominator: 1,
                    denominatorTag: "capex", rows: [], sourceKind: breakdownSourceXbrlFacts,
                    needsReview: false, warnings: []),
                source: breakdownSourceXbrlFacts, contentHash: "h", audit: nil),
            xbrlDir: dir)
        guard case .resolved(let payload, let source, _, _) = stamped else {
            Issue.record("expected resolved breakdown")
            return
        }
        #expect(payload.needsReview)
        #expect(source == breakdownSourceXbrlFacts)
        #expect(
            !isPubliclyServableBreakdown(
                source: source, needsReview: payload.needsReview, warnings: payload.warnings))
        let unrelated = breakdownByRecordingOverlayRegressions(
            .resolved(
                payload: BreakdownSnapshotPayload(
                    axis: breakdownAxisBusiness, denominator: 1, denominatorTag: "sales",
                    rows: [], sourceKind: breakdownSourceXbrlFacts, needsReview: false,
                    warnings: []),
                source: breakdownSourceXbrlFacts, contentHash: "h", audit: nil),
            xbrlDir: dir)
        guard case .resolved(let other, _, _, _) = unrelated else {
            Issue.record("expected resolved unrelated breakdown")
            return
        }
        #expect(!other.needsReview)
        #expect(!hasOverlayRegressionWarning(other.warnings))
    }
}
