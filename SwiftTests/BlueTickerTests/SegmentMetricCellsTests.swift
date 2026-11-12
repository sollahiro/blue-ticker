// segment 行へ報告セグメント表のセルを member 名で載せる純関数と、その公開 JSON の形。
// 金額はトヨタ 7203 S100Y8NY の格納行（capex / equity_method_investments 軸）から。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct SegmentMetricCellsTests {
    private func row(_ labelRaw: String, _ kind: String, amount: Double = 0) -> BreakdownRowPayload {
        BreakdownRowPayload(labelRaw: labelRaw, label: labelRaw, amount: amount, profit: nil, rowKind: kind)
    }

    private var segment: BreakdownSnapshotPayload {
        BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: 50_684_952_000_000, denominatorTag: "Revenue",
            rows: [
                row("AutomotiveReportableSegmentMember", "segment", amount: 45_201_924_000_000),
                row("FinancialServicesReportableSegmentMember", "segment", amount: 4_819_003_000_000),
                row("OtherReportableSegmentsMember", "segment", amount: 664_026_000_000),
                row("CorporateExpensesAndEliminationMember", "reconciling"),
            ],
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
    }

    private var capex: BreakdownSnapshotPayload {
        var automotive = row("AutomotiveReportableSegmentMember", "segment")
        automotive.segmentAssets = 33_182_372_000_000
        automotive.flow = 2_453_641_000_000
        var corporate = row("CorporateExpensesAndEliminationMember", "reconciling")
        corporate.segmentAssets = 14_532_118_000_000
        var total = row("EntityTotal", breakdownRowKindEntityTotal)
        total.segmentAssets = 105_522_331_000_000
        return BreakdownSnapshotPayload(
            axis: breakdownAxisCapex, denominator: 0, denominatorTag: "",
            rows: [automotive, corporate, total],
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [],
            flowMetric: capexFlowMetricCapitalExpenditures,
            segmentAssets: CapexMetricTotalsPayload(denominator: 105_522_331_000_000, denominatorTag: "Assets"),
            flow: CapexMetricTotalsPayload(denominator: 6_059_779_000_000, denominatorTag: "CapitalExpenditures"))
    }

    private var equity: BreakdownSnapshotPayload {
        BreakdownSnapshotPayload(
            axis: breakdownAxisEquityMethodInvestments, denominator: 5_342_548_000_000,
            denominatorTag: "InvestmentsAccountedForUsingEquityMethodIFRS",
            rows: [
                row("AutomotiveReportableSegmentMember", "segment", amount: 4_763_577_000_000),
                row("EntityTotal", "subtotal", amount: 5_342_548_000_000),
            ],
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
    }

    @Test func mergesCellsByMemberName() {
        let merged = SegmentMetricCells.merge(segment: segment, capex: capex, equityMethod: equity)
        #expect(merged.rows.count == 4)
        #expect(merged.rows[0].segmentAssets == 33_182_372_000_000)
        #expect(merged.rows[0].flow == 2_453_641_000_000)
        #expect(merged.rows[0].equityMethodInvestments == 4_763_577_000_000)
        #expect(merged.rows[1].segmentAssets == nil)
        #expect(merged.rows[3].segmentAssets == 14_532_118_000_000)
        #expect(merged.rows[0].amount == 45_201_924_000_000)
        #expect(merged.denominator == 50_684_952_000_000)
        #expect(merged.segmentAssets?.denominator == 105_522_331_000_000)
        #expect(merged.flow?.denominator == 6_059_779_000_000)
        #expect(merged.flowMetric == capexFlowMetricCapitalExpenditures)
        #expect(merged.equityMethodInvestments?.denominator == 5_342_548_000_000)
        #expect(merged.warnings.isEmpty)
    }

    @Test func unmatchedMembersAreDroppedWithWarning() {
        var extra = row("AllOtherReportableSegmentMember", "segment")
        extra.segmentAssets = 1
        var withExtra = capex
        withExtra.rows.append(extra)
        let merged = SegmentMetricCells.merge(segment: segment, capex: withExtra, equityMethod: nil)
        #expect(merged.rows.count == 4)
        #expect(merged.warnings == [SegmentMetricCells.warningUnmatchedRows])
        #expect(merged.equityMethodInvestments == nil)
    }

    @Test func noMetricsLeavesSegmentUnchanged() {
        #expect(SegmentMetricCells.merge(segment: segment, capex: nil, equityMethod: nil) == segment)
    }

    @Test func jsonOmitsAmountOnSegmentAxis() throws {
        let plain = segment.jsonObject()
        #expect(plain["amount"] == nil)
        #expect(plain["denominator"] == nil)
        let plainRows = try #require(plain["rows"] as? [[String: Any]])
        #expect(plainRows[0]["amount"] == nil)
        #expect(plainRows[0][capexCellSegmentAssets] == nil)
    }

    @Test func rowCellRoundTripsThroughCodable() throws {
        var source = row("AutomotiveReportableSegmentMember", "segment", amount: 1)
        source.equityMethodInvestments = 2
        let decoded = try JSONDecoder().decode(
            BreakdownRowPayload.self, from: JSONEncoder().encode(source))
        #expect(decoded.equityMethodInvestments == 2)
    }

    @Test func equityMethodAxisIsRetired() {
        #expect(retiredBreakdownAxes.contains(breakdownAxisEquityMethodInvestments))
        #expect(isSupportedBreakdownAxis(breakdownAxisEquityMethodInvestments) == false)
        #expect(segmentBreakdownCacheVersion == "breakdown-segment-v3")
    }
}
