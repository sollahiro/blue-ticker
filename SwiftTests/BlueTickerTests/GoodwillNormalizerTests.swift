import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct GoodwillNormalizerTests {
    private func fact(
        tag: String, member: String?, value: Double, context: String
    ) -> BreakdownFact {
        let dimensions: [String: String]
        if let member {
            dimensions = ["OperatingSegmentsAxis": member]
        } else {
            dimensions = [:]
        }
        return BreakdownFact(
            tag: tag, contextRef: context, dimensions: dimensions, value: value,
            label: nil, unitRef: "JPY", decimals: "0")
    }

    @Test func publicJsonOmitsAmountAndRetiredAxis() throws {
        let payload = GoodwillNormalizer.assemble(
            opening: nil,
            closing: BreakdownSnapshot(
                axis: breakdownAxisGoodwill, denominator: 100, denominatorTag: "Goodwill",
                rows: [
                    BreakdownRow(
                        labelRaw: "AMember", label: "A", amount: 100, share: 1, profit: nil,
                        rowKind: "segment")
                ],
                sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: []),
            amortization: nil, impairment: nil)
        let json = try #require(payload?.jsonObject())
        #expect(json["amount"] == nil)
        #expect(json["denominator"] == nil)
        let rows = try #require(json["rows"] as? [[String: Any]])
        #expect(rows.first?["amount"] == nil)
        #expect(rows.first?[goodwillCellClosing] as? Double == 100)
        #expect(retiredBreakdownAxes.contains(breakdownAxisGoodwillAmortization))
        #expect(isSupportedBreakdownAxis(breakdownAxisGoodwillAmortization) == false)
    }

    @Test func amortizationDenominatorUsesEntityTotalNotSegmentSum() throws {
        let facts = [
            fact(
                tag: "AmortizationOfGoodwillSGA", member: nil, value: 1_051_000_000,
                context: "CurrentYearDuration"),
            fact(
                tag: "AmortizationOfGoodwillSGA", member: "IPAndAnimeBusinessReportableSegmentMember",
                value: 794_000_000, context: "CurrentYearDuration_IPAndAnimeBusinessReportableSegmentMember"),
            fact(
                tag: "AmortizationOfGoodwillSGA", member: "RealEstateBusinessReportableSegmentsMember",
                value: 256_000_000, context: "CurrentYearDuration_RealEstateBusinessReportableSegmentsMember"),
        ]
        let snapshot = try #require(BreakdownNormalizer.normalizeGoodwillAmortization(facts: facts))
        #expect(snapshot.denominator == 1_051_000_000)
        #expect(snapshot.denominator != 1_050_000_000)
    }

    @Test func nestedSubtotalLabelIsNotAddedToSegmentSum() throws {
        let facts = [
            fact(
                tag: "Goodwill", member: nil, value: 235_000_000, context: "CurrentYearInstant"),
            fact(
                tag: "Goodwill", member: "AluminumAndCopperReportableSegmentsMember",
                value: 235_000_000,
                context: "CurrentYearInstant_AluminumAndCopperReportableSegmentsMember"),
            fact(
                tag: "Goodwill", member: "MetalsSubtotalReportableSegmentsMember",
                value: 235_000_000,
                context: "CurrentYearInstant_MetalsSubtotalReportableSegmentsMember"),
        ]
        let labels = [
            "AluminumAndCopperReportableSegmentsMember": "アルミ・銅",
            "MetalsSubtotalReportableSegmentsMember": "金属小計",
        ]
        let snapshot = try #require(
            BreakdownNormalizer.normalizeGoodwill(
                facts: facts, total: 235_000_000, totalTag: "Goodwill",
                axis: breakdownAxisGoodwill, labelsByTag: labels))
        let aluminum = try #require(
            snapshot.rows.first { $0.labelRaw == "AluminumAndCopperReportableSegmentsMember" })
        let subtotal = try #require(
            snapshot.rows.first { $0.labelRaw == "MetalsSubtotalReportableSegmentsMember" })
        #expect(aluminum.rowKind == "segment")
        #expect(subtotal.rowKind == "subtotal")
        #expect(snapshot.denominator == 235_000_000)
        #expect(snapshot.needsReview == false)
    }

    @Test func unallocatedReportableSegmentsMemberIsReconciling() throws {
        let facts = [
            fact(
                tag: "Goodwill", member: "ReportableSegmentsMember", value: 52_000_000,
                context: "CurrentYearInstant_ReportableSegmentsMember"),
            fact(
                tag: "Goodwill", member: nil, value: 52_000_000, context: "CurrentYearInstant"),
        ]
        let snapshot = try #require(
            BreakdownNormalizer.normalizeGoodwill(
                facts: facts, total: 52_000_000, totalTag: "Goodwill",
                axis: breakdownAxisGoodwill, unallocatedToReportableSegments: true))
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        let reconciling = snapshot.rows.filter { $0.rowKind == "reconciling" }
        #expect(segments.isEmpty)
        #expect(reconciling.count == 1)
        #expect(reconciling.first?.labelRaw == "ReportableSegmentsMember")
        #expect(reconciling.first?.amount == 52_000_000)
    }

    @Test func durationUnamortizedBalanceIsUsedWhenInstantSegmentFactsAreMissing() throws {
        let facts = [
            fact(
                tag: "UnamortizedBalanceOfGoodwill",
                member: "IPAndAnimeBusinessReportableSegmentMember",
                value: 15_448_000_000,
                context: "CurrentYearDuration_IPAndAnimeBusinessReportableSegmentMember"),
            fact(
                tag: "UnamortizedBalanceOfGoodwill", member: nil, value: 16_832_000_000,
                context: "CurrentYearDuration"),
        ]
        let snapshot = try #require(
            BreakdownNormalizer.normalizeGoodwill(
                facts: facts, total: 16_832_000_000, totalTag: "Goodwill",
                axis: breakdownAxisGoodwill))
        let anime = try #require(
            snapshot.rows.first { $0.labelRaw == "IPAndAnimeBusinessReportableSegmentMember" })
        #expect(anime.amount == 15_448_000_000)
        #expect(snapshot.denominator == 16_832_000_000)
    }

    @Test func impairmentLossELIsNotReadAsGoodwillImpairment() throws {
        let facts = [
            fact(
                tag: "ImpairmentLossEL",
                member: "AirConditioningAndRefrigerationEquipmentReportableSegmentsMember",
                value: 11_849_000_000,
                context:
                    "CurrentYearDuration_AirConditioningAndRefrigerationEquipmentReportableSegmentsMember"),
            fact(
                tag: "Goodwill",
                member: "AirConditioningAndRefrigerationEquipmentReportableSegmentsMember",
                value: 258_981_000_000,
                context:
                    "CurrentYearInstant_AirConditioningAndRefrigerationEquipmentReportableSegmentsMember"),
        ]
        #expect(BreakdownNormalizer.normalizeGoodwillImpairment(facts: facts) == nil)
        let payload = try #require(
            GoodwillNormalizer.normalize(facts: facts, companyClosingTotal: (
                258_981_000_000, "Goodwill"
            )))
        let air = try #require(
            payload.rows.first {
                $0.labelRaw == "AirConditioningAndRefrigerationEquipmentReportableSegmentsMember"
            })
        #expect(air.impairment == nil)
        #expect(air.closing == 258_981_000_000)
    }

    @Test func noneDisclosedFillsImpairmentZeroWithoutInventingOtherCells() throws {
        let closing = BreakdownSnapshot(
            axis: breakdownAxisGoodwill, denominator: 1_053_000_000, denominatorTag: "Goodwill",
            rows: [
                BreakdownRow(
                    labelRaw: "EuropeReportableSegmentsMember", label: "欧州",
                    amount: 1_053_000_000, share: 1, profit: nil, rowKind: "segment")
            ],
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
        let payload = try #require(
            GoodwillNormalizer.assemble(
                opening: nil, closing: closing, amortization: nil, impairment: nil,
                notes: GoodwillNoteFlags(
                    unallocatedToReportableSegments: false, openingNoneDisclosed: false,
                    amortizationNoneDisclosed: false, impairmentNoneDisclosed: true)))
        let europe = try #require(payload.rows.first)
        #expect(europe.impairment == 0)
        #expect(europe.amortization == nil)
        #expect(payload.impairment?.denominator == 0)
    }

    @Test func noneDisclosedTextHelpers() {
        #expect(GoodwillNoteText.isNoneDisclosed("該当事項はありません。"))
        #expect(
            GoodwillNoteText.isNoneDisclosed("セグメント情報に同様の情報を開示しているため、記載を省略しております。")
                == false)
        #expect(
            GoodwillNoteText.isUnallocated("のれんの償却額及び未償却残高は、報告セグメントに配分しておりません。"))
        #expect(
            GoodwillNoteText.isAmortizationNone("のれんの償却額は発生しておりません。"))
    }
}
