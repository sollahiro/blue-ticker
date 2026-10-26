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
        #expect(rows.first?["in_total"] as? Bool == true)
        let closing = try #require(json[goodwillCellClosing] as? [String: Any])
        #expect(closing["status"] as? String == goodwillCellStatusDisclosed)
        #expect(closing["denominator_tag"] as? String == "Goodwill")
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
            fact(
                tag: "Goodwill", member: "MetarsSegmentsReportableSegmentMember",
                value: 235_000_000,
                context: "CurrentYearInstant_MetarsSegmentsReportableSegmentMember"),
        ]
        let labels = [
            "AluminumAndCopperReportableSegmentsMember": "アルミ・銅",
            "MetalsSubtotalReportableSegmentsMember": "金属小計",
            "MetarsSegmentsReportableSegmentMember": "金属セグメント",
        ]
        let snapshot = try #require(
            BreakdownNormalizer.normalizeGoodwill(
                facts: facts, total: 235_000_000, totalTag: "Goodwill",
                axis: breakdownAxisGoodwill, labelsByTag: labels))
        let aluminum = try #require(
            snapshot.rows.first { $0.labelRaw == "AluminumAndCopperReportableSegmentsMember" })
        let subtotal = try #require(
            snapshot.rows.first { $0.labelRaw == "MetalsSubtotalReportableSegmentsMember" })
        let grouped = try #require(
            snapshot.rows.first { $0.labelRaw == "MetarsSegmentsReportableSegmentMember" })
        #expect(aluminum.rowKind == "segment")
        #expect(subtotal.rowKind == "subtotal")
        #expect(grouped.rowKind == "subtotal")
        #expect(snapshot.denominator == 235_000_000)
        #expect(snapshot.needsReview == false)
    }

    /// 9537 S100YIW6 型。`XxxSegmentsReportableSegmentsMember` は葉のセグメント名にも使われる。
    @Test func segmentsReportableSegmentsLeafNamesStaySegments() throws {
        let facts = [
            fact(
                tag: "NumberOfEmployees", member: "LPGSegmentsReportableSegmentsMember", value: 12,
                context: "CurrentYearInstant_LPGSegmentsReportableSegmentsMember"),
            fact(
                tag: "NumberOfEmployees", member: "PlumingSegmentsReportableSegmentsMember", value: 67,
                context: "CurrentYearInstant_PlumingSegmentsReportableSegmentsMember"),
            fact(
                tag: "NumberOfEmployees", member: "CorporateSharedMember", value: 21,
                context: "CurrentYearInstant_CorporateSharedMember"),
        ]
        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 100, axis: breakdownAxisEmployees))
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw).sorted()
        #expect(segments == ["LPGSegmentsReportableSegmentsMember", "PlumingSegmentsReportableSegmentsMember"])
        #expect(snapshot.needsReview == false)
    }

    /// 1605 S100L16P 型。報告セグメント計＋全社だけの従業員表は報告セグメントを segment に残す。
    @Test func soleReportableSegmentsMemberWithCorporateSharedIsSegment() throws {
        let facts = [
            fact(
                tag: "NumberOfEmployees", member: "ReportableSegmentsMember", value: 2_893,
                context: "CurrentYearInstant_ReportableSegmentsMember"),
            fact(
                tag: "NumberOfEmployees", member: "CorporateSharedMember", value: 270,
                context: "CurrentYearInstant_CorporateSharedMember"),
        ]
        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 3_163, axis: breakdownAxisEmployees))
        let row = try #require(snapshot.rows.first { $0.labelRaw == "ReportableSegmentsMember" })
        #expect(row.rowKind == "segment")
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
        let json = payload.jsonObject()
        let impairment = try #require(json[goodwillCellImpairment] as? [String: Any])
        #expect(impairment["status"] as? String == goodwillCellStatusNoneDisclosed)
        #expect(impairment["denominator"] as? Double == 0)
        #expect(impairment["denominator_tag"] is NSNull)
        #expect(json[goodwillCellAmortization] is NSNull)
    }

    @Test func subtotalRowIsNotInTotal() throws {
        let closing = BreakdownSnapshot(
            axis: breakdownAxisGoodwill, denominator: 100, denominatorTag: "Goodwill",
            rows: [
                BreakdownRow(
                    labelRaw: "AMember", label: "A", amount: 100, share: 1, profit: nil,
                    rowKind: "segment"),
                BreakdownRow(
                    labelRaw: "ReportableSegmentsMember", label: "報告セグメント計", amount: 100,
                    share: nil, profit: nil, rowKind: "subtotal"),
            ],
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
        let payload = try #require(
            GoodwillNormalizer.assemble(
                opening: nil, closing: closing, amortization: nil, impairment: nil))
        let rows = try #require(payload.jsonObject()["rows"] as? [[String: Any]])
        let inTotal = Dictionary(
            uniqueKeysWithValues: rows.map { ($0["label_raw"] as! String, $0["in_total"] as! Bool) })
        #expect(inTotal == ["AMember": true, "ReportableSegmentsMember": false])
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
        let note = """
            【報告セグメントごとののれんの償却額及び未償却残高に関する情報】
            前連結会計年度（自 2024年４月１日 至 2025年３月31日）
            記載すべき該当事項はありません。
            当連結会計年度（自 2025年４月１日 至 2026年３月31日）
            のれんの償却額及び未償却残高は、報告セグメントに配分しておりません。
            のれんの償却額は発生しておりません。
            【報告セグメントごとの固定資産の減損損失に関する情報】
            前連結会計年度 該当事項はありません。
            当連結会計年度 該当事項はありません。
            """
        let prior = GoodwillNoteText.headingPeriod(
            note, heading: GoodwillNoteText.goodwillAmortizationHeading, current: false)
        let currentImp = GoodwillNoteText.headingPeriod(
            note, heading: GoodwillNoteText.segmentImpairmentHeading, current: true)
        #expect(GoodwillNoteText.isNoneDisclosed(prior))
        #expect(GoodwillNoteText.isNoneDisclosed(currentImp))
        #expect(GoodwillNoteText.isUnallocated(note))
    }

    @Test func amortizationDenominatorFallsBackToReportableSegmentsMember() throws {
        let facts = [
            fact(
                tag: "AmortizationOfGoodwillSGA", member: "RetailBusinessUnitReportableSegmentMember",
                value: 9_462_000_000, context: "CurrentYearDuration_Retail"),
            fact(
                tag: "AmortizationOfGoodwillSGA", member: "GlobalBusinessUnitReportableSegmentMember",
                value: 13_754_000_000, context: "CurrentYearDuration_Global"),
            fact(
                tag: "AmortizationOfGoodwillSGA",
                member: "HeadOfficeAccountsEtcReportableSegmentMember",
                value: 9_695_000_000, context: "CurrentYearDuration_Head"),
            fact(
                tag: "AmortizationOfGoodwillSGA", member: "ReportableSegmentsMember",
                value: 32_912_000_000, context: "CurrentYearDuration_ReportableSegmentsMember"),
        ]
        let snapshot = try #require(BreakdownNormalizer.normalizeGoodwillAmortization(facts: facts))
        #expect(snapshot.denominator == 32_912_000_000)
        #expect(snapshot.denominator != 32_911_000_000)
    }

    @Test func assembleMergesAdjustmentAndUnallocatedReconciling() throws {
        let closing = BreakdownSnapshot(
            axis: breakdownAxisGoodwill, denominator: 12_341_000, denominatorTag: "Goodwill",
            rows: [
                BreakdownRow(
                    labelRaw: "UnallocatedAmountsAndEliminationMember", label: "全社・消去",
                    amount: 12_341_000, share: 1, profit: nil, rowKind: "reconciling")
            ],
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
        let amortization = BreakdownSnapshot(
            axis: breakdownAxisGoodwill, denominator: 3_702_000,
            denominatorTag: "AmortizationOfGoodwillSGA",
            rows: [
                BreakdownRow(
                    labelRaw: "ReconcilingItemsMember", label: "調整額",
                    amount: 3_702_000, share: 1, profit: nil, rowKind: "reconciling")
            ],
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
        let payload = try #require(
            GoodwillNormalizer.assemble(
                opening: nil, closing: closing, amortization: amortization, impairment: nil))
        let reconciling = payload.rows.filter { $0.rowKind == "reconciling" }
        #expect(reconciling.count == 1)
        #expect(reconciling.first?.label == "全社・消去")
        #expect(reconciling.first?.closing == 12_341_000)
        #expect(reconciling.first?.amortization == 3_702_000)
        #expect(payload.amortization?.denominator == 3_702_000)
    }
}
