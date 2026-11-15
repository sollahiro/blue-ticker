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

    @Test func retiredKeysAreNotStoredAndNotServed() {
        let keys = Set(currentFilingSectionKeys().split(separator: ",").map(String.init))
        #expect(keys == ["business_risks", "mda", "capex_overview", "facility_plans", "management_policy"])
        #expect(keys.isDisjoint(with: retiredFilingSectionKeys))
        // 旧行に退役キーが残っていても read では返さない。
        let payload = FilingSectionsPayload(
            texts: ["mda": "m", "major_facilities": "f"],
            specials: ["segments": ExtractedBreakdownPayload(method: "x", tables: [], facts: [])])
        #expect(Set(payload.sectionsObject(sections: nil).keys) == ["mda"])
        #expect(payload.sectionsObject(sections: ["segments", "major_facilities"]).isEmpty)
    }

    @Test func oldRowsWithRetiredKeysStayFreshButMissingCurrentKeysAreStale() {
        let current = currentFilingSectionKeys()
        let old = (current.split(separator: ",").map(String.init) + ["segments", "geography"]).sorted()
            .joined(separator: ",")
        #expect(filingSectionKeysCoverCurrent(stored: old, current: current))
        #expect(filingSectionKeysCoverCurrent(stored: "mda", current: current) == false)
    }

    @Test func descriptionOfBusinessIsNotAPublishedFilingTextKey() {
        #expect(xbrlSections["description_of_business"] == nil)
        #expect(xbrlSections.values.contains { $0.xbrlElements.contains(Xbrl.descriptionOfBusinessTextblockTag) } == false)
        #expect(currentFilingSectionKeys().contains("description_of_business") == false)
    }

    @Test func htmlExtractorSharedPathBumpsFilingSectionsWithBusinessAndGeography() throws {
        let sectionsN = try #require(filingSectionsCacheVersionNumber(filingSectionsCacheVersion))
        #expect(sectionsN == 8)
        #expect(try #require(filingSectionsCacheVersionNumber("sections-v7")) < sectionsN)
        #expect(filingSectionsCacheVersion == "sections-v8")
        // breakdown of-which refinements already at geography v13; product_service is a
        // new axis series at v1 after the public axis-key hard cutover.
        #expect(geographyBreakdownCacheVersion == "breakdown-geography-v14")
        #expect(productServiceBreakdownCacheVersion == "breakdown-product_service-v2")
        #expect(segmentBreakdownCacheVersion == "breakdown-segment-v3")
    }
}

@Suite struct FilingSectionsR2ConfigTests {
    private let creds = [
        "BLT_R2_ACCOUNT_ID": "acct", "BLT_R2_ACCESS_KEY_ID": "id", "BLT_R2_SECRET_ACCESS_KEY": "secret",
    ]

    @Test func dedicatedBucketWinsOverXbrlBucket() {
        var env = creds
        env["BLT_R2_XBRL_BUCKET"] = "xbrl"
        env["BLT_R2_FILING_SECTIONS_BUCKET"] = "blt-filing-sections"
        #expect(R2StorageConfig.resolveFilingSectionsFromEnvironment(env)?.bucket == "blt-filing-sections")
        #expect(R2StorageConfig.resolveXbrlFromEnvironment(env)?.bucket == "xbrl")
    }

    @Test func fallsBackToXbrlBucketAndNeedsCredentials() {
        var env = creds
        env["BLT_R2_XBRL_BUCKET"] = "xbrl"
        #expect(R2StorageConfig.resolveFilingSectionsFromEnvironment(env)?.bucket == "xbrl")
        #expect(R2StorageConfig.resolveFilingSectionsFromEnvironment(["BLT_R2_FILING_SECTIONS_BUCKET": "b"]) == nil)
        #expect(R2StorageConfig.resolveFilingSectionsFromEnvironment([:]) == nil)
    }

    @Test func objectKeyRejectsPathSeparators() {
        #expect(filingSectionsObjectKey(docID: "S100ABCD") == "jp/edinet/filing-sections/S100ABCD.json")
        #expect(filingSectionsObjectKey(docID: "../x") == nil)
        #expect(filingSectionsObjectKey(docID: "") == nil)
    }
}
