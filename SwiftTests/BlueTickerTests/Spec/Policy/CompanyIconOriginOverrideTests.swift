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
            ("4452", "https://icons.sollahiro.com/company-icons/4452.png"), // pragma: allowlist secret
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

    /// 2026-09-28 weekly: listed × company_icons 欠行。公告紙面／URL無し／Pronexus の公式画像。
    /// Jetpack CDN・横長ワードマーク OGP はマップに載せない。9445 は自社製品ブランド。
    @Test func pins20260928WeeklyMissingListedManualImageURLs() {
        let expected: [(String, String)] = [
            ("2195", "https://icons.sollahiro.com/company-icons/2195.png"), // pragma: allowlist secret
            ("2395", "https://snbl.com/wp-content/themes/snbl/apple-touch-icon.png"),
            ("2449", "https://www.prap.co.jp/wp/wp-content/themes/custom-theme/apple-touch-icon.png"),
            ("2894", "https://icons.sollahiro.com/company-icons/2894.png"), // pragma: allowlist secret
            ("3083", "https://starseeds.co.jp/cms/wp-content/themes/corporate-theme/assets/icons/apple-touch-icon.png"),
            ("3123", "https://www.saibo.co.jp/img/saibohp/favicon02.ico"),
            ("339A", "https://progresstech-group.jp/assets/images/common/apple-touch-icon-180x180.png"),
            ("3653", "https://www.morphoinc.com/assets/images/common/singleicon.png"),
            ("4056", "https://www.neural-group.com/assets/img/apple-touch-icon.png"),
            ("4092", "https://www.nippon-chem.co.jp/apple-touch-icon.png"),
            ("4436", "https://minkabu.co.jp/wp-content/themes/wp-thema-infonoid-web-2022-main/assets/meta/apple-touch-icon.png"),
            ("446A", "https://northsand.co.jp/wp-content/uploads/2025/10/cropped-n.png"),
            ("4673", "https://www.kge.co.jp/wp-bridge2026/wp-content/uploads/2026/08/cropped-apple-touch-icon-180x180.png"),
            ("4819", "https://www.garage.co.jp/wp/wp-content/themes/garage/assets/config/apple-touch-icon.jpg"),
            ("5659", "https://www.n-seisen.co.jp/assets/images/common/apple-touch-icon.png"),
            ("6203", "https://icons.sollahiro.com/company-icons/6203.png"), // pragma: allowlist secret
            ("6278", "https://www.uniontool.co.jp/assets/img/apple-touch-icon.png"),
            ("6706", "https://denkikogyo.co.jp/wp-content/uploads/2022/09/cropped-favicon-180x180.png"),
            ("6797", "https://www.nagoya-denki.co.jp/cms/wp-content/themes/nagoyadenki/icon.png"),
            ("7265", "https://icons.sollahiro.com/company-icons/7265.png"), // pragma: allowlist secret
            ("7266", "https://www.imasen.co.jp/wp-content/themes/imasen/img/common/apple-touch-icon.png"),
            ("7443", "https://yokohamagyorui.co.jp/wp-content/uploads/2026/04/cropped-cropped-favicon-150x150-1-180x180.png"),
            ("8225", "https://kk-takachiho.jp/files/favicon/apple-touch-icon.png"),
            ("8595", "https://www.jafco.co.jp/apple-touch-icon.png"),
            ("9245", "https://www.livero.co.jp/corporate/corp_assets/apple-touch-icon.png"),
            ("9313", "https://www.maru8.co.jp/apple-touch-icon-144-precomposed.png"),
            ("9930", "https://www.kitazawasangyo.co.jp/image/common/apple-touch-icon.png"),
            ("9445", "https://www.collabo-one.jp/wp-content/themes/collaboone/images/common/webclip.png"),
        ]
        #expect(expected.count == 28)
        #expect(Set(expected.map(\.0)).count == 28)
        #expect(CompanyIconOriginOverride.manualSources["9216"] == nil)
        #expect(
            Set(expected.map(\.0))
                .isDisjoint(with: Set(CompanyIconOriginOverride.pronexusDisclosureHomepages.keys)))
        for (code, url) in expected {
            #expect(!url.contains("prtimes.jp"), "code=\(code)")
            #expect(!url.contains("i0.wp.com"), "code=\(code)")
            #expect(
                CompanyIconOriginOverride.manualSources[code] == .imageURL(url), "code=\(code)")
        }
    }

    /// 2026-10-05 weekly: listed × company_icons 欠行。公告紙面／URL無し／Pronexus の公式画像。
    /// 単色矩形・SNS の X・横長ワードマーク OGP はマップに載せない。
    @Test func pins20261005WeeklyMissingListedManualImageURLs() {
        let expected: [(String, String)] = [
            ("1992", "https://www.kandt.co.jp/favicon.ico"),
            ("2435", "https://www.cedar-group.co.jp/media/images/common/apple-touch-icon.png"),
            ("2776", "https://www.shintohd.co.jp/wp-content/uploads/fbrfg/apple-touch-icon.png"),
            ("2917", "https://ohmoriya-inc.co.jp/wp-content/uploads/2024/06/cropped-logo512-180x180.png"),
            ("3021", "https://www.prins.co.jp/favicon.ico"),
            ("3063", "https://www.jgroup.jp/wp/wp-content/uploads/cropped-favicon-180x180.png"),
            ("3140", "https://bruno-inc.com/apple-touch-icon.png"),
            ("3323", "https://www.recomm.co.jp/apple-touch-icon.png"),
            ("3399", "https://www.yamaokaya.com/images/apple-touch-icon.png"),
            ("3421", "https://www.inaba-ss.co.jp/assets/favicon/apple-touch-icon.png"),
            ("3439", "https://www.mitsuchi.co.jp/wp-content/themes/mituchi/img/icons/touch.png"),
            ("3441", "https://www.sanno.co.jp/assets/images/favicon.png"),
            ("3913", "https://www.greenbee.co.jp/apple-touch-icon.png"),
            ("3948", "https://hikaribf.co.jp/wordpress/wp-content/themes/hbf/img/favicon.png"),
            ("4094", "https://www.nihonkagakusangyo.co.jp/apple-touch-icon.png"),
            ("4345", "https://www.cts-h.co.jp/apple-touch-icon.png"),
            ("4645", "https://ir.ichishin.co.jp/wp/wp-content/uploads/2025/07/cropped-favicon-180x180.png"),
            ("4684", "https://www.obic.co.jp/app-files/img/symbol/apple-touch-icon.png"),
            ("4762", "https://www.xnet.co.jp/apple-touch-icon.png"),
            ("4772", "https://smej.co.jp/apple-touch-icon-precomposed.png"),
            ("5284", "https://www.yamau-holdings.co.jp/img/apple-touch-icon.png"),
            ("6050", "https://www.e-guardian.co.jp/resources/img/ogp2.png"),
            ("6076", "https://www.az-hotels.co.jp/apple-touch-icon.png"),
            ("6091", "https://www.wescohd.co.jp/wp-content/uploads/2023/10/favicon.png"),
            ("6291", "https://www.airtech.co.jp/assets/img/common/apple-touch-icon.png"),
            ("6298", "https://www.yac.co.jp/resources/apple-touch-icon.png"),
            ("6342", "https://www.taihei-ss.co.jp/wp/wp-content/uploads/2024/07/cropped-taihei_favicom_240723-180x180.png"),
            ("6360", "https://www.tam-tokyo.co.jp/apple-touch-icon.png"),
            ("6400", "https://www.fujiseiki.com/wp-content/themes/fujiseiki2025/assets/apple-touch-icon.png"),
            ("6469", "https://www.hsk.co.jp/resources/apple-touch-icon.png"),
            ("6538", "https://disruptors.co.jp/apple-touch-icon.png"),
            ("7477", "https://muraki.jp/mu-db103/wp-content/uploads/2024/04/cropped-muraki-180x180.gif"),
            ("7819", "https://www.shobido-corp.co.jp/assets/img/common/logo@144.png"),
            ("7849", "https://starts-pub.jp/wp-content/uploads/2021/10/cropped-fabicon-180x180.png"),
            ("7872", "https://www.estelle.co.jp/wp_manager/wp-content/uploads/2023/11/cropped-estelle-1-180x180.png"),
            ("7878", "https://www.kohsai-qq.co.jp/assets/image/common/icon_180x180.png"),
            ("7887", "https://www.nankaiplywood.co.jp/image/common/favicon.ico"),
            ("7908", "https://www.kimoto.co.jp/application/files/3117/4704/5415/sp_icon.png"),
            ("8013", "https://www.naigai.co.jp/core_sys/images/others/favicon/apple-touch-icon-180x180.png"),
            ("8254", "https://p3.ssl-cdn.jp/var/data/u/c9/43e4ad62220/img/webclip.png"),
            ("8927", "https://meiho-est.com/meiho-wp/wp-content/themes/meiho-est/assets/img/common/app_icon.png"),
            ("8944", "https://www.lbca.co.jp/img/common/apple-touch-icon.png"),
            ("9034", "https://www.nanso.co.jp/apple-touch-icon.png"),
            ("9367", "https://www.daito-koun.co.jp/cms/wp-content/uploads/2025/08/cropped-favicon-180x180.png"),
            ("9610", "https://japan.wilsonlearning.com/apple-touch-icon.png"),
            ("9643", "https://www.nakanihonkogyo.co.jp/img/icon/apple-touch-icon.png"),
            ("9679", "https://www.horai-kk.co.jp/assets/img/common/apple-touch-icon-precomposed.png"),
            ("9778", "https://www.subaru-net.com/wp-content/themes/subaru-net/images/apple-touch-icon.png"),
            ("9820", "https://www.mt-genex.co.jp/assets/images/common/apple-touch-icon.png"),
        ]
        #expect(expected.count == 49)
        #expect(Set(expected.map(\.0)).count == 49)
        #expect(CompanyIconOriginOverride.manualSources["288A"] == nil)
        #expect(CompanyIconOriginOverride.manualSources["3467"] == nil)
        #expect(CompanyIconOriginOverride.manualSources["7868"] == nil)
        #expect(
            Set(expected.map(\.0))
                .isDisjoint(with: Set(CompanyIconOriginOverride.pronexusDisclosureHomepages.keys)))
        for (code, url) in expected {
            #expect(!url.contains("prtimes.jp"), "code=\(code)")
            #expect(!url.contains("i0.wp.com"), "code=\(code)")
            #expect(
                CompanyIconOriginOverride.manualSources[code] == .imageURL(url), "code=\(code)")
        }
    }

    /// 2026-10-20 weekly replacements: 16px→公式 apple-touch。PR #534 visual GO 99 社。
    @Test func pins20261020WeeklyReplacementGOManualImageURLs() {
        let expected: [(String, String)] = [
            ("1333", "https://www.umios.com/favicon/favicon_192.png"),
            ("1444", "https://reform-nisso.co.jp/favicons/apple-touch-icon-144x144.png"),
            ("1518", "https://www.mitsui-matsushima.co.jp/wp/wp-content/themes/mitsui-matsushima_2024/assets/images/apple-touch-icon.png"),
            ("1723", "https://www.nihondengi.co.jp/apple-touch-icon.png"),
            ("1928", "https://www.sekisuihouse.co.jp/library/img/touch-icon.png"),
            ("1963", "https://www.jgc.com/jp/common/img/apple-touch-icon.png"),
            ("2282", "https://www.nipponham.co.jp/apple-touch-icon.png"),
            ("2351", "https://www.asj.ad.jp/apple-touch-icon-180x180.png"),
            ("2489", "https://adways.net/wp-content/uploads/cropped-apple-touch-icon-1-192x192.png"),
            ("2585", "https://www.ld-company.com/images/miscs/ldc_favicon_144.png"),
            ("2702", "https://www.mcd-holdings.co.jp/apple-touch-icon.png"),
            ("2737", "https://www.tomendevices.co.jp/apple-touch-icon.png"),
            ("2798", "https://www.ystable.co.jp/apple-touch-icon.png"),
            ("3093", "https://www.treasurefactory.co.jp/img/iconified/apple-touch-icon-144x144.png"),
            ("3103", "https://www.unitika.co.jp/apple-touch-icon.png"),
            ("3317", "https://www.fgarden.co.jp/common/webclip.png"),
            ("3333", "https://www.cb-asahi.co.jp/apple-touch-icon.png"),
            ("3361", "https://www.toell.co.jp/touch-icon.png"),
            ("3447", "https://ir.shinwa-jp.com/resources/sw_img/favicon.ico"),
            ("3461", "https://www.palma.jp/assets/img/apple-touch-icon.png"),
            ("3863", "https://www.nipponpapergroup.com/assets/images/apple-touch-icon.png"),
            ("3896", "https://www.awapaper.co.jp/common/img/apple-touch-icon.png"),
            ("3903", "https://gu3.co.jp/assets/img/gumi_favicon_144.ico"),
            ("3907", "https://www.siliconstudio.co.jp/wp-content/themes/custom/favicon/apple-touch-icon.png"),
            ("3958", "https://www.sasatoku.co.jp/img/apple-touch-icon.png"),
            ("3964", "https://ir.aucnet.co.jp/resources/apple-touch-icon.png"),
            ("3976", "https://www.shanon.co.jp/assets/img/apple-touch-icon.png"),
            ("3983", "https://www.oro.com/ja/img/share/apple-touch-icon.png"),
            ("4004", "https://www.resonac.com/themes/resonac/common/img/shared/apple-touch-icon.png"),
            ("4027", "https://www.tayca.co.jp/apple-touch-icon.png"),
            ("4041", "https://www.nippon-soda.co.jp/asset/image/apple-touch-icon.png"),
            ("4114", "https://www.shokubai.co.jp/ja/apple-touch-icon.png"),
            ("418A", "https://uridoki.co.jp/wp-content/uploads/2024/03/favicon.png"),
            ("4193", "https://www.fabrica-hd.co.jp/application/themes/holdings/favicon.png"),
            ("4202", "https://www.daicel.com/apple-touch-icon.png"),
            ("4218", "https://www.nichiban.co.jp/apple-touch-icon.png"),
            ("4249", "https://www.moriroku.co.jp/apple-touch-icon.png"),
            ("4287", "https://www.justweb.co.jp/apple-touch-icon.png"),
            ("4393", "https://boi.jp/assets/static/apple-touch-icon.png"),
            ("4397", "https://corp.teamspirit.com/wp-content/themes/tsp/_assets/images/common/apple-touch-icon.png"),
            ("4428", "https://www.sinops.jp/cms/wp-content/themes/sinops/images/common/img_webclip_01.png"),
            ("4444", "https://www.e-infonet.jp/Portals/0/apple-touch-icon_02.png"),
            ("4628", "https://www.sk-kaken.co.jp/wp/wp-content/themes/201801_SKkakenWP-2/lib/favicons/apple-touch-icon.png"),
            ("4705", "https://www.clip-cor.co.jp/apple-touch-icon.png"),
            ("4848", "https://www.fullcastholdings.co.jp/assets/img/common/favicon.png"),
            ("4973", "https://www.netjpc.com/Portals/0/apple-touch-icon.png"),
            ("5233", "https://www.taiheiyo-cement.co.jp/assets/images/common/apple-touch-icon.png"),
            ("5279", "https://www.nihon-kogyo.co.jp/images/apple-touch-icon.jpg"),
            ("5401", "https://www.nipponsteel.com/app-files/img/symbol/apple-touch-icon.webp"),
            ("5616", "https://ame-kaze-taiyo.jp/wp-content/themes/poke-m-corp/img/amekaze-apple-touch-icon-180x180-precomposed.png"),
            ("5704", "https://www.jmc-rp.co.jp/assets/images/misc/favicon_144.png"),
            ("5834", "https://www.sbils.co.jp/wp-content/themes/SBI/assets/images/apple-touch-icon.png"),
            ("5951", "https://www.dainichi-net.co.jp/image/favicon/apple-touch-icon.png"),
            ("5992", "https://www.chkk.co.jp/common/img/apple-touch-icon.png"),
            ("6074", "https://www.jss-group.co.jp/com/img/com/apple-touch-icon-180x180.png"),
            ("6143", "https://www.sodick.co.jp/apple-touch-icon.png"),
            ("6145", "https://nittoku.co.jp/wp_201912/wp-content/themes/nittoku/assets/images/common/apple-touch-icon.png"),
            ("6265", "https://www.convum.co.jp/apple-touch-icon.png"),
            ("6284", "https://www.nisseiasb.co.jp/apple-touch-icon.png"),
            ("6310", "https://www.iseki.co.jp/cms/wp-content/themes/iseki_corporate_v2/assets/img/apple-touch-icon.png"),
            ("6436", "https://www.amano.co.jp/assets/img/common/apple-touch-icon.png"),
            ("6532", "https://www.baycurrent.co.jp/wp-content/themes/baycurrent-template-v3/assets/img/common/apple-touch-icon.png"),
            ("6561", "https://hanatourjapan.jp/images/favicon.png"),
            ("6654", "https://www.fujidk.co.jp/common/img/apple-touch-icon-precomposed.png"),
            ("6866", "https://www.hioki.com/themes/hioki/common/images/apple-touch-icon.png"),
            ("6870", "https://www.fenwal.co.jp/wp/wp-content/uploads/2021/06/favicon-1.png"),
            ("7059", "https://www.copro-h.co.jp/img/apple-touch-icon.png"),
            ("7073", "https://www.jaic-g.com/wp-jaic/wp-content/themes/wp-theme/assets/images/meta/apple-touch-icon.png"),
            ("7184", "https://www.first-bank.co.jp/common_v3/images/favicon.ico"),
            ("7256", "https://www.kasai.co.jp/apple-touch-icon.png"),
            ("7353", "https://www.kiyo-learning.com/apple-touch-icon-152x152.png"),
            ("7701", "https://www.shimadzu.co.jp/apple-touch-icon.png"),
            ("7723", "https://www.aichitokei.co.jp/apple-touch-icon.png"),
            ("7811", "https://www.npacks.co.jp/wpress/wp-content/themes/nakamoto/assets/img/common/apple-touch-icon.png"),
            ("7966", "https://www.lintec.co.jp/common/images/symbol/apple-touch-icon.png"),
            ("8091", "https://www.nichimo.co.jp/common/img/apple-touch-icon.png"),
            ("8185", "https://www.chiyodagrp.co.jp/apple-touch-icon.png"),
            ("8273", "https://www.izumi.co.jp/apple-touch-icon-precomposed.png"),
            ("8276", "https://www.heiwado.jp/apple-touch-icon.png"),
            ("8349", "https://www.tohoku-bank.co.jp/assets/images/webclip.png"),
            ("8591", "https://www.orix.co.jp/ORIX_favicon_152x152.png"),
            ("8609", "https://www.okasan.jp/apple-touch-icon-precomposed.png"),
            ("8622", "https://www.mito.co.jp/apple-touch-icon.png"),
            ("8624", "https://file.ichiyoshi.co.jp/ichiyoshi/images/apple-touch-icon-180x180-precomposed.png?v=20261020110420"),
            ("8830", "https://www.sumitomo-rd.co.jp/apple-touch-icon.png"),
            ("8860", "https://www.fuji-jutaku.co.jp/_assets/img/common/apple-touch-icon.png"),
            ("9087", "https://www.takase.co.jp/library/6329656258959dc1460fd449/favicon/6374674c79d77142bda6f594/webclip.png?v=1670551085704"),
            ("9142", "https://www.jrkyushu.co.jp/apple-touch-icon.png"),
            ("9249", "https://www.jp-eco.co.jp/gnq78kmx-wp/wp-content/uploads/2023/10/cropped-apple-touch-icon-192x192.png"),
            ("9303", "https://www.sumitomo-soko.co.jp/img/apple-touch-icon.png"),
            ("9424", "https://www.j-com.co.jp/apple-touch-icon.png"),
            ("9471", "https://www.bunkei.co.jp/apple-touch-icon.png"),
            ("9504", "https://www.energia.co.jp/apple-touch-icon.png"),
            ("9536", "https://hd.saibugas.co.jp/common_2020/apple-touch-icon.png"),
            ("9627", "https://www.ainj.co.jp/img/apple-touch-icon.png"),
            ("9697", "https://www.capcom.co.jp/index_img/favicon.ico"),
            ("9743", "https://www.tanseisha.co.jp/wp-content/themes/www.tanseisha.co.jp/assets/img/apple-touch-icon.png"),
            ("9867", "https://www.solekia.com/apple-touch-icon.png"),
            ("9983", "https://www.fastretailing.com/favicon/apple-touch-icon.png"),
        ]
        #expect(expected.count == 99)
        #expect(Set(expected.map(\.0)).count == 99)
        #expect(
            Set(expected.map(\.0))
                .isDisjoint(with: Set(CompanyIconOriginOverride.pronexusDisclosureHomepages.keys)))
        for (code, url) in expected {
            #expect(!url.contains("prtimes.jp"), "code=\(code)")
            #expect(!url.contains("i0.wp.com"), "code=\(code)")
            #expect(
                CompanyIconOriginOverride.manualSources[code] == .imageURL(url), "code=\(code)")
        }
    }

    /// 2026-10-20 weekly: 3167 / 4678 / 8600 mark-only 512. PR #534 visual GO after wordmark reject.
    @Test func pins20261020WeeklyMarkOnlyReplacementCDNImageURLs() {
        let expected: [(String, String)] = [
            ("3167", "https://icons.sollahiro.com/company-icons/3167.png"), // pragma: allowlist secret
            ("4678", "https://icons.sollahiro.com/company-icons/4678.png"), // pragma: allowlist secret
            ("8600", "https://icons.sollahiro.com/company-icons/8600.png"), // pragma: allowlist secret
        ]
        #expect(expected.count == 3)
        #expect(Set(expected.map(\.0)).count == 3)
        #expect(
            Set(expected.map(\.0))
                .isDisjoint(with: Set(CompanyIconOriginOverride.pronexusDisclosureHomepages.keys)))
        for (code, url) in expected {
            #expect(!url.contains("prtimes.jp"), "code=\(code)")
            #expect(!url.contains("i0.wp.com"), "code=\(code)")
            #expect(url.hasSuffix("/company-icons/\(code).png"), "code=\(code)")
            #expect(
                CompanyIconOriginOverride.manualSources[code] == .imageURL(url), "code=\(code)")
        }
    }

    /// 2026-10-31: 4452 花王。横長 OGP は aspect-fit で低視認。Sorahiro visual GO のワンオフ 512 白地を R2 CDN へ。
    @Test func pins20261031KaoWordmarkReplacementCDNImageURL() {
        let url = "https://icons.sollahiro.com/company-icons/4452.png" // pragma: allowlist secret
        #expect(CompanyIconOriginOverride.manualSources["4452"] == .imageURL(url))
        #expect(!url.contains("prtimes.jp"))
        #expect(!url.contains("i0.wp.com"))
        #expect(!url.contains("kao.com"))
        #expect(url.hasSuffix("/company-icons/4452.png"))
        #expect(CompanyIconOriginOverride.pronexusDisclosureHomepages["4452"] == nil)
    }

    /// 2026-10-28 weekly replacements. Visual GO on PR #573.
    /// 251 official apple-touch / square HTTPS URLs + 3600 mark-only 180 CDN
    /// + 4450/5031 origin-blocked CDN copies of the GO'd After.
    @Test func pins20261028WeeklyReplacementGOManualImageURLs() {
        let expected: [(String, String)] = [
            ("135A", "https://vrain.co.jp/vrain/wp-content/uploads/2026/07/cropped-%E3%82%B9%E3%82%AF%E3%83%AA%E3%83%BC%E3%83%B3%E3%82%B7%E3%83%A7%E3%83%83%E3%83%88-2026-07-28-175624-180x180.png"),
            ("1375", "https://www.yukiguni-factory.co.jp/wp-content/uploads/2025/03/cropped-favicon-1-180x180.png"),
            ("137A", "https://cocolive.co.jp/newsite/wp-content/uploads/2023/03/cropped-favicon-180x180.jpg"),
            ("1384", "https://www.hokuryo.co.jp/wp-content/uploads/2019/12/cropped-%E4%BC%9A%E7%A4%BE%E3%83%AD%E3%82%B42704-180x180.png"),
            ("147A", "https://storage.googleapis.com/production-os-assets/assets/53948a70-ea2d-461c-a28c-0a44d53dea5f"),
            ("150A", "https://www.jsh-japan.jp/wp/wp-content/uploads/2020/04/cropped-logo-1-180x180.png"),
            ("153A", "https://cdn.getshifter.co/38a4d842fa3e5953fde43746f0194de650adcafc/uploads/2023/12/cropped-favicon-180x180.png"),
            ("157A", "https://greenmonster.co.jp/wp-content/themes/green-monster-theme/assets/img/icon/apple-touch-icon.png"),
            ("160A", "https://www.as-partners.co.jp/wp/wp-content/uploads/2021/10/cropped-Home_icon-180x180.png"),
            ("168A", "https://www.itamiarts.co.jp/wp-content/uploads/2023/11/cropped-header_logo-1-180x180.png"),
            ("1783", "https://fantasista-tokyo.jp/wp-content/themes/aghd/images/apple-touch-icon.png"),
            ("1813", "https://www.fudotetra.co.jp/wp-content/themes/fudoTetraTheme/assets/img/apple-touch-icon.png"),
            ("1887", "https://www.n-kokudo.co.jp/common/img/icon/apple-touch-icon.png"),
            ("192A", "https://www.integroup.jp/_assets/_common/img/favico_apple_180x180.png"),
            ("1975", "https://www.asahikogyosha.co.jp/wp-content/themes/asahikogyosha_themes_v1/assets/img/apple-touch-icon.png"),
            ("2158", "https://www.fronteo.com/hubfs/raw_assets/public/p-chan-fronteo/assets/images/common/FRONTEO_logo_TW.png"),
            ("2160", "https://www.gnipharma.com/wp/wp-content/uploads/2025/07/cropped-cropped-GNI_favicon-180x180-1-180x180.png"),
            ("2163", "https://www.artner.co.jp/wp-content/uploads/2025/06/cropped-favicon-1-1-180x180.png"),
            ("2216", "https://www.kanro.co.jp/apple-icon.png"),
            ("2222", "https://www.kotobukispirits.co.jp/resources/apple-touch-icon.png"),
            ("2293", "https://www.takizawaham.co.jp/icon/icon.png"),
            ("2301", "https://company.gakujo.ne.jp/wp-content/themes/gakujo/_assets/images/_etc/custom-icon.png"),
            ("2467", "https://vlcsecurity.com/wp-content/uploads/2025/09/cropped-logo_02_basic-180x180.png"),
            ("247A", "https://ai-robotics.co.jp/common/img/apple-icon.png"),
            ("2488", "https://www.jtp.co.jp/assets/themes/cinra/static/apple-touch-icon.png"),
            ("2493", "https://www.e-supportlink.com/wp-content/uploads/2022/04/cropped-fabicon-180x180.png"),
            ("254A", "https://aifcg.jp/wp-content/themes/AI%20FUSION%20CAPITAL%20GROUP_0317/images/touch_icon.jpg"),
            ("2593", "https://www.itoen.co.jp/wp-content/themes/itoen.co.jp/assets/static/img/common/apple-icon-152x152.png"),
            ("263A", "https://www.digitalcube.jp/wp-content/uploads/2019/07/cropped-digitalcube-site-icon-white-3-180x180.png"),
            ("2656", "https://corp.vector.co.jp/wp-content/uploads/2023/03/cropped-vector_favicon-180x180.png"),
            ("2735", "https://www.watts-jp.com/wp-content/uploads/2025/08/cropped-%E3%81%B5%E3%81%81%E3%81%B30826%E5%AE%9A-2-01-180x180.png"),
            ("2750", "https://www.ishimitsu.co.jp/wp-content/uploads/2019/06/cropped-logo_mark-1-180x180.png"),
            ("2813", "https://www.wakoushokuhin.co.jp/wp01/wp-content/uploads/2019/02/cropped-logo-180x180.png"),
            ("2884", "https://www.y-food-h.com/wp-content/uploads/2021/11/cropped-apple-touch-icon-180x180.png"),
            ("2901", "https://ishigakifoods.co.jp/wp-content/uploads/2026/03/cropped-ishigaki-favicon-512-180x180.png"),
            ("2926", "https://shinozakiya.com/wp-content/uploads/2020/05/cropped-icon-180x180.jpg"),
            ("2981", "https://landix.jp/resource/img/common/ico/apple-touch-icon.png"),
            ("2984", "https://www.yueg.co.jp/images/common/apple-touch-icon.png"),
            ("303A", "https://storage.googleapis.com/production-os-assets/assets/b5d7b1be-c7f5-4c40-b468-2ee58f66f8b0"),
            ("3045", "https://kawasaki-corp.co.jp/wp-content/uploads/2024/09/cropped-fav-180x180.jpg"),
            ("3069", "https://j-fla.com/favicon/apple-touch-icon.png"),
            ("3139", "https://www.lactojapan.com/resources/apple-touch-icon.png"),
            ("319A", "https://ngt-g.com/wp-content/uploads/2024/12/cropped-%E3%83%95%E3%82%A1%E3%83%93%E3%82%B3%E3%83%B3-180x180.png"),
            ("3238", "https://central-gd.co.jp/wp-content/uploads/2022/10/cropped-favicon-180x180.png"),
            ("3242", "https://www.urbanet.jp/assets/img/apple-touch-icon.png"),
            ("3245", "https://www.dear-life.co.jp/assets/img/apple-touch-icon.png"),
            ("324A", "https://www.booking-resort.jp/wp-content/uploads/2022/01/cropped-rglogoimg-180x180.jpg"),
            ("3252", "https://www.jinushi-jp.com/assets/favicons/apple-touch-icon.png"),
            ("325A", "https://corp.tential.jp/wp-content/uploads/2024/01/cropped-%E3%83%95%E3%82%A1%E3%83%93%E3%82%B3%E3%83%B3_144_144-180x180.png"),
            ("3276", "https://static.wixstatic.com/media/3e7db2_92eb3b00a90c439cb2362702cad7692f~mv2.png/v1/fill/w_180,h_180,lg_1,usm_0.66_1.00_0.01/3e7db2_92eb3b00a90c439cb2362702cad7692f~mv2.png"),
            ("3300", "https://am-bition.jp/wp-content/uploads/2021/09/cropped-apple-touch-icon-1-180x180.png"),
            ("3329", "https://www.towafood-net.co.jp/wp-content/themes/touwa/img/apple-touch-icon.png"),
            ("3346", "https://hirotaghd.com/wp/wp-content/uploads/2023/09/cropped-favicon-180x180.png"),
            ("3387", "https://www.createrestaurants.com/wp-content/uploads/cropped-favicon_512x512-180x180.png"),
            ("340A", "https://www.zig-zag.co.jp/wp-content/uploads/2026/07/cropped-logo_whi-180x180.png"),
            ("3415", "https://tokyobase.co.jp/assets/themes/tokyo-base/assets/static/favicon/apple-touch-icon.png"),
            ("3433", "https://www.tocalo.co.jp/resources/apple-touch-icon.png"),
            ("3440", "https://nissogroup.com/wp-content/uploads/2024/10/cropped-nisso_favicon-180x180.png"),
            ("3496", "https://azoom.jp/assets/img/webclip.png"),
            ("3521", "https://thermae-yu-hd.co.jp/wp-content/uploads/2025/09/cropped-favicon_logo-180x180.png"),
            ("3559", "https://www.p-ban.com/img/common/bookmark_icon.png"),
            ("3600", "https://icons.sollahiro.com/company-icons/3600.png"), // pragma: allowlist secret
            ("3622", "https://www.netyear.net/common/img/favicon.png"),
            ("3698", "https://www.cri-mw.co.jp/wp/wp-content/themes/cri-mw/assets/images/common/app-icon.png"),
            ("369A", "https://a-tie.co.jp/wp/wp-content/uploads/2025/08/cropped-favicon-1-180x180.png"),
            ("3723", "https://www.falcom.co.jp/page/wp-content/themes/falcom2022/assets/webclip_512.png"),
            ("3727", "https://www.aplix.co.jp/assets/images/favicon/apple-touch-icon.png"),
            ("3773", "https://www.advanced-media.co.jp/wp-content/themes/advanced-media-html/dist/assets/images/web-clipicon.png"),
            ("3775", "https://www.gaiax.co.jp/wp-content/uploads/2021/03/cropped-gaiax-favicon-1-180x180.png"),
            ("3841", "https://www.jedat.co.jp/wp-content/uploads/2022/05/cropped-super-big-icon-180x180.jpg"),
            ("3853", "https://en.asteria.com/wp-content/uploads/2022/06/android-touch-icon.png"),
            ("3865", "https://www.hokuetsucorp.com/img/apple-touch-icon.png"),
            ("3912", "https://www.mobilefactory.jp/wp-content/uploads/2018/06/cropped-dc23e8eb0e0ed23360b7ff4e78ad8f1c-180x180.png"),
            ("3920", "https://www.ibc21.co.jp/wp-content/uploads/2022/10/cropped-IBC_logomark_%E9%9D%9E%E9%80%8F%E9%81%8E-180x180.png"),
            ("3936", "https://www.globalway.co.jp/wp-content/themes/globalway/img/icon/icon-logo-180x180.png"),
            ("3985", "https://temona.co.jp/wp-content/plugins/all-in-one-seo-pack/images/default-user-image.png"),
            ("4046", "https://www.osaka-soda.co.jp/resources/apple-touch-icon.png"),
            ("4064", "https://www.carbide.co.jp/cms/wp-content/uploads/2021/08/cropped-1_1_rgb-180x180.png"),
            ("4075", "https://www.brains-tech.co.jp/wp-content/uploads/2025/12/brains-tech_logo.png"),
            ("410A", "https://www.gmo-c.jp/wp-content/uploads/2025/09/cropped-favicon_144x144-180x180.png"),
            ("4112", "https://www.hodogaya.co.jp/wp/wp-content/uploads/2022/05/cropped-cropped-favicon-180x180.png"),
            ("4196", "https://corp.neo-m.jp/hubfs/%E3%83%8D%E3%82%AA%E3%83%AD%E3%82%B4%20-%20%E5%86%86%E3%81%AE%E8%BA%AB.png"),
            ("4237", "https://www.fujipream.co.jp/wp/wp-content/uploads/2023/10/cropped-favicon-180x180.png"),
            ("4238", "https://www.miraial.co.jp/wp-content/uploads/2020/08/cropped-favicon-180x180.png"),
            ("4243", "https://nix.co.jp/cms/wp-content/themes/nix/assets/img/common/apple-touch-icon.png"),
            ("4284", "https://www.solxyz.co.jp/wp-content/uploads/2021/02/cropped-favicon-180x180.png"),
            ("428A", "https://www.cypress-holdings.co.jp/wp-content/uploads/2025/08/cropped-favicon-180x180.png"),
            ("4370", "https://mobilus.co.jp/wp-content/uploads/2021/02/cropped-fabicon-180x180.png"),
            ("4409", "https://toho-chem.co.jp/db/wp-content/themes/bone/library/images/apple-touch-icon.png"),
            ("4414", "https://www.flect.co.jp/wp-content/uploads/2023/05/cropped-favicon-180x180.png"),
            ("4439", "https://www.toumei.co.jp/image/ogp.jpg"),
            ("4441", "https://tobila.com/wp/wp-content/uploads/2026/08/443e3dc8443e083f2d72c5267a94a1b6-320x320.png"),
            ("4450", "https://icons.sollahiro.com/company-icons/4450.png"), // pragma: allowlist secret
            ("4465", "https://www.niitaka.co.jp/images/apple-touch-icon.png"),
            ("4479", "https://www.makuake.co.jp/img/apple-touch-icon.png"),
            ("4544", "https://www.hugp.com/resources/img/common/favicon/apple-touch-icon.png"),
            ("4568", "https://www.daiichisankyo.co.jp/Portals/0/DS_Apple_Touch_Icon_RGB_180x180px_200507.png"),
            ("4571", "https://www.nano-hd.com/nanocms/wp-content/themes/original_20260322/img/common/logo.png"),
            ("4633", "https://www.inx.co.jp/common/favicon/apple-touch-icon.png"),
            ("4642", "https://www.oec-solution.co.jp/apple-touch-icon.png"),
            ("4644", "https://www.imagineer.co.jp/images/basic.png"),
            ("4664", "https://www.trsc.co.jp/wrscp/wp-content/uploads/2024/11/cropped-favicon-180x180.png"),
            ("4685", "https://www.ryoyu.co.jp/assets/img/common/site-icon-192.png"),
            ("471A", "https://nsg-inc.co.jp/wp-content/uploads/2024/12/cropped-favicon-180x180.png"),
            ("4735", "https://group.kyoshin.co.jp/wp-content/uploads/sites/2/2024/05/cropped-favicon-180x180.png"),
            ("4746", "https://www.toukei.co.jp/wp-content/uploads/2025/02/cropped-tcc-favicon-180x180.png"),
            ("4751", "https://d1kdu080g8vme4.cloudfront.net/files/user/img/common/ogp/apple-touch-icon.png?version=1506600472"),
            ("4760", "https://www.popalpha.co.jp/cms/wp-content/uploads/2019/01/cropped-logo_alpha-1-180x180.png"),
            ("4777", "https://cdn.prod.website-files.com/65b09eef31dcbaedbc68ce12/65f7d8867d923d7d2a1fc7ec_webclip.png"),
            ("4801", "https://www.central.co.jp/apple-touch-icon.png"),
            ("4809", "https://paraca.co.jp/mg/wp-content/uploads/2025/10/cropped-cropped-siteicon-180x180.jpg"),
            ("4826", "https://www.cij.co.jp/wp-content/uploads/cropped-favicon-180x180.png"),
            ("4833", "https://def-consulting.co.jp/wp-content/themes/def-consulting/assets/favicon/apple-touch-icon.png"),
            ("4883", "https://modalistx.com/wp-content/uploads/2025/03/cropped-modalis-favicon-180x180.png"),
            ("4932", "https://www.almado.co.jp/wordpress/wp-content/themes/almado/favicon/apple-touch-icon.png"),
            ("4936", "https://axxzia.co.jp/assets/img/apple-touch-icon.png"),
            ("5031", "https://icons.sollahiro.com/company-icons/5031.png"), // pragma: allowlist secret
            ("5035", "https://cdn.prod.website-files.com/60ed5df2530e651a48bcd5cd/61f3a0dfd0062b2caf03a667_housei_webclip.png"),
            ("5132", "https://cdn.clipkit.co/tenants/942/sites/touch_icons/000/000/001/square/e109fbe8-0953-49b8-a728-f56f3dcb25b3.png?1604852566"),
            ("5136", "https://tripla.io/wp-content/uploads/2023/05/cropped-icon-180x180.png"),
            ("5138", "https://www.rebase.co.jp/images/webclip.png"),
            ("520A", "https://www.j-pharma.com/assets/img/cropped-favicon-180x180.png"),
            ("5262", "https://www.nipponhume.co.jp/wp/wp-content/uploads/2023/04/cropped-logo_2-180x180.png"),
            ("5310", "https://www.toyotanso.co.jp/img/common/apple-touch-icon.png"),
            ("5542", "https://www.shst.co.jp/wp-content/uploads/2025/01/cropped-favicon-180x180.jpg"),
            ("556A", "https://corp.inuneko-seikatsu.co.jp/inunkeko_cms/wp-content/uploads/2025/09/cropped-logo%E9%80%8F-3-180x180.png"),
            ("5571", "https://www.excite-holdings.co.jp/wp-content/uploads/2023/02/cropped-cropped-lep-180x180.png"),
            ("5588", "https://www.fastaccounting.jp/wp-content/uploads/2020/08/cropped-favicon_white-180x180.png"),
            ("5612", "https://www.nichu.co.jp/wp-content/themes/nck/assets/images/apple-touch-icon.png"),
            ("5619", "https://www.mrso.co.jp/images/common/cropped-icon-180x180.png"),
            ("5631", "https://www.jsw.co.jp:443/common/favicon/apple-touch-icon.png"),
            ("5699", "https://www.ibokin.co.jp/wordpress/wp-content/uploads/2026/08/cropped-apple-touch-icon-180x180.png"),
            ("5753", "https://www.nippon-shindo.co.jp/wp/wp-content/uploads/2019/01/cropped-icon-180x180.png"),
            ("5816", "https://www.onamba.co.jp/wp/wp-content/uploads/2022/05/cropped-favicon-180x180.png"),
            ("5933", "https://alinco.co.jp/apple-icon.png?b531c56825ffda31"),
            ("5952", "https://www.amatei.co.jp/wp/wp-content/uploads/2024/06/cropped-d4ea1e65fa2516d74f263f43724a4a6f-180x180.png"),
            ("6031", "https://zeta.inc/wp-content/uploads/2025/07/cropped-4431d9c0b317ff9fef936d07301ff5e5-180x180.png"),
            ("6061", "https://uni-green.co.jp/wp-content/uploads/2022/12/cropped-cropped-favicon-180x180.png"),
            ("6088", "https://www.sigmaxyz.com/resources/apple-touch-icon.png"),
            ("6099", "https://www.kkelan.com/wp-content/uploads/2022/06/cropped-favicon-1-180x180.png"),
            ("6155", "https://www.takamaz.co.jp/wp/wp-content/themes/takamaz.co.jp/assets/images/webclip.jpg"),
            ("6171", "https://www.dksiken.co.jp/wp-content/uploads/2023/01/cropped-DK-logo-512-180x180.png"),
            ("6186", "https://www.ichikura.jp/_wsys/wp-content/themes/ichikura_corp/assets/images/common/favicon/apple-touch-icon.png"),
            ("6224", "https://corp.jrcnet.co.jp/wp-content/uploads/2025/01/cropped-favicon-1-180x180.png"),
            ("6228", "https://www.globaljet.jp/wp-content/uploads/2023/03/cropped-favicon-180x180.png"),
            ("6268", "https://www.nabtesco.com/cms/wp-content/uploads/cropped-favicon-180x180.png"),
            ("6289", "https://www.giken.com/ja/wp-content/uploads/2017/09/cropped-favicon-180x180.png"),
            ("6325", "https://www.takakita-net.co.jp/favicon/apple-touch-icon.png"),
            ("6335", "https://www.tks-net.co.jp/corporate/wp-content/uploads/2022/07/cropped-favicon-180x180.png"),
            ("6346", "https://www.kikukawa.co.jp/cms/wp-content/uploads/2024/03/cropped-favicon-1-180x180.jpg"),
            ("6357", "https://www.sansei-technologies.com/wp-content/uploads/2025/06/cropped-favicon-180x180.png"),
            ("6367", "https://www.daikin.co.jp/-/media/640E2D69C822493AB9DFC6EC0228A0CB.ashx"),
            ("6381", "https://www.anestiwata-corp.com/sites/default/files/assets/images/ogpimg.png"),
            ("6395", "https://www.tadano.co.jp/wp-content/themes/tadano/assets/dist/images/favicons/apple-touch-icon.png"),
            ("6418", "https://www.jcm-hq.co.jp/resources/apple-touch-icon.png"),
            ("6464", "https://tsubaki-nakashima.com/wp-content/uploads/2025/12/cropped-favicon-180x180.png"),
            ("6479", "https://www.minebeamitsumi.com/apple-touch-icon.png"),
            ("6522", "https://www.asx.co.jp/wp-content/uploads/2020/12/cropped-as-1-180x180.png"),
            ("6554", "https://www.sus-g.co.jp/suswp/wp-content/uploads/2025/07/cropped-favicon-180x180.png"),
            ("6557", "https://aiai-group.co.jp/cms/wp-content/uploads/2021/12/cropped-favicon-aiai-180x180.png"),
            ("6651", "https://www.nito.co.jp/assets/images/favicon/apple-touch-icon.png"),
            ("6656", "https://www.inspec21.com/apple-touch-icon.png"),
            ("6662", "https://www.ubiteq.co.jp/wp-content/uploads/2023/02/cropped-ubiteq_logo-180x180.png"),
            ("6695", "https://www.castrico.co.jp/cms2024/wp-content/themes/Castrico-A/favicons/apple-touch-icon.png"),
            ("6741", "https://www.signal.co.jp/wordpress/wp-content/uploads/2021/07/cropped-favicon-270x270.png"),
            ("6803", "https://www.teac.co.jp/assets/favicon/teac-group/apple-touch-icon-152x152.png?v=eEExBk2Aa4"),
            ("6837", "https://www.kyosha.co.jp/apple-touch-icon.png"),
            ("6841", "https://www.yokogawa.co.jp/img/ipad3_retina_144x144.png"),
            ("6912", "https://kikusui-holdings.co.jp/wp-content/uploads/2022/12/cropped-khd-favicon-180x180.png"),
            ("6964", "https://www.sko.co.jp/wp-content/uploads/2019/07/cropped-sko-logo-180x180.png"),
            ("7012", "https://www.khi.co.jp/common_new/img/favicon/apple-touch-icon-180x180.png"),
            ("7021", "https://www.nitchitsu.co.jp/wp-content/files_mf/cropped-favicon-180x180.png"),
            ("7041", "https://www.crgh.co.jp/icons/icon-192x192.png?v=636d1c8776796403cc1a97c1d194ca85"),
            ("7046", "https://www.tdse.jp/wp-content/uploads/2021/11/cropped-fav-180x180.png"),
            ("7060", "https://www.geechs.com/wp-content/uploads/2022/08/cropped-%E3%83%95%E3%82%A1%E3%83%93%E3%82%B3%E3%83%B3-180x180.png"),
            ("7068", "https://feedforcegroup.jp/wp-content/uploads/2021/09/cropped-favicon-152x152-1-180x180.jpg"),
            ("7082", "https://jmty.co.jp/wp-content/uploads/2017/11/jmty_logo-1.png"),
            ("7083", "https://ahc.co.jp/ahcwp/wp-content/uploads/2022/02/cropped-apple-icon-180x180-1-180x180.png"),
            ("7089", "https://cdn.prod.website-files.com/606ab0cd3013aa344c0e3cdf/60e7d58b9569a679d97cbb1c_favicon_big.png"),
            ("7090", "https://ligua.jp/wp-content/uploads/2022/08/cropped-favicon-180x180.png"),
            ("7157", "https://ir.lifenet-seimei.co.jp/resources/apple-touch-icon.png"),
            ("7235", "https://www.tokyo-radiator.co.jp/wordpress/wp-content/uploads/2024/03/cropped-siteicon-180x180.png"),
            ("7241", "https://futabasangyo.com/wordpress/wp-content/uploads/2026/03/cropped-icon-180x180.png"),
            ("7254", "https://www.uvc.co.jp/hubfs/01.page_image/module/apple-touch-icon.png"),
            ("7279", "https://www.hi-lex.co.jp/wp-content/uploads/2023/07/cropped-favicon-180x180.png"),
            ("7291", "https://www.n-plast.co.jp/wp-content/uploads/2022/06/cropped-logo-1-180x180.png"),
            ("7294", "https://www.yorozu-corp.co.jp/wp-content/themes/YOROZU%201.0.3/images/icon/apple-touch-icon-152x152.png"),
            ("7318", "https://www.serendip-c.com/wp/wp-content/uploads/2026/05/cropped-favicon-180x180.png"),
            ("7320", "https://solvvy.co.jp/wp-content/themes/solvvy/assets/images/favicon/apple-touch-icon-180x180.png"),
            ("7361", "https://hch-ja.co.jp/mg/wp-content/uploads/2022/11/cropped-siteicon-180x180.png"),
            ("7367", "https://www.celm.co.jp/wordpress/wp-content/uploads/2023/11/cropped-favicon-180x180.png"),
            ("7426", "https://www.yamadai.com/wp-content/themes/yamadai/common/img/favicon/apple-touch-icon.png"),
            ("7510", "https://www.takebishi.co.jp/static/icons/apple-touch-icon.png"),
            ("7537", "https://www.marubun.co.jp/apple-touch-icon.png"),
            ("7567", "https://sakae-denshi.com/wp-content/uploads/2020/10/cropped-%EF%BC%88%E6%A0%AA%EF%BC%89%E6%A0%84%E9%9B%BB%E5%AD%90%E3%83%AD%E3%82%B4-300x288-1-180x180.jpg"),
            ("7585", "https://kannanmaru.co.jp/wp-content/uploads/2023/06/cropped-%E3%88%B1%E3%81%8B%E3%82%93%E3%81%AA%E3%82%93%E4%B8%B8%E3%80%80%E3%82%A2%E3%82%A4%E3%82%B3%E3%83%B3-180x180.jpg"),
            ("7606", "https://www.united-arrows.co.jp/wp-content/themes/united-arrows/assets/config/apple-touch-icon.png"),
            ("7608", "https://www.sk-japan.co.jp/wp-content/uploads/2021/06/cropped-favicon-180x180.jpg"),
            ("7678", "https://www.asakuma.co.jp/images/top-asakuma.jpg"),
            ("7683", "https://www.wa-jp.com/wp2024/wp-content/uploads/2024/09/cropped-apple-touch-icon-1-180x180.png"),
            ("7687", "https://corp.micreed.co.jp/assets/img/favicon/apple-touch-icon.png"),
            ("7689", "https://www.copa.co.jp/wp-content/themes/copa-corp/assets/images/apple-touch-icon-precomposed.png"),
            ("7790", "https://barcos.jp/wp/wp-content/uploads/cropped-favicon_logo-180x180.png"),
            ("7809", "https://company.kotobukiya.co.jp/wp-content/uploads/2022/06/cropped-cropped-favicon-180x180.png"),
            ("7821", "https://www.maedakosen.jp/wp/wp-content/themes/mdk/images/logo.jpg"),
            ("7831", "https://www.wellco-corp.com/wp-content/uploads/2025/01/cropped-wellcoHD-icon-180x180.png"),
            ("7841", "https://endo-mfg.co.jp/apple-touch-icon.png"),
            ("7850", "https://www.shouken.co.jp/sp/wp-content/themes/shouken/uploads/images/cropped-apple-touch-icon-180x180.png"),
            ("7856", "https://www.hagihara.co.jp/cms/wp-content/uploads/27039d9f3f402c48e8fababb3e87ed9e-300x297.jpg"),
            ("7871", "https://www.fukuvi.co.jp/application/files/9115/3973/9928/apple-touch-icon.png"),
            ("7874", "https://www.lecinc.co.jp/wp-content/uploads/2021/02/cropped-favicons-180x180.png"),
            ("7917", "https://www.zacros.co.jp/wp-content/uploads/2024/09/cropped-newlogo_fav-180x180.png"),
            ("7936", "https://assets.asics.com/page_types/4043/files/corp_ogp_original.jpg?1560319228"),
            ("7946", "https://cdn.prod.website-files.com/65656bd9b9576a75a4eca3d5/65b07dfba478bf4894a81402_koyosya-webclip.png"),
            ("7975", "https://www.lihit-lab.com/wp-content/uploads/2021/10/cropped-favicon-180x180.jpg"),
            ("7987", "https://www.nakabayashi.co.jp/common/img/icon.png"),
            ("8032", "https://www.kamipa.co.jp/wp/wp-content/themes/jp-2017/touch-icon.png"),
            ("8107", "https://www.kimuratan.co.jp/corporate_cms/wp-content/uploads/2025/03/cropped-favicon-180x180.png"),
            ("8129", "https://www.tohohd.co.jp/apple-touch-icon.png"),
            ("8200", "https://www.ringerhut.co.jp/common_2017/img/apple-touch-icon.png"),
            ("8218", "https://www.komeri.bit.or.jp/img/favicon/152.png"),
            ("8260", "https://www.izutsuya.co.jp/touch_icon.png"),
            ("8278", "https://www.the-fuji.com/common_v14/apple-touch-icon.png"),
            ("8537", "https://www.taikobank.jp/undefined/favicons/apple-touch-icon-180x180.png"),
            ("8550", "https://www.tochigibank.co.jp/common/images/tochigi_ogp.jpg"),
            ("8708", "https://www.aizawa-group.jp/apple-touch-icon.png"),
            ("8771", "https://www.eguarantee.co.jp/wp-content/uploads/2023/03/cropped-favicon-180x180.png"),
            ("8914", "https://www.arealink.co.jp/apple-touch-icon.png"),
            ("9008", "https://www.keio.co.jp/assets/img/apple-touch-icon.png"),
            ("9036", "https://www.tohbu.co.jp/wp-content/themes/tbn_corpolate/assets/img/common/icon-favicon-180x180.png"),
            ("9107", "https://www.kline.co.jp/resources/apple-touch-icon.png"),
            ("9110", "https://www.nsuship.co.jp/resources/apple-touch-icon.png"),
            ("9166", "https://genda.jp/wp-content/uploads/2024/09/cropped-cropped-GENDA_favicon-150x150-1-180x180.png"),
            ("9214", "https://www.recovery-group.co.jp/wp-content/themes/recovery/images/common/logo_ogp.png"),
            ("9229", "https://sunwels.jp/wp-content/uploads/2025/04/cropped-siteicon-180x180.png"),
            ("9240", "https://www.deliv.co.jp/hubfs/corp_2022/files/images/apple-touch-icon.png"),
            ("9251", "https://ab-company.co.jp/cropped-abc-logo_transparent-180x180.png"),
            ("9278", "https://www.bookoffgroup.co.jp/management/wp-content/uploads/2025/05/cropped-bogh-favicon-180x180.jpg"),
            ("9279", "https://cdn.prod.website-files.com/63ef03c2b82a66a06802f5f0/63ef0496a31e98089d9deb03_webclip.png"),
            ("9332", "https://www.nisso-hd.com/assets_hd/images/apple.png"),
            ("9381", "https://www.ait-jp.com/wp/wp-content/uploads/2022/01/cropped-AIT512x512-180x180.png"),
            ("9434", "https://www.softbank.jp/site/set/common/shared/img/icon_softbank.gif"),
            ("9475", "https://www.mapple.co.jp/wp/wp-content/themes/mapple/assets/favicon/apple-touch-icon.png"),
            ("9556", "https://www.intloop.com/wp-content/themes/intloop_241023/assets/images/common/apple-touch-icon.png"),
            ("9601", "https://www.shochiku.co.jp/wp-content/themes/shochiku2025/images/ogp.png"),
            ("9699", "https://nishio-grp.co.jp/wordpress/wp-content/uploads/2023/04/cropped-fav-2-180x180.png"),
            ("9716", "https://www.nomurakougei.co.jp/img/apple-touch-icon.png"),
            ("9723", "https://www.kyotohotel.co.jp/wp-content/themes/group_temp/favicon-icon.png?date=20190401"),
            ("9769", "https://www.gakkyusha.com/wp-content/uploads/2026/08/cropped-cropped-cropped-favicon-180x180.png"),
            ("9902", "https://www.nichiden.com/cms/wp-content/themes/nichiden/apple-touch-icon-180x180.png"),
            ("9932", "https://www.sugi-net.co.jp/corp/wp-content/uploads/2021/02/cropped-favicon-180x180.png"),
            ("9941", "https://www.taiyo-bussan.co.jp/wp-content/uploads/2018/12/cropped-sitelogo_single-180x180.png"),
            ("9978", "https://www.bunkyodo.co.jp/wp-content/uploads/2021/10/cropped-favicon_512x512-180x180.jpg"),
            ("9984", "https://group.softbank/sites/default/files/assets/img/logo-group-square.png"),
        ]
        #expect(expected.count == 254)
        #expect(Set(expected.map(\.0)).count == 254)
        for (code, url) in expected {
            #expect(!url.contains("prtimes.jp"), "code=\(code)")
            #expect(!url.contains("i0.wp.com"), "code=\(code)")
            #expect(
                CompanyIconOriginOverride.manualSources[code] == .imageURL(url), "code=\(code)")
        }
        #expect(expected.contains { $0.0 == "3600" && $0.1.hasSuffix("/company-icons/3600.png") })
        #expect(expected.contains { $0.0 == "4450" && $0.1.hasSuffix("/company-icons/4450.png") })
        #expect(expected.contains { $0.0 == "5031" && $0.1.hasSuffix("/company-icons/5031.png") })
    }

    /// 2026-10-20 weekly: listed × company_icons 欠行。公告 URL が origin パース不能／注記委譲。
    /// 公式 apple-touch / 中央マークのある OGP。単色矩形 apple-touch は載せない。
    @Test func pins20261020WeeklyMissingListedManualImageURLs() {
        let expected: [(String, String)] = [
            ("1788", "https://www.santo.co.jp/app/wp-content/uploads/2025/06/cropped-favicon-192x192.png"),
            ("2286", "https://www.hayashikane.co.jp/_assets/img/common/ogp.png"),
            ("3901", "https://www.marklines.com/apple-touch-icon.png"),
        ]
        #expect(expected.count == 3)
        #expect(Set(expected.map(\.0)).count == 3)
        #expect(CompanyIconOriginOverride.manualSources["2976"] == nil)
        #expect(CompanyIconOriginOverride.manualSources["7509"] == nil)
        #expect(
            Set(expected.map(\.0))
                .isDisjoint(with: Set(CompanyIconOriginOverride.pronexusDisclosureHomepages.keys)))
        for (code, url) in expected {
            #expect(!url.contains("prtimes.jp"), "code=\(code)")
            #expect(!url.contains("i0.wp.com"), "code=\(code)")
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
