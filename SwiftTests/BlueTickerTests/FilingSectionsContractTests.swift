import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct FilingSectionsContractTests {
    @Test func cacheVersionNumberParsesSectionsVN() {
        #expect(filingSectionsCacheVersionNumber("sections-v1") == 1)
        #expect(filingSectionsCacheVersionNumber("sections-v2") == 2)
        #expect(filingSectionsCacheVersionNumber("sections-v10") == 10)
        #expect(filingSectionsCacheVersionNumber("sections-v") == nil)
        #expect(filingSectionsCacheVersionNumber("old") == nil)
        #expect(filingSectionsCacheVersionNumber("fin-v2") == nil)
    }

    @Test func isServableUsesNumericFloorNotLexicographicOrder() throws {
        #expect(filingSectionsMinServableVersion == 1)
        #expect(isServableFilingSectionsCacheVersion("sections-v1") == true)
        #expect(isServableFilingSectionsCacheVersion("sections-v2") == true)
        #expect(isServableFilingSectionsCacheVersion("sections-v10") == true)
        #expect(isServableFilingSectionsCacheVersion("old") == false)
        let current = try #require(filingSectionsCacheVersionNumber(filingSectionsCacheVersion))
        #expect(current >= filingSectionsMinServableVersion)
    }
}
