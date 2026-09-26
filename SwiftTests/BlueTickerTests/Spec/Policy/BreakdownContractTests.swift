import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct BreakdownContractTests {
    @Test func htmlExtractorSharedPathBumpsBusinessWithGeography() throws {
        let businessN = try #require(breakdownCacheVersionNumber(businessBreakdownCacheVersion))
        let geographyN = try #require(breakdownCacheVersionNumber(geographyBreakdownCacheVersion))
        #expect(businessN == 13)
        #expect(geographyN == 12)
        #expect(try #require(breakdownCacheVersionNumber("breakdown-business-v12")) < businessN)
        #expect(try #require(breakdownCacheVersionNumber("breakdown-geography-v11")) < geographyN)
        // fact-only axes do not share allTablesFromHtml / keywordTablesFromHtml.
        #expect(employeesBreakdownCacheVersion == "breakdown-employees-v1")
        #expect(researchAndDevelopmentBreakdownCacheVersion == "breakdown-research-and-development-v1")
        #expect(goodwillBreakdownCacheVersion == "breakdown-goodwill-v1")
        #expect(segmentAssetsBreakdownCacheVersion == "breakdown-segment-assets-v3")
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
    }

    @Test func publicServingLeavesXbrlAndNoneRowsUntouched() {
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
}
