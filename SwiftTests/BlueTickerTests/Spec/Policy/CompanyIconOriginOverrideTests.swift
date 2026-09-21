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
            CompanyIconOriginOverride.manualSources["9267"]
                == .homepageOrigin("https://www.genky.co.jp"))
        #expect(
            CompanyIconOriginOverride.manualSources["581A"]
                == .imageURL("https://go.goinc.jp/android-chrome.png"))
        #expect(
            CompanyIconOriginOverride.manualSources["8887"]
                == .imageURL(
                    "https://syla-holdings.jp/wp-content/uploads/2025/05/cropped-favicon-192x192.png"))
        #expect(CompanyIconOriginOverride.manualSources["6150"] == .homepageOrigin("https://www.takeda-mc.co.jp"))
        #expect(CompanyIconOriginOverride.manualSources["7888"] == .homepageOrigin("https://www.sankogosei.co.jp"))
        #expect(
            CompanyIconOriginOverride.manualSources["8473"]
                == .imageURL("https://www.sbisec.co.jp/apple-touch-icon.png"))
        #expect(
            CompanyIconOriginOverride.manualSources["7177"]
                == .imageURL("https://group.gmo/favicon_144x144.png"))
        #expect(
            CompanyIconOriginOverride.manualSources["8630"]
                == .imageURL("https://www.sompo-hd.com/sompohd/common/images/apple-touch-icon.png"))
        #expect(
            CompanyIconOriginOverride.manualSources["8616"]
                == .imageURL("https://www.tokaitokyo-fh.jp/asset/img/common/apple-touch-icon.png"))
        #expect(
            CompanyIconOriginOverride.manualSources["2653"]
                == .imageURL("https://www.aeon-kyushu.info/apple-touch-icon-precomposed.png"))
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

    /// 2026-09-12 icons audit: priority A 2（9267 は TLS 欠落のため homepage のまま）+ missing-batch B 57。
    /// 6902 デンソーは対象外。
    @Test func pins20260912IconsAuditManualImageURLs() {
        let expected: [(String, String)] = [
            ("2462", "https://www.like-gr.co.jp/wp/wp-content/themes/like.1801/152x152.png"),
            ("8377", "https://www.hokuhoku-fg.co.jp/assets/images/pages/info/idea/corporate_mark.png"),
            ("4188", "https://www.mcgc.com/assets/img/og-image.jpg"),
            ("9531", "https://www.tokyo-gas.co.jp/apple-touch-icon.png"),
            ("3402", "https://www.toray.com/apple-touch-icon.png"),
            ("9201", "https://www.jal.com/favicon.ico"),
            ("4452", "https://www.kao.com/content/dam/sites/kao/www-kao-com/jp/ja/index/ogp_logo.png"),
            ("6724", "https://www.epson.jp/images/ogp_img.png"),
            ("4204", "https://www.sekisui.co.jp/resource/img/ogp.png"),
            ("5801", "https://www.furukawaelectric.com/common/images/ogimage.png"),
            ("5076", "https://www.infroneer.com/images/ogp.png"),
            ("2733", "https://www.arata-gr.jp/assets_renew/images/ogp.jpg"),
            ("6471", "https://www.nsk.com/content/dam/nsk/common/logo/nsk_logo.png"),
            ("9956", "https://valorholdings.co.jp/wp-content/themes/valor-template/common/img/ogp.jpg"),
            ("8282", "https://www.ksdenki.co.jp/favicon.ico"),
            ("5332", "https://jp.toto.com/favicon.ico"),
            ("8075", "https://www.shinsho.co.jp/apple-touch-icon.png"),
            ("4676", "https://www.fujimediahd.co.jp/assets/img/ogp.png"),
            ("3050", "https://www.dcm-hc.co.jp/ogp.png"),
            ("4507", "https://www.shionogi.com/content/dam/shionogi/img/apple-touch-icon.png"),
            ("7186", "https://www.yokohamafg.co.jp/shared/img/company/summary/brand/img-brand.jpg"),
            ("1861", "https://www.kumagaigumi.co.jp/assets/img/common/ogp_jp.webp"),
            ("8253", "https://www.saisoncard.co.jp/proxy_img/assets/462949b256274358947c3db996c948d4/c9aadfc16cc54456a31ffeb0a340fd31/og.png"),
            ("3086", "https://www.j-front-retailing.com/apple-touch-icon.png"),
            ("8173", "https://www.joshin.co.jp/resources/apple-touch-icon.png"),
            ("9007", "https://www.odakyu.jp/apple-touch-icon.png"),
            ("9974", "https://www.belc.jp/themes/custom/belc/img/favicons/apple-touch-icon-180x180.png"),
            ("4205", "https://www.zeon.co.jp/app-files/img/symbol/ogp.png"),
            ("3465", "https://ki-group.co.jp/ogp_cojp.jpg"),
            ("7283", "https://www.aisan-ind.co.jp/assets/images/ogp.png"),
            ("7616", "https://www.colowide.co.jp/cmn/img/favicon.ico"),
            ("9468", "https://group.kadokawa.co.jp/archives/001/202105/22600750dd2c4bde9feea9045aa782873795fad55c1ca265cb6b11f176e5aabc.jpg"),
            ("9072", "https://www.nikkon-hd.co.jp/assets/images/ogp.png"),
            ("6005", "https://www.miuraz.co.jp/assets/img/ogp.png"),
            ("4403", "https://www.nof.co.jp/assets/images/favicon.ico"),
            ("1961", "https://www.sanki.co.jp/apple-touch-icon.png"),
            ("2695", "https://www.kurasushi.co.jp/shared/img/ogp.png"),
            ("1941", "https://www.chudenko.co.jp/images/favicon.ico"),
            ("3036", "https://www.alconix.com/assets/img/ogimage.png"),
            ("6966", "https://www.mitsui-high-tec.com/common/img/ogp.jpg"),
            ("9470", "https://www.gakken.co.jp/ja/ogpImage/OGP_GHDcorp.png"),
            ("3539", "https://jm-holdings.co.jp/img/ogp.jpg"),
            ("2767", "https://www.tsuburaya-fields.co.jp/newscms/wp-content/themes/tsuburaya/assets/img/ogp.png"),
            ("2146", "https://www.ut-g.co.jp/assets/img/common/ogp/ogp.png"),
            ("4812", "https://www.dentsusoken.com/themes/dentsusoken/assets/image/ogimage.png"),
            ("9619", "https://www.ichinenhd.co.jp/assets/img/common/ogp.jpg"),
            ("5444", "https://www.yamatokogyo.co.jp/common/img/ogp.jpg"),
            ("9994", "https://www.yamaya.jp/ynhp/img/yamaya_social_image.png"),
            ("5408", "https://www.nakayama-steel.co.jp/cmn/img/ogp.jpg"),
            ("8136", "https://corporate.sanrio.co.jp/img/ogp/img_sanrio.png"),
            ("1968", "https://www.taihei-dengyo.co.jp/common_rwd/img/icon_180_180.png"),
            ("2220", "https://www.kamedaseika.co.jp/wp-content/uploads/2022/02/ogp.png"),
            ("8111", "https://www.goldwin.co.jp/static/full/images/store/ogp/onlinestore/ogp.png"),
            ("6794", "https://www.foster.co.jp/app-files/img/symbol/ogp.webp"),
            ("9119", "https://www.iino.co.jp/kaiun/files/ogp.png"),
            ("4569", "https://www.kyorin-pharm.co.jp/assets/img/og-image.png"),
            ("5161", "https://www.nishikawa-rbr.co.jp/assets/images/common/ogp.png"),
            ("7564", "https://www.workman.co.jp/apple-touch-icon.png"),
            ("9759", "https://www.nsd.co.jp/app-files/img/symbol/ogp.webp"),
        ]
        #expect(expected.count == 59)
        #expect(Set(expected.map(\.0)).count == 59)
        #expect(CompanyIconOriginOverride.manualSources["6902"] == nil)
        for (code, url) in expected {
            #expect(
                CompanyIconOriginOverride.manualSources[code] == .imageURL(url), "code=\(code)")
        }
    }

    /// 2026-09-18: listed × company_icons 欠行の売上上位。自動 ingest が使える会社は含まない。
    /// 6902 デンソーは対象外のまま。
    @Test func pins20260918MissingListedManualImageURLs() {
        let expected: [(String, String)] = [
            ("8001", "https://www.itochu.co.jp/ja/apple-touch-icon.png"),
            ("8002", "https://www.marubeni.com/apple-touch-icon.png"),
            ("7459", "https://www.medipal.co.jp/favicon.ico"),
            ("2784", "https://www.alfresa.com/assets/img/common/ogp.png"),
            ("9508", "https://www.kyuden.co.jp/library/2017/images/common/fb.png"),
            ("2181", "https://www.persol-group.co.jp/images/common/apple-touch-icon-152x152.png"),
            ("3291", "https://www.ighd.co.jp/assets/common/images/favicon-192x192.png"),
            ("4324", "https://www.group.dentsu.com/common/image/apple-touch-icon.png"),
            ("5334", "https://www.niterragroup.com/ogp.png"),
            ("3360", "https://www.shiphd.co.jp/wp-content/themes/shiptheme/assets/img/common/favicon.png"),
            ("8060", "https://corporate.jp.canon/-/media/Project/Canon/CanonJP/Website/shared/image/icon/apple-touch-icon.png?la=ja-JP"),
            ("2602", "https://www.nisshin-oillio.com/icon-192x192.png"),
            ("3105", "https://www.nisshinbo.co.jp/apple-touch-icon.png"),
            ("9401", "https://www.tbsholdings.co.jp/img/ogp.png"),
            ("2678", "https://www.askul.co.jp/apple-touch-icon.png"),
            ("1766", "https://www.token.co.jp/favicon.ico"),
            ("2670", "https://www.abc-mart.co.jp/new_img/common/logo.png"),
            ("1885", "https://www.toa-const.co.jp/common/img/og_image.png"),
            ("8572", "https://www.acom.co.jp/img/apple-touch-icon.png"),
            ("7994", "https://www.okamura.co.jp/global_assets/images/apple-touch-icon.png"),
        ]
        #expect(expected.count == 20)
        #expect(Set(expected.map(\.0)).count == 20)
        #expect(CompanyIconOriginOverride.manualSources["6902"] == nil)
        #expect(
            Set(expected.map(\.0))
                .isDisjoint(with: Set(CompanyIconOriginOverride.pronexusDisclosureHomepages.keys)))
        for (code, url) in expected {
            #expect(
                CompanyIconOriginOverride.manualSources[code] == .imageURL(url), "code=\(code)")
        }
    }

    /// 2026-09-20: visual GO。NTT 公式 apple-touch と R2 CDN（prtimes.jp 直リンク禁止）。
    @Test func pins20260920VisualGoManualImageURLs() {
        let expected: [(String, String)] = [
            ("9432", "https://group.ntt/apple-touch-icon.png"),
            ("9439", "https://icons.sollahiro.com/company-icons/9439.png"), // pragma: allowlist secret
            ("7427", "https://icons.sollahiro.com/company-icons/7427.png"), // pragma: allowlist secret
            ("9412", "https://icons.sollahiro.com/company-icons/9412.png"), // pragma: allowlist secret
        ]
        #expect(expected.count == 4)
        #expect(Set(expected.map(\.0)).count == 4)
        #expect(
            Set(expected.map(\.0))
                .isDisjoint(with: Set(CompanyIconOriginOverride.pronexusDisclosureHomepages.keys)))
        for (code, url) in expected {
            #expect(!url.contains("prtimes.jp"), "code=\(code)")
            #expect(
                CompanyIconOriginOverride.manualSources[code] == .imageURL(url), "code=\(code)")
        }
    }

    /// 2026-09-20 weekly: listed × company_icons 欠行。自動 pipeline 不能分の公式画像。
    /// 5805 の origin apple-touch は小冊子なのでマップに載せない。
    @Test func pins20260920WeeklyMissingListedManualImageURLs() {
        let expected: [(String, String)] = [
            ("8198", "https://www.mv-tokai.co.jp/wp/wp-content/uploads/fbrfg/apple-touch-icon.png"),
            ("2206", "https://www.glico.com/assets/images/original/glicoogp__1.png"),
            ("6432", "https://www.takeuchi-japan.com/apple-icon.png"),
            ("8897", "https://mirarth.co.jp/assets/img/common/apple-touch-icon.png"),
            ("2790", "https://www.nafco.tv/app-files/img/symbol/apple-touch-icon.webp"),
            ("9706", "https://www.tokyo-airport-bldg.co.jp/site_resource/common/img/000013562.png"),
            ("9682", "https://www.dts.co.jp/apple-touch-icon.png"),
            ("9413", "https://www.tv-tokyo.co.jp/apple-touch-icon.png"),
            ("2109", "https://www.msdm-hd.com/jp/app-files/img/symbol/apple-touch-icon.png"),
            ("7236", "https://icons.sollahiro.com/company-icons/7236.png"), // pragma: allowlist secret
            ("7414", "https://www.onoken.co.jp/apple-touch-icon.png"),
        ]
        #expect(expected.count == 11)
        #expect(Set(expected.map(\.0)).count == 11)
        #expect(CompanyIconOriginOverride.manualSources["6902"] == nil)
        #expect(CompanyIconOriginOverride.manualSources["5805"] == nil)
        #expect(
            Set(expected.map(\.0))
                .isDisjoint(with: Set(CompanyIconOriginOverride.pronexusDisclosureHomepages.keys)))
        for (code, url) in expected {
            #expect(!url.contains("prtimes.jp"), "code=\(code)")
            #expect(
                CompanyIconOriginOverride.manualSources[code] == .imageURL(url), "code=\(code)")
        }
    }

    /// 2026-09-21 weekly: listed × company_icons 欠行。公告 URL 無し／紙面の公式画像。
    /// フッター SNS・別名ドメイン・横長ワードマーク OGP はマップに載せない。
    @Test func pins20260921WeeklyMissingListedManualImageURLs() {
        let expected: [(String, String)] = [
            ("6349", "https://www.komori.com/global_common/img/webclip.png"),
            ("8370", "https://icons.sollahiro.com/company-icons/8370.png"), // pragma: allowlist secret
            ("4410", "https://www.harima.co.jp/apple_touch_icon.png"),
            ("8005", "https://www.scroll.jp/wp-content/themes/scr-corporate/common/img/base/apple-touch-icon.png"),
            ("6999", "https://www.koaglobal.com/common/images/iosicon.png"),
            ("7630", "https://www.ichibanya.co.jp/apple-touch-icon.png"),
            ("2698", "https://www.cando-web.co.jp/apple-touch-icon.png"),
            ("4998", "https://www.fumakilla.co.jp/apple-touch-icon.png"),
            ("8386", "https://www.114bank.co.jp/apple-touch-icon.png"),
            ("8160", "https://www.kisoji.co.jp/themes/kisoji/assets/favicon/apple-touch-icon.png"),
            ("8275", "https://www.forval.co.jp/webclip.png"),
            ("6941", "https://www.yamaichi.co.jp/img/apple-touch-icon-152x152.png"),
            ("8387", "https://www.shikokubank.co.jp/apple-touch-icon-precomposed.png"),
            ("1892", "https://www.tokura.co.jp/media/001/202602/ogp.png"),
            ("1798", "https://www.moriya-s.co.jp/files/favicon/apple-touch-icon.png"),
            ("4635", "https://www.tokyoink.co.jp/apple-touch-icon.png"),
            ("7879", "https://www.noda-co.jp/common/favicon/apple-touch-icon.png"),
            ("2329", "https://www.tfc.co.jp/cms/apple-touch-icon.png"),
            ("7715", "https://www.naganokeiki.co.jp/common/favicon/apple-touch-icon.png"),
            ("9622", "https://www.space-tokyo.co.jp/assets/img/apple-touch-icon.png"),
        ]
        #expect(expected.count == 20)
        #expect(Set(expected.map(\.0)).count == 20)
        #expect(CompanyIconOriginOverride.manualSources["3817"] == nil)
        #expect(CompanyIconOriginOverride.manualSources["7595"] == nil)
        #expect(
            Set(expected.map(\.0))
                .isDisjoint(with: Set(CompanyIconOriginOverride.pronexusDisclosureHomepages.keys)))
        for (code, url) in expected {
            #expect(!url.contains("prtimes.jp"), "code=\(code)")
            #expect(
                CompanyIconOriginOverride.manualSources[code] == .imageURL(url), "code=\(code)")
        }
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

    @Test func genkyKeepsHomepageOriginWithoutLogoPNGRefresh() {
        #expect(
            companyIconShouldRefresh(
                code: "9267", cacheVersion: companyIconsCacheVersion,
                sourceURL: "https://genky.co.jp"))
        #expect(
            !companyIconShouldRefresh(
                code: "9267", cacheVersion: companyIconsManualCacheVersion,
                sourceURL: "https://www.genky.co.jp"))
        #expect(
            companyIconShouldRefresh(
                code: "9267", cacheVersion: companyIconsManualCacheVersion,
                sourceURL: "https://genky.co.jp/common/cmn_img/logo.png"))
    }

    @Test func sylaRefreshesUntilManualImageURLIsStored() {
        let png = "https://syla-holdings.jp/wp-content/uploads/2025/05/cropped-favicon-192x192.png"
        #expect(
            companyIconShouldRefresh(
                code: "8887", cacheVersion: companyIconsCacheVersion,
                sourceURL: "https://syla-holdings.jp"))
        #expect(
            companyIconShouldRefresh(
                code: "8887", cacheVersion: companyIconsManualCacheVersion,
                sourceURL: "https://syla-holdings.jp"))
        #expect(
            !companyIconShouldRefresh(
                code: "8887", cacheVersion: companyIconsManualCacheVersion, sourceURL: png))
    }

    @Test func goAppIconRefreshesUntilManualImageURLIsStored() {
        let png = "https://go.goinc.jp/android-chrome.png"
        #expect(
            companyIconShouldRefresh(
                code: "581A", cacheVersion: companyIconsManualCacheVersion,
                sourceURL: "https://goinc.jp"))
        #expect(
            companyIconShouldRefresh(
                code: "581A", cacheVersion: companyIconsCacheVersion, sourceURL: png))
        #expect(
            !companyIconShouldRefresh(
                code: "581A", cacheVersion: companyIconsManualCacheVersion, sourceURL: png))
    }

    /// 603A: 欠行。先頭 rel=icon が 16.jpg のため公式 apple-touch 256.jpg。
    @Test func pinsIgridSolutionsMissingListedManualImageURL() {
        let jpeg = "https://igrid.co.jp/wp-content/themes/igrid2024/dist/img/favicon/256.jpg"
        #expect(
            CompanyIconOriginOverride.manualSources["603A"] == .imageURL(jpeg))
        #expect(
            CompanyIconOriginOverride.pronexusDisclosureHomepages["603A"] == nil)
        #expect(
            companyIconShouldRefresh(
                code: "603A", cacheVersion: companyIconsCacheVersion,
                sourceURL: "https://igrid.co.jp"))
        #expect(
            companyIconShouldRefresh(
                code: "603A", cacheVersion: companyIconsManualCacheVersion,
                sourceURL: "https://igrid.co.jp"))
        #expect(
            !companyIconShouldRefresh(
                code: "603A", cacheVersion: companyIconsManualCacheVersion, sourceURL: jpeg))
    }

    @Test func lowResHoldingsIconsRefreshUntilManualImageURLIsStored() {
        let pinned: [(String, String, String)] = [
            ("8473", "https://www.sbigroup.co.jp", "https://www.sbisec.co.jp/apple-touch-icon.png"),
            ("7177", "https://www.gmofh.com", "https://group.gmo/favicon_144x144.png"),
            ("8630", "https://www.sompo-hd.com",
                "https://www.sompo-hd.com/sompohd/common/images/apple-touch-icon.png"),
            ("8616", "https://www.tokaitokyo-fh.jp",
                "https://www.tokaitokyo-fh.jp/asset/img/common/apple-touch-icon.png"),
            ("2653", "https://www.aeon-kyushu.info",
                "https://www.aeon-kyushu.info/apple-touch-icon-precomposed.png"),
        ]
        for (code, oldOrigin, png) in pinned {
            #expect(
                companyIconShouldRefresh(
                    code: code, cacheVersion: companyIconsCacheVersion, sourceURL: oldOrigin),
                "code=\(code)")
            #expect(
                companyIconShouldRefresh(
                    code: code, cacheVersion: companyIconsManualCacheVersion, sourceURL: oldOrigin),
                "code=\(code)")
            #expect(
                !companyIconShouldRefresh(
                    code: code, cacheVersion: companyIconsManualCacheVersion, sourceURL: png),
                "code=\(code)")
        }
    }

    @Test func visualGoIconsRefreshUntilManualImageURLIsStored() {
        let pinned: [(String, String, String)] = [
            ("9432", "https://group.ntt", "https://group.ntt/apple-touch-icon.png"),
            ("9439", "https://icons.sollahiro.com", // pragma: allowlist secret
                "https://icons.sollahiro.com/company-icons/9439.png"), // pragma: allowlist secret
            ("7427", "https://icons.sollahiro.com", // pragma: allowlist secret
                "https://icons.sollahiro.com/company-icons/7427.png"), // pragma: allowlist secret
            ("9412", "https://icons.sollahiro.com", // pragma: allowlist secret
                "https://icons.sollahiro.com/company-icons/9412.png"), // pragma: allowlist secret
        ]
        for (code, oldOrigin, png) in pinned {
            #expect(
                companyIconShouldRefresh(
                    code: code, cacheVersion: companyIconsCacheVersion, sourceURL: oldOrigin),
                "code=\(code)")
            #expect(
                companyIconShouldRefresh(
                    code: code, cacheVersion: companyIconsManualCacheVersion, sourceURL: oldOrigin),
                "code=\(code)")
            #expect(
                !companyIconShouldRefresh(
                    code: code, cacheVersion: companyIconsManualCacheVersion, sourceURL: png),
                "code=\(code)")
        }
    }
}
