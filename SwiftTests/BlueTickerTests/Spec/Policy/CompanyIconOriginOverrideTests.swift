// Pronexus 電子公告ページ 16 社の公式 origin 決め打ち。ネットワーク非依存。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct CompanyIconOriginOverrideTests {

    @Test func remapsSixteenPronexusDisclosureCompaniesAndExcludesPronexusFiler() {
        #expect(CompanyIconOriginOverride.pronexusDisclosureHomepages.count == 16)
        #expect(CompanyIconOriginOverride.pronexusDisclosureHomepages[CompanyIconOriginOverride.pronexusFilerCode] == nil)
        let codes = Array(CompanyIconOriginOverride.pronexusDisclosureHomepages.keys).sorted()
        #expect(
            codes == [
                "1905", "3088", "4238", "6412", "6482", "6486", "6674", "6875",
                "7412", "7538", "7896", "8153", "8766", "8928", "9441", "9684",
            ])
    }

    @Test func mappedValuesAreHTTPSOriginsWithoutPath() {
        for (code, origin) in CompanyIconOriginOverride.pronexusDisclosureHomepages {
            let url = URL(string: origin)
            #expect(url != nil, "code=\(code)")
            #expect(url?.scheme == "https", "code=\(code)")
            #expect(url?.host != nil, "code=\(code)")
            #expect(url?.path == "" || url?.path == "/", "code=\(code) path=\(url?.path ?? "")")
            #expect(url?.query == nil, "code=\(code)")
            #expect(origin == "https://\(url!.host!)", "code=\(code)")
        }
        for (code, source) in CompanyIconOriginOverride.manualSources {
            guard case .homepageOrigin(let origin) = source else { continue }
            let url = URL(string: origin)
            #expect(url != nil, "code=\(code)")
            #expect(url?.scheme == "https", "code=\(code)")
            #expect(url?.host != nil, "code=\(code)")
            #expect(url?.path == "" || url?.path == "/", "code=\(code) path=\(url?.path ?? "")")
            #expect(url?.query == nil, "code=\(code)")
            #expect(origin == "https://\(url!.host!)", "code=\(code)")
        }
    }

    @Test func remapsPronexusDisclosureOriginToCompanyHomepage() {
        #expect(
            CompanyIconOriginOverride.originForFavicon(
                code: "8766", extractedOrigin: "http://www.pronexus.co.jp")
                == "https://www.tokiomarinehd.com")
        #expect(
            CompanyIconOriginOverride.originForFavicon(
                code: "3088", extractedOrigin: "https://www.pronexus.co.jp")
                == "https://www.matsukiyococokara.com")
        #expect(
            CompanyIconOriginOverride.originForFavicon(
                code: "9684", extractedOrigin: "https://kmasterplus.pronexus.co.jp")
                == "https://www.hd.square-enix.com")
    }

    @Test func leavesPronexusFilerAndNonPronexusOriginsUnchanged() {
        #expect(
            CompanyIconOriginOverride.originForFavicon(
                code: "7893", extractedOrigin: "https://www.pronexus.co.jp")
                == "https://www.pronexus.co.jp")
        #expect(
            CompanyIconOriginOverride.originForFavicon(
                code: "6758", extractedOrigin: "https://www.sony.com")
                == "https://www.sony.com")
        #expect(
            CompanyIconOriginOverride.originForFavicon(
                code: "8766", extractedOrigin: "https://www.tokiomarinehd.com")
                == "https://www.tokiomarinehd.com")
    }

    @Test func remapsToyotaManualHomepageRegardlessOfExtractedOrigin() {
        #expect(CompanyIconOriginOverride.manualSources["7203"] == .homepageOrigin("https://toyota.jp"))
        #expect(
            Set(CompanyIconOriginOverride.manualSources.keys)
                .isDisjoint(with: Set(CompanyIconOriginOverride.pronexusDisclosureHomepages.keys)))
        #expect(
            CompanyIconOriginOverride.originForFavicon(
                code: "7203", extractedOrigin: "https://www.toyota.co.jp")
                == "https://toyota.jp")
        #expect(
            CompanyIconOriginOverride.originForFavicon(
                code: "7203", extractedOrigin: "https://global.toyota")
                == "https://toyota.jp")
    }

    @Test func detectsPronexusDisclosureHosts() {
        #expect(CompanyIconOriginOverride.isPronexusDisclosureHost("https://www.pronexus.co.jp"))
        #expect(CompanyIconOriginOverride.isPronexusDisclosureHost("http://pronexus.co.jp"))
        #expect(CompanyIconOriginOverride.isPronexusDisclosureHost("https://kmasterplus.pronexus.co.jp"))
        #expect(!CompanyIconOriginOverride.isPronexusDisclosureHost("https://www.tokiomarinehd.com"))
        #expect(!CompanyIconOriginOverride.isPronexusDisclosureHost("not-a-url"))
    }

    @Test func manualCacheVersionIsExcludedFromAutomaticRefresh() {
        #expect(
            !companyIconShouldRefresh(
                code: "6758", cacheVersion: companyIconsManualCacheVersion,
                sourceURL: "https://www.sony.com"))
        #expect(
            !companyIconShouldRefresh(
                code: "6758", cacheVersion: companyIconsCacheVersion,
                sourceURL: "https://www.sony.com"))
        #expect(
            companyIconShouldRefresh(
                code: "6758", cacheVersion: "icons-v0", sourceURL: "https://www.sony.com"))
    }

    @Test func toyotaRefreshesUntilManualOriginIsStored() {
        #expect(
            companyIconShouldRefresh(
                code: "7203", cacheVersion: companyIconsCacheVersion,
                sourceURL: "https://www.toyota.co.jp"))
        #expect(
            companyIconShouldRefresh(
                code: "7203", cacheVersion: companyIconsManualCacheVersion,
                sourceURL: "https://www.toyota.co.jp"))
        #expect(
            !companyIconShouldRefresh(
                code: "7203", cacheVersion: companyIconsManualCacheVersion,
                sourceURL: "https://toyota.jp"))
        #expect(
            !companyIconShouldRefresh(
                code: "7203", cacheVersion: companyIconsManualCacheVersion,
                sourceURL: "https://toyota.jp/"))
    }
}
