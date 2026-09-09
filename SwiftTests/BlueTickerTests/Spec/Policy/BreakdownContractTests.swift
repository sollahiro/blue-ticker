import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct BreakdownContractTests {
    @Test func htmlExtractorSharedPathBumpsBusinessWithGeography() throws {
        let businessN = try #require(breakdownCacheVersionNumber(businessBreakdownCacheVersion))
        let geographyN = try #require(breakdownCacheVersionNumber(geographyBreakdownCacheVersion))
        #expect(businessN == 11)
        #expect(geographyN == 11)
        #expect(try #require(breakdownCacheVersionNumber("breakdown-business-v10")) < businessN)
        // fact-only axes do not share allTablesFromHtml / keywordTablesFromHtml.
        #expect(employeesBreakdownCacheVersion == "breakdown-employees-v1")
        #expect(researchAndDevelopmentBreakdownCacheVersion == "breakdown-research-and-development-v1")
        #expect(goodwillBreakdownCacheVersion == "breakdown-goodwill-v1")
        #expect(segmentAssetsBreakdownCacheVersion == "breakdown-segment-assets-v2")
    }
}
