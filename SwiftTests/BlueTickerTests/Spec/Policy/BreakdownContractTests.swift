import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct BreakdownContractTests {
    @Test func htmlExtractorSharedPathBumpsProductServiceWithGeography() throws {
        let productServiceN = try #require(breakdownCacheVersionNumber(productServiceBreakdownCacheVersion))
        let geographyN = try #require(breakdownCacheVersionNumber(geographyBreakdownCacheVersion))
        #expect(productServiceN == 2)
        #expect(geographyN == 14)
        #expect(try #require(breakdownCacheVersionNumber("breakdown-geography-v12")) < geographyN)
        #expect(productServiceBreakdownCacheVersion == "breakdown-product_service-v2")
        #expect(segmentBreakdownCacheVersion == "breakdown-segment-v3")
        #expect(isSupportedBreakdownAxis(breakdownAxisSegment))
        #expect(breakdownCacheVersion(forAxis: breakdownAxisSegment) == segmentBreakdownCacheVersion)
        #expect(breakdownCacheVersionNumber("breakdown-business-v15") == 15)
        // fact-only axes do not share allTablesFromHtml / keywordTablesFromHtml.
        #expect(employeesBreakdownCacheVersion == "breakdown-employees-v2")
        #expect(retiredBreakdownAxes.contains(breakdownAxisResearchAndDevelopment))
        #expect(isSupportedBreakdownAxis(breakdownAxisResearchAndDevelopment) == false)
        #expect(goodwillBreakdownCacheVersion == "breakdown-goodwill-v3")
        #expect(goodwillBreakdownMinServableVersion == 3)
        #expect(isServableBreakdown(
            source: breakdownSourceXbrlFacts, cacheVersion: "breakdown-goodwill-v2",
            axis: breakdownAxisGoodwill) == false)
        #expect(isServableBreakdown(
            source: breakdownSourceXbrlFacts, cacheVersion: goodwillBreakdownCacheVersion,
            axis: breakdownAxisGoodwill))
        #expect(retiredBreakdownAxes.contains(breakdownAxisGoodwillAmortization))
        #expect(isSupportedBreakdownAxis(breakdownAxisGoodwillAmortization) == false)
        #expect(segmentAssetsBreakdownCacheVersion == "breakdown-segment-assets-v4")
    }

    @Test func publicServingHidesNeedsReviewAndUnresolvedUnitLLMRows() {
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceRevenueRecognitionLLM, needsReview: true, warnings: [])
                == false)
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceSegmentInfoLLM, needsReview: false,
                warnings: [breakdownWarningLLMUnitUnresolved]) == false)
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceGeographyLLM, needsReview: false, warnings: []) == true)
        #expect(
            isPubliclyInsufficientRevenueRecognition(segmentCount: 1, emittedSum: 7_000_000))
        #expect(
            isPubliclyInsufficientRevenueRecognition(segmentCount: 2, emittedSum: 0))
        #expect(
            isPubliclyInsufficientRevenueRecognition(segmentCount: 2, emittedSum: 1) == false)
        let incidental = BreakdownRowPayload(
            labelRaw: "不動産賃貸管理事業に付随する収入",
            label: "不動産賃貸管理事業に付随する収入", amount: 7_000_000, profit: nil,
            rowKind: "segment")
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceRevenueRecognitionLLM, needsReview: false, warnings: [],
                rows: [incidental]) == false)
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceRevenueRecognitionLLM, needsReview: false, warnings: [],
                rows: [
                    BreakdownRowPayload(
                        labelRaw: "付随収入", label: "付随収入", amount: 0, profit: nil,
                        rowKind: "segment"),
                    BreakdownRowPayload(
                        labelRaw: "その他", label: "その他", amount: 0, profit: nil,
                        rowKind: "segment"),
                ]) == false)
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceRevenueRecognitionLLM, needsReview: false, warnings: [],
                rows: [
                    incidental,
                    BreakdownRowPayload(
                        labelRaw: "その他", label: "その他", amount: 1_000_000, profit: nil,
                        rowKind: "segment"),
                ]))
    }

    @Test func publicServingLeavesXbrlAndNoneRowsUntouched() {
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceSameAs, needsReview: false, warnings: []) == true)
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceXbrlFacts, needsReview: true, warnings: []) == true)
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceStackedSegmentPnL, needsReview: true,
                warnings: [breakdownWarningLLMUnitUnresolved]) == true)
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceNotApplicable, needsReview: true, warnings: []) == true)
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceXbrlFacts, needsReview: true,
                warnings: [
                    "overlay_regression:row_loss:S100X7DX:orig=S100W0S7:tag=Holding:before=70:after=13"
                ]) == false)
    }

    @Test func publicServingKeepsCapexProseTotal() throws {
        #expect(isVersionGatedBreakdownSource(breakdownSourceCapexProse))
        #expect(isLLMBreakdownSource(breakdownSourceCapexProse) == false)
        #expect(capexBreakdownCacheVersion == "breakdown-capex-v1")
        #expect(try #require(breakdownCacheVersionNumber(capexBreakdownCacheVersion)) == 1)
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceCapexProse, needsReview: false,
                warnings: [breakdownWarningNotAllocatableToSegments]) == true)
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceCapexProse, needsReview: true,
                warnings: [breakdownWarningCapexProseRemainder]) == true)
    }

    @Test func retiredCapexAxesAreUnsupported() {
        #expect(retiredBreakdownAxes.contains(breakdownAxisCapex))
        #expect(isSupportedBreakdownAxis(breakdownAxisCapex) == false)
        #expect(breakdownCacheVersion(forAxis: breakdownAxisCapex) == capexBreakdownCacheVersion)
        for axis in retiredBreakdownAxes {
            #expect(isSupportedBreakdownAxis(axis) == false)
            #expect(!breakdownSegmentMetricAxes.contains(axis))
        }
        #expect(isSupportedBreakdownAxis(breakdownAxisProductService))
        #expect(isSupportedBreakdownAxis("business") == false)
        #expect(retiredBreakdownAxes.contains("business"))
        #expect(breakdownAxisProductService == "product_service")
        #expect(!breakdownSegmentMetricAxes.contains(breakdownAxisSegmentAssets)
            || breakdownAxisSegmentAssets == capexCellSegmentAssets)
        #expect(!breakdownSegmentMetricAxes.contains(breakdownAxisCapex))
        #expect(segmentBreakdownMinServableVersion == 3)
        #expect(
            isServableBreakdown(
                source: breakdownSourceXbrlFacts, cacheVersion: "breakdown-segment-v2",
                axis: breakdownAxisSegment) == false)
        #expect(
            isServableBreakdown(
                source: breakdownSourceXbrlFacts, cacheVersion: segmentBreakdownCacheVersion,
                axis: breakdownAxisSegment))
    }

    @Test func roundingGapUsesDecimalsTimesRowCountAndDoesNotRoundValues() {
        #expect(segmentRoundingTolerance(decimals: -6, summedRowCount: 4) == 2_000_000)
        #expect(isSegmentRoundingGap(gap: 2_000_000, decimals: -6, summedRowCount: 4))
        #expect(isSegmentRoundingGap(gap: 2_000_001, decimals: -6, summedRowCount: 4) == false)
        #expect(isSegmentRoundingGap(gap: 1, decimals: nil, summedRowCount: 4) == false)
        let json = breakdownJSONAmount(1_583_719_000_000)
        #expect((json as? NSNumber)?.int64Value == 1_583_719_000_000)
    }

    @Test func publicServingFailsClosedForUnknownSources() {
        #expect(
            isPubliclyServableBreakdown(source: "unknown_llm", needsReview: true, warnings: [])
                == false)
        #expect(
            isPubliclyServableBreakdown(
                source: "unknown_llm", needsReview: false,
                warnings: [breakdownWarningLLMUnitUnresolved]) == false)
        #expect(
            isPubliclyServableBreakdown(source: "unknown_llm", needsReview: false, warnings: [])
                == true)
    }

    @Test func revenueRecognitionPayloadOmitsLabelAndRestoresOnRead() throws {
        let row = BreakdownRowPayload(
            labelRaw: "北米", label: "stored", amount: 1, profit: nil, rowKind: "segment",
            categoryGroup: "（海外）", category: "北米")
        #expect(row.label == "北米")
        let encoded = try JSONEncoder().encode(row)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["label"] == nil)
        #expect(object["category_group"] as? String == "（海外）")
        let decoded = try JSONDecoder().decode(BreakdownRowPayload.self, from: encoded)
        #expect(decoded.label == "北米")
        #expect(decoded.category == "北米")
        #expect(row.jsonObject()["label"] as? String == "北米")
        #expect(row.jsonObject()["category"] as? String == "北米")
    }

    @Test func geographyOfWhichRowExposesCategoryKeysOnRestObject() {
        let row = BreakdownRowPayload(
            labelRaw: "米国", label: "米国", amount: 7_624_333, profit: nil, rowKind: "subtotal",
            categoryGroup: "北米", category: "米国")
        let object = row.jsonObject()
        #expect(object["row_kind"] as? String == "subtotal")
        #expect(object["label"] as? String == "米国")
        #expect(object["category_group"] as? String == "北米")
        #expect(object["category"] as? String == "米国")
        let parent = BreakdownRowPayload(
            labelRaw: "北米", label: "北米", amount: 7_960_998, profit: nil, rowKind: "segment")
        #expect(parent.jsonObject()["category_group"] == nil)
        #expect(parent.jsonObject()["category"] == nil)
    }
}
