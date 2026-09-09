import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct BreakdownContractTests {
    @Test func htmlExtractorSharedPathBumpsBusinessWithGeography() throws {
        let businessN = try #require(breakdownCacheVersionNumber(businessBreakdownCacheVersion))
        let geographyN = try #require(breakdownCacheVersionNumber(geographyBreakdownCacheVersion))
        #expect(businessN == 12)
        #expect(geographyN == 12)
        #expect(try #require(breakdownCacheVersionNumber("breakdown-business-v11")) < businessN)
        #expect(try #require(breakdownCacheVersionNumber("breakdown-geography-v11")) < geographyN)
        // fact-only axes do not share allTablesFromHtml / keywordTablesFromHtml.
        #expect(employeesBreakdownCacheVersion == "breakdown-employees-v1")
        #expect(researchAndDevelopmentBreakdownCacheVersion == "breakdown-research-and-development-v1")
        #expect(goodwillBreakdownCacheVersion == "breakdown-goodwill-v1")
        #expect(segmentAssetsBreakdownCacheVersion == "breakdown-segment-assets-v2")
    }
}
