import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct CompanyOverviewContractTests {
    @Test func cacheVersionNumberParsesOverviewVN() {
        #expect(companyOverviewCacheVersionNumber("overview-v1") == 1)
        #expect(companyOverviewCacheVersionNumber("overview-v3") == 3)
        #expect(companyOverviewCacheVersionNumber("overview-v10") == 10)
        #expect(companyOverviewCacheVersionNumber("overview-v") == nil)
        #expect(companyOverviewCacheVersionNumber("overview-v0") == 0)
        #expect(companyOverviewCacheVersionNumber("old") == nil)
        #expect(companyOverviewCacheVersionNumber("fin-v2") == nil)
    }

    @Test func isServableUsesNumericFloorNotLexicographicOrder() throws {
        #expect(companyOverviewMinServableVersion == 1)
        #expect(isServableCompanyOverviewCacheVersion("overview-v1") == true)
        #expect(isServableCompanyOverviewCacheVersion("overview-v2") == true)
        #expect(isServableCompanyOverviewCacheVersion("overview-v3") == true)
        #expect(isServableCompanyOverviewCacheVersion("overview-v10") == true)
        #expect(isServableCompanyOverviewCacheVersion("overview-v0") == false)
        #expect(isServableCompanyOverviewCacheVersion("old") == false)
        let current = try #require(companyOverviewCacheVersionNumber(companyOverviewCacheVersion))
        #expect(current >= companyOverviewMinServableVersion)
    }
}
