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

    @Test func ofWhichParentLabelDecodesIfPresentAndOmitsWhenNil() throws {
        let withParent = BreakdownRowPayload(
            labelRaw: "うち中国", label: "うち中国", amount: 8_900, profit: nil,
            rowKind: "of_which", parentLabel: "アジア")
        let encoded = try JSONEncoder().encode(withParent)
        let decoded = try JSONDecoder().decode(BreakdownRowPayload.self, from: encoded)
        #expect(decoded.parentLabel == "アジア")
        #expect(decoded.rowKind == "of_which")

        let legacy = """
            {"labelRaw":"日本","label":"日本","amount":38840,"profit":null,"rowKind":"segment"}
            """.data(using: .utf8)!
        let old = try JSONDecoder().decode(BreakdownRowPayload.self, from: legacy)
        #expect(old.parentLabel == nil)
        #expect(old.rowKind == "segment")
    }
}
