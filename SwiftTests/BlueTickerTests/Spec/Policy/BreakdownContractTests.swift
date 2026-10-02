import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct BreakdownContractTests {
    @Test func htmlExtractorSharedPathBumpsBusinessWithGeography() throws {
        let businessN = try #require(breakdownCacheVersionNumber(businessBreakdownCacheVersion))
        let geographyN = try #require(breakdownCacheVersionNumber(geographyBreakdownCacheVersion))
        #expect(businessN == 14)
        #expect(geographyN == 13)
        #expect(try #require(breakdownCacheVersionNumber("breakdown-business-v13")) < businessN)
        #expect(try #require(breakdownCacheVersionNumber("breakdown-geography-v12")) < geographyN)
        // fact-only axes do not share allTablesFromHtml / keywordTablesFromHtml.
        #expect(employeesBreakdownCacheVersion == "breakdown-employees-v2")
        #expect(researchAndDevelopmentBreakdownCacheVersion == "breakdown-research-and-development-v2")
        #expect(goodwillBreakdownCacheVersion == "breakdown-goodwill-v2")
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
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceXbrlFacts, needsReview: true,
                warnings: [
                    "overlay_regression:row_loss:S100X7DX:orig=S100W0S7:tag=Holding:before=70:after=13"
                ]) == false)
    }

    @Test func publicServingKeepsResearchAndDevelopmentProseTotal() {
        #expect(isVersionGatedBreakdownSource(breakdownSourceResearchAndDevelopmentProse))
        #expect(isLLMBreakdownSource(breakdownSourceResearchAndDevelopmentProse) == false)
        #expect(researchAndDevelopmentBreakdownCacheVersion == "breakdown-research-and-development-v2")
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceResearchAndDevelopmentProse, needsReview: false,
                warnings: [breakdownWarningNotAllocatableToSegments]) == true)
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceResearchAndDevelopmentProse, needsReview: true,
                warnings: [breakdownWarningNotAllocatableToSegments]) == true)
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceResearchAndDevelopmentProse, needsReview: false,
                warnings: [
                    breakdownWarningNotAllocatableToSegments,
                    "overlay_regression:row_loss:S100X7DX:orig=S100W0S7:tag=Holding:before=70:after=13",
                ]) == false)
    }

    @Test func publicServingKeepsCapexProseTotal() {
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

    @Test func retiredCapexAxesAreUnsupportedAndCapexIsSupported() {
        #expect(isSupportedBreakdownAxis(breakdownAxisCapex))
        #expect(breakdownCacheVersion(forAxis: breakdownAxisCapex) == capexBreakdownCacheVersion)
        for axis in retiredBreakdownAxes {
            #expect(isSupportedBreakdownAxis(axis) == false)
            #expect(!breakdownSegmentMetricAxes.contains(axis))
        }
        #expect(!breakdownSegmentMetricAxes.contains(breakdownAxisSegmentAssets)
            || breakdownAxisSegmentAssets == capexCellSegmentAssets)
        #expect(breakdownSegmentMetricAxes.contains(breakdownAxisCapex))
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
