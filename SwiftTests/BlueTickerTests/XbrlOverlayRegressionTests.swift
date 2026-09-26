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

    /// 8316: 後の訂正が ~13 行で ~70 行表を置換しようとすると needs_review 相当で 70 を残す。
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

    @Test func scaleJumpSkipsLayerAndKeepsOriginalValue() {
        let before: [String: [String: Double]] = [
            "NetSales": ["CurrentYearDuration": 100],
        ]
        let after: [String: [String: Double]] = [
            "NetSales": ["CurrentYearDuration": 1_000],
        ]
        let (facts, skipped) = applyGuardedXbrlOverlays(
            base: before, layers: [(correctionDocID: "S100X7DX", facts: after)],
            originalDocID: originalDocID)
        #expect(facts["NetSales"]?["CurrentYearDuration"] == 100)
        #expect(skipped.contains { $0.kind == xbrlOverlayRegressionKindScaleJump })
        #expect(skipped.contains { $0.correctionDocID == "S100X7DX" })
    }

    @Test func brokenReconcileSkipsLayerAndKeepsPriorRows() {
        let stem = "CurrentYearInstant"
        let before: [String: [String: Double]] = [
            holdingTag: [
                stem: 60,
                "\(stem)_Row1Member": 10,
                "\(stem)_Row2Member": 20,
                "\(stem)_Row3Member": 30,
            ]
        ]
        let after: [String: [String: Double]] = [
            holdingTag: [
                stem: 60,
                "\(stem)_Row1Member": 10,
                "\(stem)_Row2Member": 20,
                "\(stem)_Row3Member": 40,
            ]
        ]
        let (facts, skipped) = applyGuardedXbrlOverlays(
            base: before, layers: [(correctionDocID: "S100X7DX", facts: after)],
            originalDocID: originalDocID)
        #expect(facts[holdingTag]?["\(stem)_Row3Member"] == 30)
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
                payload: StatementNotePayload(value: 70, unit: "shares"),
                source: statementNoteSourceXbrlFacts, contentHash: "h"),
            xbrlDir: dir)
        guard case .resolved(let payload, _, _) = stamped else {
            Issue.record("expected resolved note")
            return
        }
        #expect(payload.needsReview)
        #expect(hasOverlayRegressionWarning(payload.warnings))
        #expect(payload.value == 70)
        #expect(
            !isPubliclyServableStatementNote(
                needsReview: payload.needsReview, warnings: payload.warnings))
        let parsed = try #require(parseXbrlOverlayRegressionWarning(payload.warnings[0]))
        #expect(parsed.kind == xbrlOverlayRegressionKindRowLoss)
        #expect(parsed.correctionDocID == "S100X7DX")
        #expect(parsed.originalDocID == originalDocID)
        #expect(
            xbrlOverlayRegressionLogMessage(
                code: "8316", fy: "2025-03-31", originalDocID: originalDocID,
                correctionDocID: "S100X7DX", reason: parsed.kind)
                .contains("code=8316"))
    }

    @Test func recordingOverlayRegressionsHidesXbrlFactsBreakdown() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blt-overlay-reg-bd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        writeOverlayRegressions(
            [
                XbrlOverlayRegression(
                    originalDocID: originalDocID, correctionDocID: "S100X7DX",
                    kind: xbrlOverlayRegressionKindScaleJump, tag: "NetSales",
                    contextRef: "CurrentYearDuration", beforeValue: 100, afterValue: 1_000)
            ], originalDocID: originalDocID, to: dir)
        let stamped = breakdownByRecordingOverlayRegressions(
            .resolved(
                payload: BreakdownSnapshotPayload(
                    axis: breakdownAxisBusiness, denominator: 1, denominatorTag: "sales",
                    rows: [], sourceKind: breakdownSourceXbrlFacts, needsReview: false,
                    warnings: []),
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
    }
}
