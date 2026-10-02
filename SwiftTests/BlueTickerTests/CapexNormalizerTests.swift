// SPEC_ORACLE / SPEC_INVARIANT: capex マトリクスの組み立て。
// 書類単位のフロー選択、EntityTotal、欠測 null、HTML ラベル非結合。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct CapexNormalizerTests {
    private func fact(
        tag: String, member: String?, value: Double, instant: Bool = false
    ) -> BreakdownFact {
        let period = instant ? "CurrentYearInstant" : "CurrentYearDuration"
        let context: String
        let dimensions: [String: String]
        if let member {
            context = "\(period)_\(member)"
            dimensions = ["OperatingSegmentsAxis": member]
        } else {
            context = period
            dimensions = [:]
        }
        return BreakdownFact(
            tag: tag, contextRef: context, dimensions: dimensions, value: value,
            label: nil, unitRef: "JPY", decimals: "0")
    }

    @Test func prefersCapitalExpendituresOverNoncurrentAdditionsAtDocumentLevel() {
        #expect(
            CapexNormalizer.flowMetric(
                capitalExpendituresPresent: true, noncurrentAssetAdditionsPresent: true)
                == capexFlowMetricCapitalExpenditures)
        #expect(
            CapexNormalizer.flowMetric(
                capitalExpendituresPresent: false, noncurrentAssetAdditionsPresent: true)
                == capexFlowMetricNoncurrentAssetAdditions)
        #expect(
            CapexNormalizer.flowMetric(
                capitalExpendituresPresent: false, noncurrentAssetAdditionsPresent: false) == nil)
    }

    @Test func doesNotMixCapitalExpendituresAndAdditionsOnTheSameFiling() throws {
        let facts = [
            fact(tag: "CapitalExpendituresIFRS", member: "SegAMember", value: 10),
            fact(tag: "AdditionsToNoncurrentAssetsIFRS", member: "SegAMember", value: 999),
            fact(tag: "CapitalExpendituresIFRS", member: nil, value: 10),
            fact(tag: "AssetsIFRS", member: "SegAMember", value: 100, instant: true),
            fact(tag: "AssetsIFRS", member: nil, value: 100, instant: true),
        ]
        let snapshot = try #require(
            CapexNormalizer.normalize(
                facts: facts, capitalExpendituresPresent: true,
                noncurrentAssetAdditionsPresent: true))
        #expect(snapshot.axis == breakdownAxisCapex)
        #expect(snapshot.flowMetric == capexFlowMetricCapitalExpenditures)
        #expect(snapshot.flow?.denominator == 10)
        #expect(snapshot.flow?.denominatorTag == "CapitalExpendituresIFRS")
        let segment = try #require(snapshot.rows.first { $0.rowKind == "segment" })
        #expect(segment.flow == 10)
        #expect(segment.flow != 999)
        #expect(segment.segmentAssets == 100)
        let json = snapshot.jsonObject()
        #expect(json["amount"] == nil)
        #expect(json["denominator"] == nil)
        #expect(json["flow_metric"] as? String == capexFlowMetricCapitalExpenditures)
        let rows = try #require(json["rows"] as? [[String: Any]])
        #expect(rows.first?["amount"] == nil)
        #expect(rows.first?[capexCellFlow] as? Double == 10)
    }

    @Test func usesNoncurrentAdditionsWhenCapitalExpendituresAreAbsent() throws {
        let facts = [
            fact(tag: "AdditionsToNoncurrentAssetsIFRS", member: "SegAMember", value: 20),
            fact(tag: "AdditionsToNoncurrentAssetsIFRS", member: nil, value: 20),
        ]
        let snapshot = try #require(
            CapexNormalizer.normalize(
                facts: facts, capitalExpendituresPresent: false,
                noncurrentAssetAdditionsPresent: true))
        #expect(snapshot.flowMetric == capexFlowMetricNoncurrentAssetAdditions)
        #expect(snapshot.flow?.denominator == 20)
        #expect(snapshot.segmentAssets == nil)
        let json = snapshot.jsonObject()
        #expect(json[capexCellSegmentAssets] is NSNull)
    }

    @Test func remapsEntityTotalRowKindAndLeavesOtherSubtotals() throws {
        let facts = [
            fact(tag: "AssetsIFRS", member: "SegAMember", value: 80, instant: true),
            fact(
                tag: "AssetsIFRS", member: "ReportableSegmentsMember", value: 80, instant: true),
            fact(tag: "AssetsIFRS", member: "ReconcilingItemsMember", value: 20, instant: true),
            fact(tag: "AssetsIFRS", member: nil, value: 100, instant: true),
        ]
        let snapshot = try #require(
            CapexNormalizer.normalize(
                facts: facts, capitalExpendituresPresent: false,
                noncurrentAssetAdditionsPresent: false))
        let entity = try #require(
            snapshot.rows.first { $0.labelRaw == Xbrl.entityTotalMemberName })
        #expect(entity.rowKind == breakdownRowKindEntityTotal)
        #expect(entity.segmentAssets == 100)
        let reconciling = try #require(snapshot.rows.first { $0.rowKind == "reconciling" })
        #expect(reconciling.segmentAssets == 20)
        #expect(snapshot.rows.contains { $0.rowKind == "subtotal" })
    }

    @Test func keepsHtmlOverviewRowsUnjoinedFromXbrlMembers() throws {
        let facts = [
            fact(tag: "AssetsIFRS", member: "HealthcareReportableSegmentsMember", value: 10, instant: true),
            fact(tag: "AssetsIFRS", member: nil, value: 10, instant: true),
        ]
        let html = try #require(
            BreakdownNormalizer.normalizeCapitalExpendituresOverview(
                segments: [
                    CapexSegmentPayload(
                        segmentName: "ヘルスケア", investmentAmount: 5, yoyPercent: nil,
                        description: "工場")
                ]))
        let snapshot = try #require(
            CapexNormalizer.normalize(
                facts: facts, capitalExpendituresPresent: false,
                noncurrentAssetAdditionsPresent: false, overviewHTML: html))
        let assetRow = try #require(
            snapshot.rows.first { $0.labelRaw == "HealthcareReportableSegmentsMember" })
        #expect(assetRow.segmentAssets == 10)
        #expect(assetRow.capitalExpendituresOverview == nil)
        let htmlRow = try #require(snapshot.rows.first { $0.labelRaw == "ヘルスケア" })
        #expect(htmlRow.capitalExpendituresOverview == 5)
        #expect(htmlRow.segmentAssets == nil)
        #expect(htmlRow.description == "工場")
    }

    @Test func returnsNilWhenNothingIsDisclosed() {
        #expect(
            CapexNormalizer.normalize(
                facts: [], capitalExpendituresPresent: false,
                noncurrentAssetAdditionsPresent: false) == nil)
    }

    @Test func companyTotalOnlyFlowLeavesRowsEmpty() throws {
        let snapshot = try #require(
            CapexNormalizer.normalize(
                facts: [], capitalExpendituresPresent: true,
                noncurrentAssetAdditionsPresent: false,
                flowCompanyTotal: (50, "CapitalExpendituresIFRS")))
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.flow?.denominator == 50)
        #expect(snapshot.flowMetric == capexFlowMetricCapitalExpenditures)
    }
}
