// 電子公告 URL の origin が Pronexus 掲載ドメインのとき、favicon 取得先を会社公式サイトへ差し替える。
// 手動指定（XBRL を使わない公式 HP / 公式画像）もここに置く。格納は `icons-manual`。
//
// 実データ検証（2026-09-02、Neon RO company_icons）: Pronexus origin は 17 件。うち 7893 プロネクサス
// 本体は公式サイトが `www.pronexus.co.jp` なので差し替えない。残り 16 件の公告 URL は
// `www.pronexus.co.jp/koukoku/{code}/{code}.html` → kmasterplus 法定公告一覧で、会社ホームページへの
// リンクは無い。パスを残しても Pronexus のファビコンのままになる。
// 公告ページからトップを機械抽出できないため、証券コード→公式 origin を決め打ちする。
// 有報本文に公式 URL がある会社はそれを採用し、無い会社は公式トップの社名表記で照合した。

import Foundation

/// 手動アイコンの取得元。XBRL 電子公告は使わない。
enum CompanyIconManualSource: Equatable, Sendable {
    /// 公式サイト origin（scheme+host）。favicon を取る。
    case homepageOrigin(String)
    /// 公式画像の直 URL。favicon 探索はしない。
    case imageURL(String)

    var storedSourceURL: String {
        switch self {
        case .homepageOrigin(let origin): return origin
        case .imageURL(let url): return url
        }
    }
}

enum CompanyIconOriginOverride {

    /// プロネクサス本体。電子公告 URL が自社サイトなのでマップに載せない。
    static let pronexusFilerCode = "7893"

    /// 電子公告が Pronexus 掲載ページである 16 社の公式サイト origin（scheme+host。パス無し）。
    static let pronexusDisclosureHomepages: [String: String] = [
        "1905": "https://www.tenox.co.jp",  // テノックス。ライブタイトル照合
        "3088": "https://www.matsukiyococokara.com",  // マツキヨココカラ。ライブタイトル照合
        "4238": "https://www.miraial.co.jp",  // ミライアル。短信 URL / ライブ照合
        "6412": "https://www.heiwanet.co.jp",  // 平和。有報本文
        "6482": "https://www.yushin.com",  // ＹＵＳＨＩＮ。ライブタイトル照合
        "6486": "https://www.ekkeagle.com",  // イーグル工業。ライブタイトル照合
        "6674": "https://www.gs-yuasa.com",  // ＧＳユアサ。有報本文
        "6875": "https://www.megachips.co.jp",  // メガチップス。有報本文
        "7412": "https://www.atom-corp.co.jp",  // アトム。有報本文
        "7538": "https://www.daisui.co.jp",  // 大水。ライブタイトル照合
        "7896": "https://www.seven-gr.co.jp",  // セブン工業。有報本文
        "8153": "https://www.mos.co.jp",  // モスフードサービス。有報本文
        "8766": "https://www.tokiomarinehd.com",  // 東京海上HD。有報本文
        "8928": "https://www.anabuki.ne.jp",  // 穴吹興産。ライブタイトル照合
        "9441": "https://www.bellpark.co.jp",  // ベルパーク。ライブタイトル照合
        "9684": "https://www.hd.square-enix.com",  // スクエニHD。ライブタイトル照合
    ]

    /// XBRL 電子公告を使わず favicon / 公式画像を取る決め打ち。格納は `icons-manual`。
    /// 7203: トヨタ自動車。公式コンシューマサイト `https://toyota.jp/index.html`（origin のみ保持）。
    /// 9267: Genky DrugStores。有報の公告 URL は frameset のみの `genkydrugstores.co.jp`。
    /// 公式 `logo.png` は中間証明書欠落で URLSession が落ちるので homepage origin のまま。
    /// 581A: ＧＯ。タクシーアプリ `https://go.goinc.jp` の 190px PNG。コーポレート
    /// `goinc.jp` の 32px favicon は白地が多く iOS の白背景で消える。
    /// 8887: シーラ HD。`/favicon.ico` が 16x16 1bit（198B）で iOS が読めない。WP 192px PNG を直指定。
    /// 6150: タケダ機械。公告掲載方法が日本経済新聞のみ（`not_applicable`）。
    /// 7888: 三光合成。電子公告と書くが公告行に URL が無い（IR の公式 HP を使う）。
    /// 8473: SBI HD。持株会社トップの favicon は 16×16。SBI 証券 `sbisec.co.jp` の 180px apple-touch。
    /// 7177: GMOFG。持株会社トップの favicon は 16×16。GMO グループ `group.gmo` の 144px PNG。
    /// 8630: SOMPO HD。電子公告 origin の favicon は 16×16 で潰れる。公式 apple-touch 152px。
    /// 8616: 東海東京 FG。同上、公式 apple-touch 144px。
    /// 2653: イオン九州。電子公告 URL が取れず行が無い。公式 apple-touch-precomposed 180px。
    /// 2026-09-12 icons audit: priority A 2462 / 8377（9267 は上）+ missing-batch B 57 社。
    /// apple-touch 優先。無い会社は検証済み OGP（多くは 1200×630）。6902 デンソーは対象外。
    /// 8377 はほくほく FG の corporate_mark。北海道銀行 apple-touch は使わない。
    /// 2026-09-18: 欠行の売上上位 20 社。先頭 rel=icon が小さい／origin 直下が 404 のため imageURL。
    /// 7459 の logo_facebook.png は Facebook マークなので favicon.ico（256px 本体マーク）を使う。
    /// 5334 の ogp は niterragroup.com へリダイレクトする。
    /// 2026-09-20: visual GO。9432 NTT 公式 apple-touch。9439 / 7427 / 9412 は R2 CDN。
    /// prtimes.jp 直リンクは使わない。
    /// 2026-09-20 weekly: listed × company_icons 欠行。自動 pipeline 不能（紙面・URL無し・
    /// Pronexus・先頭 rel=icon が極小）の公式画像。5805 の origin apple-touch は小冊子なので不採用。
    /// 7236 ティラドは添付高解像度ロゴを白地・余白の 512 PNG にして R2 CDN へ（公式 192 は低解像）。
    /// 2026-09-21 weekly: 公告 URL 無し／紙面／Pronexus の欠行。公式 apple-touch / 正方形 /
    /// 検証済み OGP。フッター SNS・別名ドメイン・横長ワードマーク OGP は載せない。
    /// 8370 紀陽銀行はユーザー指定でマスコット中央のみを 512 白地にして R2 CDN へ（公式 OGP は横長ロックアップ）。
    /// 603A: アイ・グリッド・ソリューションズ。先頭 rel=icon が 16.jpg のため apple-touch 256.jpg。
    /// 2026-09-28 weekly: 公告紙面／URL無し／Pronexus の欠行。公式 apple-touch / 正方形 /
    /// 中央マークのある OGP。Jetpack CDN・横長ワードマーク OGP は載せない。
    /// 9445: コーポレート origin が timeout のため自社 DX サービス apple-touch。
    /// 2195 / 2894 / 6203 / 7265: ユーザー指定のワンオフ 512 白地クロップを R2 CDN へ。
    /// 2026-10-05 weekly: 公告紙面／URL無し／Pronexus の欠行。公式 apple-touch / 正方形 /
    /// 中央マークのある OGP。単色矩形・SNS の X・横長ワードマーク OGP は載せない。
    /// 2026-10-20 weekly: 公告 URL が origin パース不能／注記委譲の欠行。公式 apple-touch /
    /// 中央マークのある OGP。apple-touch の単色矩形は使わず OGP へ（2286）。
    /// 2026-10-20 weekly replacements: same-origin 16px→公式 apple-touch / 正方形。
    /// Visual GO は PR #534（99 公式 URL + 3 マークのみ 512 CDN）。
    /// 2026-10-31: 4452 花王。横長 OGP はアプリの aspect-fit で低視認。Sorahiro visual GO
    /// のワンオフ 512 白地を R2 CDN へ（公式の横長 OGP は残さない）。
    /// 2026-10-31: 3723 日本ファルコム F マーク / 9008 京王電鉄ワードマーク。Sorahiro visual GO
    /// のワンオフ 512 白地を R2 CDN へ（公式 URL は ingest 不能。本番キーへ先置き）。
    /// 2026-10-31: 2802 / 2871 / 3539 / 4075 / 7963 / 9240。Sorahiro visual GO の
    /// ワンオフ 512 白地を R2 CDN へ（本番キーへ先置き。ingest は CDN sha 一致後）。
    static let manualSources: [String: CompanyIconManualSource] = [
        "7203": .homepageOrigin("https://toyota.jp"),
        "9267": .homepageOrigin("https://www.genky.co.jp"),
        "581A": .imageURL("https://go.goinc.jp/android-chrome.png"),
        "8887": .imageURL(
            "https://syla-holdings.jp/wp-content/uploads/2025/05/cropped-favicon-192x192.png"),
        "6150": .homepageOrigin("https://www.takeda-mc.co.jp"),
        "7888": .homepageOrigin("https://www.sankogosei.co.jp"),
        "8473": .imageURL("https://www.sbisec.co.jp/apple-touch-icon.png"),
        "7177": .imageURL("https://group.gmo/favicon_144x144.png"),
        "8630": .imageURL("https://www.sompo-hd.com/sompohd/common/images/apple-touch-icon.png"),
        "8616": .imageURL("https://www.tokaitokyo-fh.jp/asset/img/common/apple-touch-icon.png"),
        "2653": .imageURL("https://www.aeon-kyushu.info/apple-touch-icon-precomposed.png"),
        "2462": .imageURL("https://www.like-gr.co.jp/wp/wp-content/themes/like.1801/152x152.png"),
        "8377": .imageURL(
            "https://www.hokuhoku-fg.co.jp/assets/images/pages/info/idea/corporate_mark.png"),
        "4188": .imageURL("https://www.mcgc.com/assets/img/og-image.jpg"),
        "9531": .imageURL("https://www.tokyo-gas.co.jp/apple-touch-icon.png"),
        "3402": .imageURL("https://www.toray.com/apple-touch-icon.png"),
        "9201": .imageURL("https://www.jal.com/favicon.ico"),
        "4452": .imageURL("https://icons.sollahiro.com/company-icons/4452.png"), // R2 CDN Kao wordmark 512 // pragma: allowlist secret
        "6724": .imageURL("https://www.epson.jp/images/ogp_img.png"),
        "4204": .imageURL("https://www.sekisui.co.jp/resource/img/ogp.png"),
        "5801": .imageURL("https://www.furukawaelectric.com/common/images/ogimage.png"),
        "5076": .imageURL("https://www.infroneer.com/images/ogp.png"),
        "2733": .imageURL("https://www.arata-gr.jp/assets_renew/images/ogp.jpg"),
        "6471": .imageURL("https://www.nsk.com/content/dam/nsk/common/logo/nsk_logo.png"),
        "9956": .imageURL(
            "https://valorholdings.co.jp/wp-content/themes/valor-template/common/img/ogp.jpg"),
        "8282": .imageURL("https://www.ksdenki.co.jp/favicon.ico"),
        "5332": .imageURL("https://jp.toto.com/favicon.ico"),
        "8075": .imageURL("https://www.shinsho.co.jp/apple-touch-icon.png"),
        "4676": .imageURL("https://www.fujimediahd.co.jp/assets/img/ogp.png"),
        "3050": .imageURL("https://www.dcm-hc.co.jp/ogp.png"),
        "4507": .imageURL("https://www.shionogi.com/content/dam/shionogi/img/apple-touch-icon.png"),
        "7186": .imageURL(
            "https://www.yokohamafg.co.jp/shared/img/company/summary/brand/img-brand.jpg"),
        "1861": .imageURL("https://www.kumagaigumi.co.jp/assets/img/common/ogp_jp.webp"),
        "8253": .imageURL(
            "https://www.saisoncard.co.jp/proxy_img/assets/462949b256274358947c3db996c948d4/c9aadfc16cc54456a31ffeb0a340fd31/og.png"),
        "3086": .imageURL("https://www.j-front-retailing.com/apple-touch-icon.png"),
        "8173": .imageURL("https://www.joshin.co.jp/resources/apple-touch-icon.png"),
        "9007": .imageURL("https://www.odakyu.jp/apple-touch-icon.png"),
        "9974": .imageURL(
            "https://www.belc.jp/themes/custom/belc/img/favicons/apple-touch-icon-180x180.png"),
        "4205": .imageURL("https://www.zeon.co.jp/app-files/img/symbol/ogp.png"),
        "3465": .imageURL("https://ki-group.co.jp/ogp_cojp.jpg"),
        "7283": .imageURL("https://www.aisan-ind.co.jp/assets/images/ogp.png"),
        "7616": .imageURL("https://www.colowide.co.jp/cmn/img/favicon.ico"),
        "9468": .imageURL(
            "https://group.kadokawa.co.jp/archives/001/202105/22600750dd2c4bde9feea9045aa782873795fad55c1ca265cb6b11f176e5aabc.jpg"),
        "9072": .imageURL("https://www.nikkon-hd.co.jp/assets/images/ogp.png"),
        "6005": .imageURL("https://www.miuraz.co.jp/assets/img/ogp.png"),
        "4403": .imageURL("https://www.nof.co.jp/assets/images/favicon.ico"),
        "1961": .imageURL("https://www.sanki.co.jp/apple-touch-icon.png"),
        "2695": .imageURL("https://www.kurasushi.co.jp/shared/img/ogp.png"),
        "1941": .imageURL("https://www.chudenko.co.jp/images/favicon.ico"),
        "3036": .imageURL("https://www.alconix.com/assets/img/ogimage.png"),
        "6966": .imageURL("https://www.mitsui-high-tec.com/common/img/ogp.jpg"),
        "9470": .imageURL("https://www.gakken.co.jp/ja/ogpImage/OGP_GHDcorp.png"),
        "3539": .imageURL("https://icons.sollahiro.com/company-icons/3539.png"), // R2 CDN Jm mark 512 // pragma: allowlist secret
        "2767": .imageURL(
            "https://www.tsuburaya-fields.co.jp/newscms/wp-content/themes/tsuburaya/assets/img/ogp.png"),
        "2146": .imageURL("https://www.ut-g.co.jp/assets/img/common/ogp/ogp.png"),
        "4812": .imageURL("https://www.dentsusoken.com/themes/dentsusoken/assets/image/ogimage.png"),
        "9619": .imageURL("https://www.ichinenhd.co.jp/assets/img/common/ogp.jpg"),
        "5444": .imageURL("https://www.yamatokogyo.co.jp/common/img/ogp.jpg"),
        "9994": .imageURL("https://www.yamaya.jp/ynhp/img/yamaya_social_image.png"),
        "5408": .imageURL("https://www.nakayama-steel.co.jp/cmn/img/ogp.jpg"),
        "8136": .imageURL("https://corporate.sanrio.co.jp/img/ogp/img_sanrio.png"),
        "1968": .imageURL("https://www.taihei-dengyo.co.jp/common_rwd/img/icon_180_180.png"),
        "2220": .imageURL("https://www.kamedaseika.co.jp/wp-content/uploads/2022/02/ogp.png"),
        "8111": .imageURL("https://www.goldwin.co.jp/static/full/images/store/ogp/onlinestore/ogp.png"),
        "6794": .imageURL("https://www.foster.co.jp/app-files/img/symbol/ogp.webp"),
        "9119": .imageURL("https://www.iino.co.jp/kaiun/files/ogp.png"),
        "4569": .imageURL("https://www.kyorin-pharm.co.jp/assets/img/og-image.png"),
        "5161": .imageURL("https://www.nishikawa-rbr.co.jp/assets/images/common/ogp.png"),
        "7564": .imageURL("https://www.workman.co.jp/apple-touch-icon.png"),
        "9759": .imageURL("https://www.nsd.co.jp/app-files/img/symbol/ogp.webp"),
        "8001": .imageURL("https://www.itochu.co.jp/ja/apple-touch-icon.png"),
        "8002": .imageURL("https://www.marubeni.com/apple-touch-icon.png"),
        "7459": .imageURL("https://www.medipal.co.jp/favicon.ico"),
        "2784": .imageURL("https://www.alfresa.com/assets/img/common/ogp.png"),
        "9508": .imageURL("https://www.kyuden.co.jp/library/2017/images/common/fb.png"),
        "2181": .imageURL("https://www.persol-group.co.jp/images/common/apple-touch-icon-152x152.png"),
        "3291": .imageURL("https://www.ighd.co.jp/assets/common/images/favicon-192x192.png"),
        "4324": .imageURL("https://www.group.dentsu.com/common/image/apple-touch-icon.png"),
        "5334": .imageURL("https://www.niterragroup.com/ogp.png"),
        "3360": .imageURL(
            "https://www.shiphd.co.jp/wp-content/themes/shiptheme/assets/img/common/favicon.png"),
        "8060": .imageURL(
            "https://corporate.jp.canon/-/media/Project/Canon/CanonJP/Website/shared/image/icon/apple-touch-icon.png?la=ja-JP"),
        "2602": .imageURL("https://www.nisshin-oillio.com/icon-192x192.png"),
        "3105": .imageURL("https://www.nisshinbo.co.jp/apple-touch-icon.png"),
        "9401": .imageURL("https://www.tbsholdings.co.jp/img/ogp.png"),
        "2678": .imageURL("https://www.askul.co.jp/apple-touch-icon.png"),
        "1766": .imageURL("https://www.token.co.jp/favicon.ico"),
        "2670": .imageURL("https://www.abc-mart.co.jp/new_img/common/logo.png"),
        "1885": .imageURL("https://www.toa-const.co.jp/common/img/og_image.png"),
        "8572": .imageURL("https://www.acom.co.jp/img/apple-touch-icon.png"),
        "7994": .imageURL("https://www.okamura.co.jp/global_assets/images/apple-touch-icon.png"),
        "9432": .imageURL("https://group.ntt/apple-touch-icon.png"), // NTT official apple-touch
        "9439": .imageURL("https://icons.sollahiro.com/company-icons/9439.png"), // R2 CDN // pragma: allowlist secret
        "7427": .imageURL("https://icons.sollahiro.com/company-icons/7427.png"), // R2 CDN // pragma: allowlist secret
        "9412": .imageURL("https://icons.sollahiro.com/company-icons/9412.png"), // R2 CDN // pragma: allowlist secret

        "8198": .imageURL(
            "https://www.mv-tokai.co.jp/wp/wp-content/uploads/fbrfg/apple-touch-icon.png"),
        "2206": .imageURL("https://www.glico.com/assets/images/original/glicoogp__1.png"),
        "6432": .imageURL("https://www.takeuchi-japan.com/apple-icon.png"),
        "8897": .imageURL("https://mirarth.co.jp/assets/img/common/apple-touch-icon.png"),
        "2790": .imageURL("https://www.nafco.tv/app-files/img/symbol/apple-touch-icon.webp"),
        "9706": .imageURL(
            "https://www.tokyo-airport-bldg.co.jp/site_resource/common/img/000013562.png"),
        "9682": .imageURL("https://www.dts.co.jp/apple-touch-icon.png"),
        "9413": .imageURL("https://www.tv-tokyo.co.jp/apple-touch-icon.png"),
        "2109": .imageURL(
            "https://www.msdm-hd.com/jp/app-files/img/symbol/apple-touch-icon.png"),
        "7236": .imageURL("https://icons.sollahiro.com/company-icons/7236.png"), // R2 CDN white-padded TRAD // pragma: allowlist secret
        "7414": .imageURL("https://www.onoken.co.jp/apple-touch-icon.png"),
        "6349": .imageURL("https://www.komori.com/global_common/img/webclip.png"),
        "8370": .imageURL("https://icons.sollahiro.com/company-icons/8370.png"), // R2 CDN mascot crop 512 // pragma: allowlist secret
        "4410": .imageURL("https://www.harima.co.jp/apple_touch_icon.png"),
        "8005": .imageURL(
            "https://www.scroll.jp/wp-content/themes/scr-corporate/common/img/base/apple-touch-icon.png"),
        "6999": .imageURL("https://www.koaglobal.com/common/images/iosicon.png"),
        "7630": .imageURL("https://www.ichibanya.co.jp/apple-touch-icon.png"),
        "2698": .imageURL("https://www.cando-web.co.jp/apple-touch-icon.png"),
        "4998": .imageURL("https://www.fumakilla.co.jp/apple-touch-icon.png"),
        "8386": .imageURL("https://www.114bank.co.jp/apple-touch-icon.png"),
        "8160": .imageURL(
            "https://www.kisoji.co.jp/themes/kisoji/assets/favicon/apple-touch-icon.png"),
        "8275": .imageURL("https://www.forval.co.jp/webclip.png"),
        "6941": .imageURL("https://www.yamaichi.co.jp/img/apple-touch-icon-152x152.png"),
        "8387": .imageURL(
            "https://www.shikokubank.co.jp/apple-touch-icon-precomposed.png"),
        "1892": .imageURL("https://www.tokura.co.jp/media/001/202602/ogp.png"),
        "1798": .imageURL("https://www.moriya-s.co.jp/files/favicon/apple-touch-icon.png"),
        "4635": .imageURL("https://www.tokyoink.co.jp/apple-touch-icon.png"),
        "7879": .imageURL("https://www.noda-co.jp/common/favicon/apple-touch-icon.png"),
        "2329": .imageURL("https://www.tfc.co.jp/cms/apple-touch-icon.png"),
        "7715": .imageURL(
            "https://www.naganokeiki.co.jp/common/favicon/apple-touch-icon.png"),
        "9622": .imageURL("https://www.space-tokyo.co.jp/assets/img/apple-touch-icon.png"),
        "603A": .imageURL(
            "https://igrid.co.jp/wp-content/themes/igrid2024/dist/img/favicon/256.jpg"),
        "2195": .imageURL("https://icons.sollahiro.com/company-icons/2195.png"), // R2 CDN AMITA wordmark 512 // pragma: allowlist secret
        "2395": .imageURL("https://snbl.com/wp-content/themes/snbl/apple-touch-icon.png"),
        "2449": .imageURL(
            "https://www.prap.co.jp/wp/wp-content/themes/custom-theme/apple-touch-icon.png"),
        "2894": .imageURL("https://icons.sollahiro.com/company-icons/2894.png"), // R2 CDN tight crop 512 // pragma: allowlist secret
        "3083": .imageURL(
            "https://starseeds.co.jp/cms/wp-content/themes/corporate-theme/assets/icons/apple-touch-icon.png"),
        "3123": .imageURL("https://www.saibo.co.jp/img/saibohp/favicon02.ico"),
        "339A": .imageURL(
            "https://progresstech-group.jp/assets/images/common/apple-touch-icon-180x180.png"),
        "3653": .imageURL("https://www.morphoinc.com/assets/images/common/singleicon.png"),
        "4056": .imageURL("https://www.neural-group.com/assets/img/apple-touch-icon.png"),
        "4092": .imageURL("https://www.nippon-chem.co.jp/apple-touch-icon.png"),
        "4436": .imageURL(
            "https://minkabu.co.jp/wp-content/themes/wp-thema-infonoid-web-2022-main/assets/meta/apple-touch-icon.png"),
        "446A": .imageURL("https://northsand.co.jp/wp-content/uploads/2025/10/cropped-n.png"),
        "4673": .imageURL(
            "https://www.kge.co.jp/wp-bridge2026/wp-content/uploads/2026/08/cropped-apple-touch-icon-180x180.png"),
        "4819": .imageURL(
            "https://www.garage.co.jp/wp/wp-content/themes/garage/assets/config/apple-touch-icon.jpg"),
        "5659": .imageURL(
            "https://www.n-seisen.co.jp/assets/images/common/apple-touch-icon.png"),
        "6203": .imageURL("https://icons.sollahiro.com/company-icons/6203.png"), // R2 CDN Howa wordmark white 512 // pragma: allowlist secret
        "6278": .imageURL("https://www.uniontool.co.jp/assets/img/apple-touch-icon.png"),
        "6706": .imageURL(
            "https://denkikogyo.co.jp/wp-content/uploads/2022/09/cropped-favicon-180x180.png"),
        "6797": .imageURL(
            "https://www.nagoya-denki.co.jp/cms/wp-content/themes/nagoyadenki/icon.png"),
        "7265": .imageURL("https://icons.sollahiro.com/company-icons/7265.png"), // R2 CDN left mark crop 512 // pragma: allowlist secret
        "7266": .imageURL(
            "https://www.imasen.co.jp/wp-content/themes/imasen/img/common/apple-touch-icon.png"),
        "7443": .imageURL(
            "https://yokohamagyorui.co.jp/wp-content/uploads/2026/04/cropped-cropped-favicon-150x150-1-180x180.png"),
        "8225": .imageURL("https://kk-takachiho.jp/files/favicon/apple-touch-icon.png"),
        "8595": .imageURL("https://www.jafco.co.jp/apple-touch-icon.png"),
        "9245": .imageURL(
            "https://www.livero.co.jp/corporate/corp_assets/apple-touch-icon.png"),
        "9313": .imageURL("https://www.maru8.co.jp/apple-touch-icon-144-precomposed.png"),
        "9930": .imageURL(
            "https://www.kitazawasangyo.co.jp/image/common/apple-touch-icon.png"),
        "9445": .imageURL(
            "https://www.collabo-one.jp/wp-content/themes/collaboone/images/common/webclip.png"),
        "1992": .imageURL("https://www.kandt.co.jp/favicon.ico"),
        "2435": .imageURL("https://www.cedar-group.co.jp/media/images/common/apple-touch-icon.png"),
        "2776": .imageURL("https://www.shintohd.co.jp/wp-content/uploads/fbrfg/apple-touch-icon.png"),
        "2917": .imageURL(
            "https://ohmoriya-inc.co.jp/wp-content/uploads/2024/06/cropped-logo512-180x180.png"),
        "3021": .imageURL("https://www.prins.co.jp/favicon.ico"),
        "3063": .imageURL("https://www.jgroup.jp/wp/wp-content/uploads/cropped-favicon-180x180.png"),
        "3140": .imageURL("https://bruno-inc.com/apple-touch-icon.png"),
        "3323": .imageURL("https://www.recomm.co.jp/apple-touch-icon.png"),
        "3399": .imageURL("https://www.yamaokaya.com/images/apple-touch-icon.png"),
        "3421": .imageURL("https://www.inaba-ss.co.jp/assets/favicon/apple-touch-icon.png"),
        "3439": .imageURL("https://www.mitsuchi.co.jp/wp-content/themes/mituchi/img/icons/touch.png"),
        "3441": .imageURL("https://www.sanno.co.jp/assets/images/favicon.png"),
        "3913": .imageURL("https://www.greenbee.co.jp/apple-touch-icon.png"),
        "3948": .imageURL("https://hikaribf.co.jp/wordpress/wp-content/themes/hbf/img/favicon.png"),
        "4094": .imageURL("https://www.nihonkagakusangyo.co.jp/apple-touch-icon.png"),
        "4345": .imageURL("https://www.cts-h.co.jp/apple-touch-icon.png"),
        "4645": .imageURL(
            "https://ir.ichishin.co.jp/wp/wp-content/uploads/2025/07/cropped-favicon-180x180.png"),
        "4684": .imageURL("https://www.obic.co.jp/app-files/img/symbol/apple-touch-icon.png"),
        "4762": .imageURL("https://www.xnet.co.jp/apple-touch-icon.png"),
        "4772": .imageURL("https://smej.co.jp/apple-touch-icon-precomposed.png"),
        "5284": .imageURL("https://www.yamau-holdings.co.jp/img/apple-touch-icon.png"),
        "6050": .imageURL("https://www.e-guardian.co.jp/resources/img/ogp2.png"),
        "6076": .imageURL("https://www.az-hotels.co.jp/apple-touch-icon.png"),
        "6091": .imageURL("https://www.wescohd.co.jp/wp-content/uploads/2023/10/favicon.png"),
        "6291": .imageURL("https://www.airtech.co.jp/assets/img/common/apple-touch-icon.png"),
        "6298": .imageURL("https://www.yac.co.jp/resources/apple-touch-icon.png"),
        "6342": .imageURL(
            "https://www.taihei-ss.co.jp/wp/wp-content/uploads/2024/07/cropped-taihei_favicom_240723-180x180.png"),
        "6360": .imageURL("https://www.tam-tokyo.co.jp/apple-touch-icon.png"),
        "6400": .imageURL(
            "https://www.fujiseiki.com/wp-content/themes/fujiseiki2025/assets/apple-touch-icon.png"),
        "6469": .imageURL("https://www.hsk.co.jp/resources/apple-touch-icon.png"),
        "6538": .imageURL("https://disruptors.co.jp/apple-touch-icon.png"),
        "7477": .imageURL("https://muraki.jp/mu-db103/wp-content/uploads/2024/04/cropped-muraki-180x180.gif"),
        "7819": .imageURL("https://www.shobido-corp.co.jp/assets/img/common/logo@144.png"),
        "7849": .imageURL("https://starts-pub.jp/wp-content/uploads/2021/10/cropped-fabicon-180x180.png"),
        "7872": .imageURL(
            "https://www.estelle.co.jp/wp_manager/wp-content/uploads/2023/11/cropped-estelle-1-180x180.png"),
        "7878": .imageURL("https://www.kohsai-qq.co.jp/assets/image/common/icon_180x180.png"),
        "7887": .imageURL("https://www.nankaiplywood.co.jp/image/common/favicon.ico"),
        "7908": .imageURL("https://www.kimoto.co.jp/application/files/3117/4704/5415/sp_icon.png"),
        "8013": .imageURL(
            "https://www.naigai.co.jp/core_sys/images/others/favicon/apple-touch-icon-180x180.png"),
        "8254": .imageURL("https://p3.ssl-cdn.jp/var/data/u/c9/43e4ad62220/img/webclip.png"),
        "8927": .imageURL(
            "https://meiho-est.com/meiho-wp/wp-content/themes/meiho-est/assets/img/common/app_icon.png"),
        "8944": .imageURL("https://www.lbca.co.jp/img/common/apple-touch-icon.png"),
        "9034": .imageURL("https://www.nanso.co.jp/apple-touch-icon.png"),
        "9367": .imageURL(
            "https://www.daito-koun.co.jp/cms/wp-content/uploads/2025/08/cropped-favicon-180x180.png"),
        "9610": .imageURL("https://japan.wilsonlearning.com/apple-touch-icon.png"),
        "9643": .imageURL("https://www.nakanihonkogyo.co.jp/img/icon/apple-touch-icon.png"),
        "9679": .imageURL("https://www.horai-kk.co.jp/assets/img/common/apple-touch-icon-precomposed.png"),
        "9778": .imageURL("https://www.subaru-net.com/wp-content/themes/subaru-net/images/apple-touch-icon.png"),
        "9820": .imageURL("https://www.mt-genex.co.jp/assets/images/common/apple-touch-icon.png"),
        "1788": .imageURL(
            "https://www.santo.co.jp/app/wp-content/uploads/2025/06/cropped-favicon-192x192.png"),
        "2286": .imageURL("https://www.hayashikane.co.jp/_assets/img/common/ogp.png"),
        "3901": .imageURL("https://www.marklines.com/apple-touch-icon.png"),
        // 2026-10-28 weekly: 公告行の URL が colspan 後続セルにあり extractor が空セルで落とす欠行。
        // 公式 256 PNG（apple-touch 180 と同マーク）。差し替えはマップしない。
        "2778": .imageURL("https://palemo.co.jp/wp-content/uploads/2026/08/favicon256.png"),
        "1333": .imageURL("https://www.umios.com/favicon/favicon_192.png"),
        "1444": .imageURL("https://reform-nisso.co.jp/favicons/apple-touch-icon-144x144.png"),
        "1518": .imageURL(
            "https://www.mitsui-matsushima.co.jp/wp/wp-content/themes/mitsui-matsushima_2024/assets/images/apple-touch-icon.png"),
        "1723": .imageURL("https://www.nihondengi.co.jp/apple-touch-icon.png"),
        "1928": .imageURL("https://www.sekisuihouse.co.jp/library/img/touch-icon.png"),
        "1963": .imageURL("https://www.jgc.com/jp/common/img/apple-touch-icon.png"),
        "2282": .imageURL("https://www.nipponham.co.jp/apple-touch-icon.png"),
        "2351": .imageURL("https://www.asj.ad.jp/apple-touch-icon-180x180.png"),
        "2489": .imageURL(
            "https://adways.net/wp-content/uploads/cropped-apple-touch-icon-1-192x192.png"),
        "2585": .imageURL("https://www.ld-company.com/images/miscs/ldc_favicon_144.png"),
        "2702": .imageURL("https://www.mcd-holdings.co.jp/apple-touch-icon.png"),
        "2737": .imageURL("https://www.tomendevices.co.jp/apple-touch-icon.png"),
        "2798": .imageURL("https://www.ystable.co.jp/apple-touch-icon.png"),
        "3093": .imageURL(
            "https://www.treasurefactory.co.jp/img/iconified/apple-touch-icon-144x144.png"),
        "3103": .imageURL("https://www.unitika.co.jp/apple-touch-icon.png"),
        "3317": .imageURL("https://www.fgarden.co.jp/common/webclip.png"),
        "3333": .imageURL("https://www.cb-asahi.co.jp/apple-touch-icon.png"),
        "3361": .imageURL("https://www.toell.co.jp/touch-icon.png"),
        "3447": .imageURL("https://ir.shinwa-jp.com/resources/sw_img/favicon.ico"),
        "3461": .imageURL("https://www.palma.jp/assets/img/apple-touch-icon.png"),
        "3863": .imageURL("https://www.nipponpapergroup.com/assets/images/apple-touch-icon.png"),
        "3896": .imageURL("https://www.awapaper.co.jp/common/img/apple-touch-icon.png"),
        "3903": .imageURL("https://gu3.co.jp/assets/img/gumi_favicon_144.ico"),
        "3907": .imageURL(
            "https://www.siliconstudio.co.jp/wp-content/themes/custom/favicon/apple-touch-icon.png"),
        "3958": .imageURL("https://www.sasatoku.co.jp/img/apple-touch-icon.png"),
        "3964": .imageURL("https://ir.aucnet.co.jp/resources/apple-touch-icon.png"),
        "3976": .imageURL("https://www.shanon.co.jp/assets/img/apple-touch-icon.png"),
        "3983": .imageURL("https://www.oro.com/ja/img/share/apple-touch-icon.png"),
        "4004": .imageURL(
            "https://www.resonac.com/themes/resonac/common/img/shared/apple-touch-icon.png"),
        "4027": .imageURL("https://www.tayca.co.jp/apple-touch-icon.png"),
        "4041": .imageURL("https://www.nippon-soda.co.jp/asset/image/apple-touch-icon.png"),
        "4114": .imageURL("https://www.shokubai.co.jp/ja/apple-touch-icon.png"),
        "418A": .imageURL("https://uridoki.co.jp/wp-content/uploads/2024/03/favicon.png"),
        "4193": .imageURL("https://www.fabrica-hd.co.jp/application/themes/holdings/favicon.png"),
        "4202": .imageURL("https://www.daicel.com/apple-touch-icon.png"),
        "4218": .imageURL("https://www.nichiban.co.jp/apple-touch-icon.png"),
        "4249": .imageURL("https://www.moriroku.co.jp/apple-touch-icon.png"),
        "4287": .imageURL("https://www.justweb.co.jp/apple-touch-icon.png"),
        "4393": .imageURL("https://boi.jp/assets/static/apple-touch-icon.png"),
        "4397": .imageURL(
            "https://corp.teamspirit.com/wp-content/themes/tsp/_assets/images/common/apple-touch-icon.png"),
        "4428": .imageURL(
            "https://www.sinops.jp/cms/wp-content/themes/sinops/images/common/img_webclip_01.png"),
        "4444": .imageURL("https://www.e-infonet.jp/Portals/0/apple-touch-icon_02.png"),
        "4628": .imageURL(
            "https://www.sk-kaken.co.jp/wp/wp-content/themes/201801_SKkakenWP-2/lib/favicons/apple-touch-icon.png"),
        "4705": .imageURL("https://www.clip-cor.co.jp/apple-touch-icon.png"),
        "4848": .imageURL("https://www.fullcastholdings.co.jp/assets/img/common/favicon.png"),
        "4973": .imageURL("https://www.netjpc.com/Portals/0/apple-touch-icon.png"),
        "5233": .imageURL(
            "https://www.taiheiyo-cement.co.jp/assets/images/common/apple-touch-icon.png"),
        "5279": .imageURL("https://www.nihon-kogyo.co.jp/images/apple-touch-icon.jpg"),
        "5401": .imageURL("https://www.nipponsteel.com/app-files/img/symbol/apple-touch-icon.webp"),
        "5616": .imageURL(
            "https://ame-kaze-taiyo.jp/wp-content/themes/poke-m-corp/img/amekaze-apple-touch-icon-180x180-precomposed.png"),
        "5704": .imageURL("https://www.jmc-rp.co.jp/assets/images/misc/favicon_144.png"),
        "5834": .imageURL(
            "https://www.sbils.co.jp/wp-content/themes/SBI/assets/images/apple-touch-icon.png"),
        "5951": .imageURL("https://www.dainichi-net.co.jp/image/favicon/apple-touch-icon.png"),
        "5992": .imageURL("https://www.chkk.co.jp/common/img/apple-touch-icon.png"),
        "6074": .imageURL("https://www.jss-group.co.jp/com/img/com/apple-touch-icon-180x180.png"),
        "6143": .imageURL("https://www.sodick.co.jp/apple-touch-icon.png"),
        "6145": .imageURL(
            "https://nittoku.co.jp/wp_201912/wp-content/themes/nittoku/assets/images/common/apple-touch-icon.png"),
        "6265": .imageURL("https://www.convum.co.jp/apple-touch-icon.png"),
        "6284": .imageURL("https://www.nisseiasb.co.jp/apple-touch-icon.png"),
        "6310": .imageURL(
            "https://www.iseki.co.jp/cms/wp-content/themes/iseki_corporate_v2/assets/img/apple-touch-icon.png"),
        "6436": .imageURL("https://www.amano.co.jp/assets/img/common/apple-touch-icon.png"),
        "6532": .imageURL(
            "https://www.baycurrent.co.jp/wp-content/themes/baycurrent-template-v3/assets/img/common/apple-touch-icon.png"),
        "6561": .imageURL("https://hanatourjapan.jp/images/favicon.png"),
        "6654": .imageURL("https://www.fujidk.co.jp/common/img/apple-touch-icon-precomposed.png"),
        "6866": .imageURL("https://www.hioki.com/themes/hioki/common/images/apple-touch-icon.png"),
        "6870": .imageURL("https://www.fenwal.co.jp/wp/wp-content/uploads/2021/06/favicon-1.png"),
        "7059": .imageURL("https://www.copro-h.co.jp/img/apple-touch-icon.png"),
        "7073": .imageURL(
            "https://www.jaic-g.com/wp-jaic/wp-content/themes/wp-theme/assets/images/meta/apple-touch-icon.png"),
        "7184": .imageURL("https://www.first-bank.co.jp/common_v3/images/favicon.ico"),
        "7256": .imageURL("https://www.kasai.co.jp/apple-touch-icon.png"),
        "7353": .imageURL("https://www.kiyo-learning.com/apple-touch-icon-152x152.png"),
        "7701": .imageURL("https://www.shimadzu.co.jp/apple-touch-icon.png"),
        "7723": .imageURL("https://www.aichitokei.co.jp/apple-touch-icon.png"),
        "7811": .imageURL(
            "https://www.npacks.co.jp/wpress/wp-content/themes/nakamoto/assets/img/common/apple-touch-icon.png"),
        "7966": .imageURL("https://www.lintec.co.jp/common/images/symbol/apple-touch-icon.png"),
        "8091": .imageURL("https://www.nichimo.co.jp/common/img/apple-touch-icon.png"),
        "8185": .imageURL("https://www.chiyodagrp.co.jp/apple-touch-icon.png"),
        "8273": .imageURL("https://www.izumi.co.jp/apple-touch-icon-precomposed.png"),
        "8276": .imageURL("https://www.heiwado.jp/apple-touch-icon.png"),
        "8349": .imageURL("https://www.tohoku-bank.co.jp/assets/images/webclip.png"),
        "8591": .imageURL("https://www.orix.co.jp/ORIX_favicon_152x152.png"),
        "8609": .imageURL("https://www.okasan.jp/apple-touch-icon-precomposed.png"),
        "8622": .imageURL("https://www.mito.co.jp/apple-touch-icon.png"),
        "8624": .imageURL(
            "https://file.ichiyoshi.co.jp/ichiyoshi/images/apple-touch-icon-180x180-precomposed.png?v=20261020110420"),
        "8830": .imageURL("https://www.sumitomo-rd.co.jp/apple-touch-icon.png"),
        "8860": .imageURL("https://www.fuji-jutaku.co.jp/_assets/img/common/apple-touch-icon.png"),
        "9087": .imageURL(
            "https://www.takase.co.jp/library/6329656258959dc1460fd449/favicon/6374674c79d77142bda6f594/webclip.png?v=1670551085704"),
        "9142": .imageURL("https://www.jrkyushu.co.jp/apple-touch-icon.png"),
        "9249": .imageURL(
            "https://www.jp-eco.co.jp/gnq78kmx-wp/wp-content/uploads/2023/10/cropped-apple-touch-icon-192x192.png"),
        "9303": .imageURL("https://www.sumitomo-soko.co.jp/img/apple-touch-icon.png"),
        "9424": .imageURL("https://www.j-com.co.jp/apple-touch-icon.png"),
        "9471": .imageURL("https://www.bunkei.co.jp/apple-touch-icon.png"),
        "9504": .imageURL("https://www.energia.co.jp/apple-touch-icon.png"),
        "9536": .imageURL("https://hd.saibugas.co.jp/common_2020/apple-touch-icon.png"),
        "9627": .imageURL("https://www.ainj.co.jp/img/apple-touch-icon.png"),
        "9697": .imageURL("https://www.capcom.co.jp/index_img/favicon.ico"),
        "9743": .imageURL(
            "https://www.tanseisha.co.jp/wp-content/themes/www.tanseisha.co.jp/assets/img/apple-touch-icon.png"),
        "9867": .imageURL("https://www.solekia.com/apple-touch-icon.png"),
        "9983": .imageURL("https://www.fastretailing.com/favicon/apple-touch-icon.png"),
        "3167": .imageURL("https://icons.sollahiro.com/company-icons/3167.png"), // R2 CDN TOKAI T-mark 512 // pragma: allowlist secret
        "4678": .imageURL("https://icons.sollahiro.com/company-icons/4678.png"), // R2 CDN Shuei S-mark 512 // pragma: allowlist secret
        "8600": .imageURL("https://icons.sollahiro.com/company-icons/8600.png"), // R2 CDN Tomony wing 512 // pragma: allowlist secret
        // 2026-10-28 weekly replacements: same-origin 16/32px→公式 apple-touch / 正方形。
        // Visual GO は PR #573（251 公式 URL + 3600 マークのみ 180 CDN + 4450/5031 origin 不能 CDN）。
        "135A": .imageURL("https://vrain.co.jp/vrain/wp-content/uploads/2026/07/cropped-%E3%82%B9%E3%82%AF%E3%83%AA%E3%83%BC%E3%83%B3%E3%82%B7%E3%83%A7%E3%83%83%E3%83%88-2026-07-28-175624-180x180.png"),
        "1375": .imageURL("https://www.yukiguni-factory.co.jp/wp-content/uploads/2025/03/cropped-favicon-1-180x180.png"),
        "137A": .imageURL("https://cocolive.co.jp/newsite/wp-content/uploads/2023/03/cropped-favicon-180x180.jpg"),
        "1384": .imageURL("https://www.hokuryo.co.jp/wp-content/uploads/2019/12/cropped-%E4%BC%9A%E7%A4%BE%E3%83%AD%E3%82%B42704-180x180.png"),
        "147A": .imageURL("https://storage.googleapis.com/production-os-assets/assets/53948a70-ea2d-461c-a28c-0a44d53dea5f"),
        "150A": .imageURL("https://www.jsh-japan.jp/wp/wp-content/uploads/2020/04/cropped-logo-1-180x180.png"),
        "153A": .imageURL("https://cdn.getshifter.co/38a4d842fa3e5953fde43746f0194de650adcafc/uploads/2023/12/cropped-favicon-180x180.png"),
        "157A": .imageURL("https://greenmonster.co.jp/wp-content/themes/green-monster-theme/assets/img/icon/apple-touch-icon.png"),
        "160A": .imageURL("https://www.as-partners.co.jp/wp/wp-content/uploads/2021/10/cropped-Home_icon-180x180.png"),
        "168A": .imageURL("https://www.itamiarts.co.jp/wp-content/uploads/2023/11/cropped-header_logo-1-180x180.png"),
        "1783": .imageURL("https://fantasista-tokyo.jp/wp-content/themes/aghd/images/apple-touch-icon.png"),
        "1813": .imageURL("https://www.fudotetra.co.jp/wp-content/themes/fudoTetraTheme/assets/img/apple-touch-icon.png"),
        "1887": .imageURL("https://www.n-kokudo.co.jp/common/img/icon/apple-touch-icon.png"),
        "192A": .imageURL("https://www.integroup.jp/_assets/_common/img/favico_apple_180x180.png"),
        "1975": .imageURL("https://www.asahikogyosha.co.jp/wp-content/themes/asahikogyosha_themes_v1/assets/img/apple-touch-icon.png"),
        "2158": .imageURL("https://www.fronteo.com/hubfs/raw_assets/public/p-chan-fronteo/assets/images/common/FRONTEO_logo_TW.png"),
        "2160": .imageURL("https://www.gnipharma.com/wp/wp-content/uploads/2025/07/cropped-cropped-GNI_favicon-180x180-1-180x180.png"),
        "2163": .imageURL("https://www.artner.co.jp/wp-content/uploads/2025/06/cropped-favicon-1-1-180x180.png"),
        "2216": .imageURL("https://www.kanro.co.jp/apple-icon.png"),
        "2222": .imageURL("https://www.kotobukispirits.co.jp/resources/apple-touch-icon.png"),
        "2293": .imageURL("https://www.takizawaham.co.jp/icon/icon.png"),
        "2301": .imageURL("https://company.gakujo.ne.jp/wp-content/themes/gakujo/_assets/images/_etc/custom-icon.png"),
        "2467": .imageURL("https://vlcsecurity.com/wp-content/uploads/2025/09/cropped-logo_02_basic-180x180.png"),
        "247A": .imageURL("https://ai-robotics.co.jp/common/img/apple-icon.png"),
        "2488": .imageURL("https://www.jtp.co.jp/assets/themes/cinra/static/apple-touch-icon.png"),
        "2493": .imageURL("https://www.e-supportlink.com/wp-content/uploads/2022/04/cropped-fabicon-180x180.png"),
        "254A": .imageURL("https://aifcg.jp/wp-content/themes/AI%20FUSION%20CAPITAL%20GROUP_0317/images/touch_icon.jpg"),
        "2593": .imageURL("https://www.itoen.co.jp/wp-content/themes/itoen.co.jp/assets/static/img/common/apple-icon-152x152.png"),
        "263A": .imageURL("https://www.digitalcube.jp/wp-content/uploads/2019/07/cropped-digitalcube-site-icon-white-3-180x180.png"),
        "2656": .imageURL("https://corp.vector.co.jp/wp-content/uploads/2023/03/cropped-vector_favicon-180x180.png"),
        "2735": .imageURL("https://www.watts-jp.com/wp-content/uploads/2025/08/cropped-%E3%81%B5%E3%81%81%E3%81%B30826%E5%AE%9A-2-01-180x180.png"),
        "2750": .imageURL("https://www.ishimitsu.co.jp/wp-content/uploads/2019/06/cropped-logo_mark-1-180x180.png"),
        "2802": .imageURL("https://icons.sollahiro.com/company-icons/2802.png"), // R2 CDN Aj mark 512 // pragma: allowlist secret
        "2813": .imageURL("https://www.wakoushokuhin.co.jp/wp01/wp-content/uploads/2019/02/cropped-logo-180x180.png"),
        "2871": .imageURL("https://icons.sollahiro.com/company-icons/2871.png"), // R2 CDN N mark 512 // pragma: allowlist secret
        "2884": .imageURL("https://www.y-food-h.com/wp-content/uploads/2021/11/cropped-apple-touch-icon-180x180.png"),
        "2901": .imageURL("https://ishigakifoods.co.jp/wp-content/uploads/2026/03/cropped-ishigaki-favicon-512-180x180.png"),
        "2926": .imageURL("https://shinozakiya.com/wp-content/uploads/2020/05/cropped-icon-180x180.jpg"),
        "2981": .imageURL("https://landix.jp/resource/img/common/ico/apple-touch-icon.png"),
        "2984": .imageURL("https://www.yueg.co.jp/images/common/apple-touch-icon.png"),
        "303A": .imageURL("https://storage.googleapis.com/production-os-assets/assets/b5d7b1be-c7f5-4c40-b468-2ee58f66f8b0"),
        "3045": .imageURL("https://kawasaki-corp.co.jp/wp-content/uploads/2024/09/cropped-fav-180x180.jpg"),
        "3069": .imageURL("https://j-fla.com/favicon/apple-touch-icon.png"),
        "3139": .imageURL("https://www.lactojapan.com/resources/apple-touch-icon.png"),
        "319A": .imageURL("https://ngt-g.com/wp-content/uploads/2024/12/cropped-%E3%83%95%E3%82%A1%E3%83%93%E3%82%B3%E3%83%B3-180x180.png"),
        "3238": .imageURL("https://central-gd.co.jp/wp-content/uploads/2022/10/cropped-favicon-180x180.png"),
        "3242": .imageURL("https://www.urbanet.jp/assets/img/apple-touch-icon.png"),
        "3245": .imageURL("https://www.dear-life.co.jp/assets/img/apple-touch-icon.png"),
        "324A": .imageURL("https://www.booking-resort.jp/wp-content/uploads/2022/01/cropped-rglogoimg-180x180.jpg"),
        "3252": .imageURL("https://www.jinushi-jp.com/assets/favicons/apple-touch-icon.png"),
        "325A": .imageURL("https://corp.tential.jp/wp-content/uploads/2024/01/cropped-%E3%83%95%E3%82%A1%E3%83%93%E3%82%B3%E3%83%B3_144_144-180x180.png"),
        "3276": .imageURL("https://static.wixstatic.com/media/3e7db2_92eb3b00a90c439cb2362702cad7692f~mv2.png/v1/fill/w_180,h_180,lg_1,usm_0.66_1.00_0.01/3e7db2_92eb3b00a90c439cb2362702cad7692f~mv2.png"),
        "3300": .imageURL("https://am-bition.jp/wp-content/uploads/2021/09/cropped-apple-touch-icon-1-180x180.png"),
        "3329": .imageURL("https://www.towafood-net.co.jp/wp-content/themes/touwa/img/apple-touch-icon.png"),
        "3346": .imageURL("https://hirotaghd.com/wp/wp-content/uploads/2023/09/cropped-favicon-180x180.png"),
        "3387": .imageURL("https://www.createrestaurants.com/wp-content/uploads/cropped-favicon_512x512-180x180.png"),
        "340A": .imageURL("https://www.zig-zag.co.jp/wp-content/uploads/2026/07/cropped-logo_whi-180x180.png"),
        "3415": .imageURL("https://tokyobase.co.jp/assets/themes/tokyo-base/assets/static/favicon/apple-touch-icon.png"),
        "3433": .imageURL("https://www.tocalo.co.jp/resources/apple-touch-icon.png"),
        "3440": .imageURL("https://nissogroup.com/wp-content/uploads/2024/10/cropped-nisso_favicon-180x180.png"),
        "3496": .imageURL("https://azoom.jp/assets/img/webclip.png"),
        "3521": .imageURL("https://thermae-yu-hd.co.jp/wp-content/uploads/2025/09/cropped-favicon_logo-180x180.png"),
        "3559": .imageURL("https://www.p-ban.com/img/common/bookmark_icon.png"),
        "3600": .imageURL("https://icons.sollahiro.com/company-icons/3600.png"), // R2 CDN Fujix circular mark 180 // pragma: allowlist secret
        "3622": .imageURL("https://www.netyear.net/common/img/favicon.png"),
        "3698": .imageURL("https://www.cri-mw.co.jp/wp/wp-content/themes/cri-mw/assets/images/common/app-icon.png"),
        "369A": .imageURL("https://a-tie.co.jp/wp/wp-content/uploads/2025/08/cropped-favicon-1-180x180.png"),
        "3723": .imageURL("https://icons.sollahiro.com/company-icons/3723.png"), // R2 CDN Falcom F-mark 512 // pragma: allowlist secret
        "3727": .imageURL("https://www.aplix.co.jp/assets/images/favicon/apple-touch-icon.png"),
        "3773": .imageURL("https://www.advanced-media.co.jp/wp-content/themes/advanced-media-html/dist/assets/images/web-clipicon.png"),
        "3775": .imageURL("https://www.gaiax.co.jp/wp-content/uploads/2021/03/cropped-gaiax-favicon-1-180x180.png"),
        "3841": .imageURL("https://www.jedat.co.jp/wp-content/uploads/2022/05/cropped-super-big-icon-180x180.jpg"),
        "3853": .imageURL("https://en.asteria.com/wp-content/uploads/2022/06/android-touch-icon.png"),
        "3865": .imageURL("https://www.hokuetsucorp.com/img/apple-touch-icon.png"),
        "3912": .imageURL("https://www.mobilefactory.jp/wp-content/uploads/2018/06/cropped-dc23e8eb0e0ed23360b7ff4e78ad8f1c-180x180.png"),
        "3920": .imageURL("https://www.ibc21.co.jp/wp-content/uploads/2022/10/cropped-IBC_logomark_%E9%9D%9E%E9%80%8F%E9%81%8E-180x180.png"),
        "3936": .imageURL("https://www.globalway.co.jp/wp-content/themes/globalway/img/icon/icon-logo-180x180.png"),
        "3985": .imageURL("https://temona.co.jp/wp-content/plugins/all-in-one-seo-pack/images/default-user-image.png"),
        "4046": .imageURL("https://www.osaka-soda.co.jp/resources/apple-touch-icon.png"),
        "4064": .imageURL("https://www.carbide.co.jp/cms/wp-content/uploads/2021/08/cropped-1_1_rgb-180x180.png"),
        "4075": .imageURL("https://icons.sollahiro.com/company-icons/4075.png"), // R2 CDN brains lockup 512 // pragma: allowlist secret
        "410A": .imageURL("https://www.gmo-c.jp/wp-content/uploads/2025/09/cropped-favicon_144x144-180x180.png"),
        "4112": .imageURL("https://www.hodogaya.co.jp/wp/wp-content/uploads/2022/05/cropped-cropped-favicon-180x180.png"),
        "4196": .imageURL("https://corp.neo-m.jp/hubfs/%E3%83%8D%E3%82%AA%E3%83%AD%E3%82%B4%20-%20%E5%86%86%E3%81%AE%E8%BA%AB.png"),
        "4237": .imageURL("https://www.fujipream.co.jp/wp/wp-content/uploads/2023/10/cropped-favicon-180x180.png"),
        "4238": .imageURL(
            "https://www.miraial.co.jp/wp-content/uploads/2020/08/cropped-favicon-180x180.png"),
        // Pronexus 公告 origin マップは残す。ingest は 180 apple-touch。
        "4243": .imageURL("https://nix.co.jp/cms/wp-content/themes/nix/assets/img/common/apple-touch-icon.png"),
        "4284": .imageURL("https://www.solxyz.co.jp/wp-content/uploads/2021/02/cropped-favicon-180x180.png"),
        "428A": .imageURL("https://www.cypress-holdings.co.jp/wp-content/uploads/2025/08/cropped-favicon-180x180.png"),
        "4370": .imageURL("https://mobilus.co.jp/wp-content/uploads/2021/02/cropped-fabicon-180x180.png"),
        "4409": .imageURL("https://toho-chem.co.jp/db/wp-content/themes/bone/library/images/apple-touch-icon.png"),
        "4414": .imageURL("https://www.flect.co.jp/wp-content/uploads/2023/05/cropped-favicon-180x180.png"),
        "4439": .imageURL("https://www.toumei.co.jp/image/ogp.jpg"),
        "4441": .imageURL("https://tobila.com/wp/wp-content/uploads/2026/08/443e3dc8443e083f2d72c5267a94a1b6-320x320.png"),
        "4450": .imageURL("https://icons.sollahiro.com/company-icons/4450.png"), // R2 CDN Power Solutions apple-touch (origin 403) // pragma: allowlist secret
        "4465": .imageURL("https://www.niitaka.co.jp/images/apple-touch-icon.png"),
        "4479": .imageURL("https://www.makuake.co.jp/img/apple-touch-icon.png"),
        "4544": .imageURL("https://www.hugp.com/resources/img/common/favicon/apple-touch-icon.png"),
        "4568": .imageURL("https://www.daiichisankyo.co.jp/Portals/0/DS_Apple_Touch_Icon_RGB_180x180px_200507.png"),
        "4571": .imageURL("https://www.nano-hd.com/nanocms/wp-content/themes/original_20260322/img/common/logo.png"),
        "4633": .imageURL("https://www.inx.co.jp/common/favicon/apple-touch-icon.png"),
        "4642": .imageURL("https://www.oec-solution.co.jp/apple-touch-icon.png"),
        "4644": .imageURL("https://www.imagineer.co.jp/images/basic.png"),
        "4664": .imageURL("https://www.trsc.co.jp/wrscp/wp-content/uploads/2024/11/cropped-favicon-180x180.png"),
        "4685": .imageURL("https://www.ryoyu.co.jp/assets/img/common/site-icon-192.png"),
        "471A": .imageURL("https://nsg-inc.co.jp/wp-content/uploads/2024/12/cropped-favicon-180x180.png"),
        "4735": .imageURL("https://group.kyoshin.co.jp/wp-content/uploads/sites/2/2024/05/cropped-favicon-180x180.png"),
        "4746": .imageURL("https://www.toukei.co.jp/wp-content/uploads/2025/02/cropped-tcc-favicon-180x180.png"),
        "4751": .imageURL("https://d1kdu080g8vme4.cloudfront.net/files/user/img/common/ogp/apple-touch-icon.png?version=1506600472"),
        "4760": .imageURL("https://www.popalpha.co.jp/cms/wp-content/uploads/2019/01/cropped-logo_alpha-1-180x180.png"),
        "4777": .imageURL("https://cdn.prod.website-files.com/65b09eef31dcbaedbc68ce12/65f7d8867d923d7d2a1fc7ec_webclip.png"),
        "4801": .imageURL("https://www.central.co.jp/apple-touch-icon.png"),
        "4809": .imageURL("https://paraca.co.jp/mg/wp-content/uploads/2025/10/cropped-cropped-siteicon-180x180.jpg"),
        "4826": .imageURL("https://www.cij.co.jp/wp-content/uploads/cropped-favicon-180x180.png"),
        "4833": .imageURL("https://def-consulting.co.jp/wp-content/themes/def-consulting/assets/favicon/apple-touch-icon.png"),
        "4883": .imageURL("https://modalistx.com/wp-content/uploads/2025/03/cropped-modalis-favicon-180x180.png"),
        "4932": .imageURL("https://www.almado.co.jp/wordpress/wp-content/themes/almado/favicon/apple-touch-icon.png"),
        "4936": .imageURL("https://axxzia.co.jp/assets/img/apple-touch-icon.png"),
        "5031": .imageURL("https://icons.sollahiro.com/company-icons/5031.png"), // R2 CDN moi.st apple-touch (origin TLS fail) // pragma: allowlist secret
        "5035": .imageURL("https://cdn.prod.website-files.com/60ed5df2530e651a48bcd5cd/61f3a0dfd0062b2caf03a667_housei_webclip.png"),
        "5132": .imageURL("https://cdn.clipkit.co/tenants/942/sites/touch_icons/000/000/001/square/e109fbe8-0953-49b8-a728-f56f3dcb25b3.png?1604852566"),
        "5136": .imageURL("https://tripla.io/wp-content/uploads/2023/05/cropped-icon-180x180.png"),
        "5138": .imageURL("https://www.rebase.co.jp/images/webclip.png"),
        "520A": .imageURL("https://www.j-pharma.com/assets/img/cropped-favicon-180x180.png"),
        "5262": .imageURL("https://www.nipponhume.co.jp/wp/wp-content/uploads/2023/04/cropped-logo_2-180x180.png"),
        "5310": .imageURL("https://www.toyotanso.co.jp/img/common/apple-touch-icon.png"),
        "5542": .imageURL("https://www.shst.co.jp/wp-content/uploads/2025/01/cropped-favicon-180x180.jpg"),
        "556A": .imageURL("https://corp.inuneko-seikatsu.co.jp/inunkeko_cms/wp-content/uploads/2025/09/cropped-logo%E9%80%8F-3-180x180.png"),
        "5571": .imageURL("https://www.excite-holdings.co.jp/wp-content/uploads/2023/02/cropped-cropped-lep-180x180.png"),
        "5588": .imageURL("https://www.fastaccounting.jp/wp-content/uploads/2020/08/cropped-favicon_white-180x180.png"),
        "5612": .imageURL("https://www.nichu.co.jp/wp-content/themes/nck/assets/images/apple-touch-icon.png"),
        "5619": .imageURL("https://www.mrso.co.jp/images/common/cropped-icon-180x180.png"),
        "5631": .imageURL("https://www.jsw.co.jp:443/common/favicon/apple-touch-icon.png"),
        "5699": .imageURL("https://www.ibokin.co.jp/wordpress/wp-content/uploads/2026/08/cropped-apple-touch-icon-180x180.png"),
        "5753": .imageURL("https://www.nippon-shindo.co.jp/wp/wp-content/uploads/2019/01/cropped-icon-180x180.png"),
        "5816": .imageURL("https://www.onamba.co.jp/wp/wp-content/uploads/2022/05/cropped-favicon-180x180.png"),
        "5933": .imageURL("https://alinco.co.jp/apple-icon.png?b531c56825ffda31"),
        "5952": .imageURL("https://www.amatei.co.jp/wp/wp-content/uploads/2024/06/cropped-d4ea1e65fa2516d74f263f43724a4a6f-180x180.png"),
        "6031": .imageURL("https://zeta.inc/wp-content/uploads/2025/07/cropped-4431d9c0b317ff9fef936d07301ff5e5-180x180.png"),
        "6061": .imageURL("https://uni-green.co.jp/wp-content/uploads/2022/12/cropped-cropped-favicon-180x180.png"),
        "6088": .imageURL("https://www.sigmaxyz.com/resources/apple-touch-icon.png"),
        "6099": .imageURL("https://www.kkelan.com/wp-content/uploads/2022/06/cropped-favicon-1-180x180.png"),
        "6155": .imageURL("https://www.takamaz.co.jp/wp/wp-content/themes/takamaz.co.jp/assets/images/webclip.jpg"),
        "6171": .imageURL("https://www.dksiken.co.jp/wp-content/uploads/2023/01/cropped-DK-logo-512-180x180.png"),
        "6186": .imageURL("https://www.ichikura.jp/_wsys/wp-content/themes/ichikura_corp/assets/images/common/favicon/apple-touch-icon.png"),
        "6224": .imageURL("https://corp.jrcnet.co.jp/wp-content/uploads/2025/01/cropped-favicon-1-180x180.png"),
        "6228": .imageURL("https://www.globaljet.jp/wp-content/uploads/2023/03/cropped-favicon-180x180.png"),
        "6268": .imageURL("https://www.nabtesco.com/cms/wp-content/uploads/cropped-favicon-180x180.png"),
        "6289": .imageURL("https://www.giken.com/ja/wp-content/uploads/2017/09/cropped-favicon-180x180.png"),
        "6325": .imageURL("https://www.takakita-net.co.jp/favicon/apple-touch-icon.png"),
        "6335": .imageURL("https://www.tks-net.co.jp/corporate/wp-content/uploads/2022/07/cropped-favicon-180x180.png"),
        "6346": .imageURL("https://www.kikukawa.co.jp/cms/wp-content/uploads/2024/03/cropped-favicon-1-180x180.jpg"),
        "6357": .imageURL("https://www.sansei-technologies.com/wp-content/uploads/2025/06/cropped-favicon-180x180.png"),
        "6367": .imageURL("https://www.daikin.co.jp/-/media/640E2D69C822493AB9DFC6EC0228A0CB.ashx"),
        "6381": .imageURL("https://www.anestiwata-corp.com/sites/default/files/assets/images/ogpimg.png"),
        "6395": .imageURL("https://www.tadano.co.jp/wp-content/themes/tadano/assets/dist/images/favicons/apple-touch-icon.png"),
        "6418": .imageURL("https://www.jcm-hq.co.jp/resources/apple-touch-icon.png"),
        "6464": .imageURL("https://tsubaki-nakashima.com/wp-content/uploads/2025/12/cropped-favicon-180x180.png"),
        "6479": .imageURL("https://www.minebeamitsumi.com/apple-touch-icon.png"),
        "6522": .imageURL("https://www.asx.co.jp/wp-content/uploads/2020/12/cropped-as-1-180x180.png"),
        "6554": .imageURL("https://www.sus-g.co.jp/suswp/wp-content/uploads/2025/07/cropped-favicon-180x180.png"),
        "6557": .imageURL("https://aiai-group.co.jp/cms/wp-content/uploads/2021/12/cropped-favicon-aiai-180x180.png"),
        "6651": .imageURL("https://www.nito.co.jp/assets/images/favicon/apple-touch-icon.png"),
        "6656": .imageURL("https://www.inspec21.com/apple-touch-icon.png"),
        "6662": .imageURL("https://www.ubiteq.co.jp/wp-content/uploads/2023/02/cropped-ubiteq_logo-180x180.png"),
        "6695": .imageURL("https://www.castrico.co.jp/cms2024/wp-content/themes/Castrico-A/favicons/apple-touch-icon.png"),
        "6741": .imageURL("https://www.signal.co.jp/wordpress/wp-content/uploads/2021/07/cropped-favicon-270x270.png"),
        "6803": .imageURL("https://www.teac.co.jp/assets/favicon/teac-group/apple-touch-icon-152x152.png?v=eEExBk2Aa4"),
        "6837": .imageURL("https://www.kyosha.co.jp/apple-touch-icon.png"),
        "6841": .imageURL("https://www.yokogawa.co.jp/img/ipad3_retina_144x144.png"),
        "6912": .imageURL("https://kikusui-holdings.co.jp/wp-content/uploads/2022/12/cropped-khd-favicon-180x180.png"),
        "6964": .imageURL("https://www.sko.co.jp/wp-content/uploads/2019/07/cropped-sko-logo-180x180.png"),
        "7012": .imageURL("https://www.khi.co.jp/common_new/img/favicon/apple-touch-icon-180x180.png"),
        "7021": .imageURL("https://www.nitchitsu.co.jp/wp-content/files_mf/cropped-favicon-180x180.png"),
        "7041": .imageURL("https://www.crgh.co.jp/icons/icon-192x192.png?v=636d1c8776796403cc1a97c1d194ca85"),
        "7046": .imageURL("https://www.tdse.jp/wp-content/uploads/2021/11/cropped-fav-180x180.png"),
        "7060": .imageURL("https://www.geechs.com/wp-content/uploads/2022/08/cropped-%E3%83%95%E3%82%A1%E3%83%93%E3%82%B3%E3%83%B3-180x180.png"),
        "7068": .imageURL("https://feedforcegroup.jp/wp-content/uploads/2021/09/cropped-favicon-152x152-1-180x180.jpg"),
        "7082": .imageURL("https://jmty.co.jp/wp-content/uploads/2017/11/jmty_logo-1.png"),
        "7083": .imageURL("https://ahc.co.jp/ahcwp/wp-content/uploads/2022/02/cropped-apple-icon-180x180-1-180x180.png"),
        "7089": .imageURL("https://cdn.prod.website-files.com/606ab0cd3013aa344c0e3cdf/60e7d58b9569a679d97cbb1c_favicon_big.png"),
        "7090": .imageURL("https://ligua.jp/wp-content/uploads/2022/08/cropped-favicon-180x180.png"),
        "7157": .imageURL("https://ir.lifenet-seimei.co.jp/resources/apple-touch-icon.png"),
        "7235": .imageURL("https://www.tokyo-radiator.co.jp/wordpress/wp-content/uploads/2024/03/cropped-siteicon-180x180.png"),
        "7241": .imageURL("https://futabasangyo.com/wordpress/wp-content/uploads/2026/03/cropped-icon-180x180.png"),
        "7254": .imageURL("https://www.uvc.co.jp/hubfs/01.page_image/module/apple-touch-icon.png"),
        "7279": .imageURL("https://www.hi-lex.co.jp/wp-content/uploads/2023/07/cropped-favicon-180x180.png"),
        "7291": .imageURL("https://www.n-plast.co.jp/wp-content/uploads/2022/06/cropped-logo-1-180x180.png"),
        "7294": .imageURL("https://www.yorozu-corp.co.jp/wp-content/themes/YOROZU%201.0.3/images/icon/apple-touch-icon-152x152.png"),
        "7318": .imageURL("https://www.serendip-c.com/wp/wp-content/uploads/2026/05/cropped-favicon-180x180.png"),
        "7320": .imageURL("https://solvvy.co.jp/wp-content/themes/solvvy/assets/images/favicon/apple-touch-icon-180x180.png"),
        "7361": .imageURL("https://hch-ja.co.jp/mg/wp-content/uploads/2022/11/cropped-siteicon-180x180.png"),
        "7367": .imageURL("https://www.celm.co.jp/wordpress/wp-content/uploads/2023/11/cropped-favicon-180x180.png"),
        "7426": .imageURL("https://www.yamadai.com/wp-content/themes/yamadai/common/img/favicon/apple-touch-icon.png"),
        "7510": .imageURL("https://www.takebishi.co.jp/static/icons/apple-touch-icon.png"),
        "7537": .imageURL("https://www.marubun.co.jp/apple-touch-icon.png"),
        "7567": .imageURL("https://sakae-denshi.com/wp-content/uploads/2020/10/cropped-%EF%BC%88%E6%A0%AA%EF%BC%89%E6%A0%84%E9%9B%BB%E5%AD%90%E3%83%AD%E3%82%B4-300x288-1-180x180.jpg"),
        "7585": .imageURL("https://kannanmaru.co.jp/wp-content/uploads/2023/06/cropped-%E3%88%B1%E3%81%8B%E3%82%93%E3%81%AA%E3%82%93%E4%B8%B8%E3%80%80%E3%82%A2%E3%82%A4%E3%82%B3%E3%83%B3-180x180.jpg"),
        "7606": .imageURL("https://www.united-arrows.co.jp/wp-content/themes/united-arrows/assets/config/apple-touch-icon.png"),
        "7608": .imageURL("https://www.sk-japan.co.jp/wp-content/uploads/2021/06/cropped-favicon-180x180.jpg"),
        "7678": .imageURL("https://www.asakuma.co.jp/images/top-asakuma.jpg"),
        "7683": .imageURL("https://www.wa-jp.com/wp2024/wp-content/uploads/2024/09/cropped-apple-touch-icon-1-180x180.png"),
        "7687": .imageURL("https://corp.micreed.co.jp/assets/img/favicon/apple-touch-icon.png"),
        "7689": .imageURL("https://www.copa.co.jp/wp-content/themes/copa-corp/assets/images/apple-touch-icon-precomposed.png"),
        "7790": .imageURL("https://barcos.jp/wp/wp-content/uploads/cropped-favicon_logo-180x180.png"),
        "7809": .imageURL("https://company.kotobukiya.co.jp/wp-content/uploads/2022/06/cropped-cropped-favicon-180x180.png"),
        "7821": .imageURL("https://www.maedakosen.jp/wp/wp-content/themes/mdk/images/logo.jpg"),
        "7831": .imageURL("https://www.wellco-corp.com/wp-content/uploads/2025/01/cropped-wellcoHD-icon-180x180.png"),
        "7841": .imageURL("https://endo-mfg.co.jp/apple-touch-icon.png"),
        "7850": .imageURL("https://www.shouken.co.jp/sp/wp-content/themes/shouken/uploads/images/cropped-apple-touch-icon-180x180.png"),
        "7856": .imageURL("https://www.hagihara.co.jp/cms/wp-content/uploads/27039d9f3f402c48e8fababb3e87ed9e-300x297.jpg"),
        "7871": .imageURL("https://www.fukuvi.co.jp/application/files/9115/3973/9928/apple-touch-icon.png"),
        "7874": .imageURL("https://www.lecinc.co.jp/wp-content/uploads/2021/02/cropped-favicons-180x180.png"),
        "7917": .imageURL("https://www.zacros.co.jp/wp-content/uploads/2024/09/cropped-newlogo_fav-180x180.png"),
        "7936": .imageURL("https://assets.asics.com/page_types/4043/files/corp_ogp_original.jpg?1560319228"),
        "7946": .imageURL("https://cdn.prod.website-files.com/65656bd9b9576a75a4eca3d5/65b07dfba478bf4894a81402_koyosya-webclip.png"),
        "7963": .imageURL("https://icons.sollahiro.com/company-icons/7963.png"), // R2 CDN Koken mark 512 // pragma: allowlist secret
        "7975": .imageURL("https://www.lihit-lab.com/wp-content/uploads/2021/10/cropped-favicon-180x180.jpg"),
        "7987": .imageURL("https://www.nakabayashi.co.jp/common/img/icon.png"),
        "8032": .imageURL("https://www.kamipa.co.jp/wp/wp-content/themes/jp-2017/touch-icon.png"),
        "8107": .imageURL("https://www.kimuratan.co.jp/corporate_cms/wp-content/uploads/2025/03/cropped-favicon-180x180.png"),
        "8129": .imageURL("https://www.tohohd.co.jp/apple-touch-icon.png"),
        "8200": .imageURL("https://www.ringerhut.co.jp/common_2017/img/apple-touch-icon.png"),
        "8218": .imageURL("https://www.komeri.bit.or.jp/img/favicon/152.png"),
        "8260": .imageURL("https://www.izutsuya.co.jp/touch_icon.png"),
        "8278": .imageURL("https://www.the-fuji.com/common_v14/apple-touch-icon.png"),
        "8537": .imageURL("https://www.taikobank.jp/undefined/favicons/apple-touch-icon-180x180.png"),
        "8550": .imageURL("https://www.tochigibank.co.jp/common/images/tochigi_ogp.jpg"),
        "8708": .imageURL("https://www.aizawa-group.jp/apple-touch-icon.png"),
        "8771": .imageURL("https://www.eguarantee.co.jp/wp-content/uploads/2023/03/cropped-favicon-180x180.png"),
        "8914": .imageURL("https://www.arealink.co.jp/apple-touch-icon.png"),
        "9008": .imageURL("https://icons.sollahiro.com/company-icons/9008.png"), // R2 CDN KEIO wordmark 512 // pragma: allowlist secret
        "9036": .imageURL("https://www.tohbu.co.jp/wp-content/themes/tbn_corpolate/assets/img/common/icon-favicon-180x180.png"),
        "9107": .imageURL("https://www.kline.co.jp/resources/apple-touch-icon.png"),
        "9110": .imageURL("https://www.nsuship.co.jp/resources/apple-touch-icon.png"),
        "9166": .imageURL("https://genda.jp/wp-content/uploads/2024/09/cropped-cropped-GENDA_favicon-150x150-1-180x180.png"),
        "9214": .imageURL("https://www.recovery-group.co.jp/wp-content/themes/recovery/images/common/logo_ogp.png"),
        "9229": .imageURL("https://sunwels.jp/wp-content/uploads/2025/04/cropped-siteicon-180x180.png"),
        "9240": .imageURL("https://icons.sollahiro.com/company-icons/9240.png"), // R2 CDN DC mark 512 // pragma: allowlist secret
        "9251": .imageURL("https://ab-company.co.jp/cropped-abc-logo_transparent-180x180.png"),
        "9278": .imageURL("https://www.bookoffgroup.co.jp/management/wp-content/uploads/2025/05/cropped-bogh-favicon-180x180.jpg"),
        "9279": .imageURL("https://cdn.prod.website-files.com/63ef03c2b82a66a06802f5f0/63ef0496a31e98089d9deb03_webclip.png"),
        "9332": .imageURL("https://www.nisso-hd.com/assets_hd/images/apple.png"),
        "9381": .imageURL("https://www.ait-jp.com/wp/wp-content/uploads/2022/01/cropped-AIT512x512-180x180.png"),
        "9434": .imageURL("https://www.softbank.jp/site/set/common/shared/img/icon_softbank.gif"),
        "9475": .imageURL("https://www.mapple.co.jp/wp/wp-content/themes/mapple/assets/favicon/apple-touch-icon.png"),
        "9556": .imageURL("https://www.intloop.com/wp-content/themes/intloop_241023/assets/images/common/apple-touch-icon.png"),
        "9601": .imageURL("https://www.shochiku.co.jp/wp-content/themes/shochiku2025/images/ogp.png"),
        "9699": .imageURL("https://nishio-grp.co.jp/wordpress/wp-content/uploads/2023/04/cropped-fav-2-180x180.png"),
        "9716": .imageURL("https://www.nomurakougei.co.jp/img/apple-touch-icon.png"),
        "9723": .imageURL("https://www.kyotohotel.co.jp/wp-content/themes/group_temp/favicon-icon.png?date=20190401"),
        "9769": .imageURL("https://www.gakkyusha.com/wp-content/uploads/2026/08/cropped-cropped-cropped-favicon-180x180.png"),
        "9902": .imageURL("https://www.nichiden.com/cms/wp-content/themes/nichiden/apple-touch-icon-180x180.png"),
        "9932": .imageURL("https://www.sugi-net.co.jp/corp/wp-content/uploads/2021/02/cropped-favicon-180x180.png"),
        "9941": .imageURL("https://www.taiyo-bussan.co.jp/wp-content/uploads/2018/12/cropped-sitelogo_single-180x180.png"),
        "9978": .imageURL("https://www.bunkyodo.co.jp/wp-content/uploads/2021/10/cropped-favicon_512x512-180x180.jpg"),
        "9984": .imageURL("https://group.softbank/sites/default/files/assets/img/logo-group-square.png"),
        // 2026-10-31 weekly missing: listed × company_icons 欠行。公告から自動 ingest できず、公式 apple-touch / logo / origin。
        "1429": .imageURL("https://www.n-aqua.jp/assets/images/common/apple-icon-180x180.png"),
        "1447": .imageURL("https://www.saaf-hd.co.jp/media/YkB4cb3kh0VFYh4dHFQ116tlABkyzbKW0bOe16Rp.png"),
        "1771": .imageURL("https://www.kanryu.co.jp/assets/img/common/ogp.jpg"),
        "1897": .imageURL("https://www.kaneshita.co.jp/file/2016/06/cropped-25231e1667d9ed76e1a19e6fcd321df6-1-e1467102917523.png"),
        "1898": .imageURL("https://www.seikitokyu.co.jp/assets/images/common/logo_black.svg"),
        "1981": .imageURL("https://www.kyowa-nissei.co.jp/images/logo.svg"),
        "2003": .imageURL("https://www.nittofuji.co.jp/img/favicon/apple-touch-icon.png"),
        "2137": .imageURL("https://www.varus.co.jp/common/images/flogo.png"),
        "2152": .imageURL("https://www.youji.co.jp/images/logo.png"),
        "2207": .imageURL("https://www.meito-abc.co.jp/apple-touch-icon.png"),
        "2215": .imageURL("https://www.daiichipan.co.jp/favicon.ico"),
        "2294": .imageURL("https://www.kakiyasuhonten.co.jp/assets/images/favicon/apple-icon-144x144.png"),
        "2304": .imageURL("https://www.css-holdings.jp/material/img/logo.png"),
        "2341": .imageURL("https://www.atimes.co.jp/product/images/logo_job.png"),
        "2345": .imageURL("https://hodl1.jp/wp-content/themes/hodl1/assets/img/apple-touch-icon.png"),
        "2388": .imageURL("https://www.wedge-hd.com/image/top_logo_unicon_hobby_3l_u.jpg"),
        "2418": .imageURL("https://www.tsukada-global.holdings/shared/common/ogp.jpg"),
        "2652": .imageURL("https://www.mandarake.co.jp/img/icon/shortcut/144.png"),
        "2668": .imageURL("https://tabio.com/cdn/shop/files/web_sns___750_750_logo.jpg?v=1791449389&width=750"),
        "2752": .imageURL("https://fujiogroup.com/img/top/mv_logo_06.png"),
        "2795": .imageURL("https://www.primex.co.jp/k_images/logo.png"),
        "2819": .imageURL("https://www.ebarafoods.com/shared/img/desk_ico.png"),
        "2911": .imageURL("https://www.asahimatsu.co.jp/img/FB-f-Logo__blue_512.png"),
        "2915": .imageURL("https://www.kenkomayo.co.jp/cms/img/km_header/logo_km.png"),
        "2999": .imageURL("https://www.homeposition.co.jp/assets/img/og-img.jpg"),
        "3030": .imageURL("https://www.pub-hub.co.jp/images/index/logoAccess.png"),
        "3059": .imageURL("https://company.hiraki.co.jp/wp-content/uploads/2026/02/cropped-favicon-180x180.webp"),
        "3143": .imageURL("https://owill.co.jp/img/logo.png"),
        "3161": .imageURL("https://www.azearth.co.jp/images/top/logo.png"),
        "3172": .imageURL("https://www.tealifeir.com/_cmn/logo.png"),
        "3192": .imageURL("https://www.shirohato.co.jp/common/img/logo_b.jpg"),
        "3422": .imageURL("https://www.jp-jmax.co.jp/assets/images/common/logo.png"),
        "3556": .imageURL("https://corp.renet.jp/business/img/recycling/logo.png"),
        "3652": .imageURL("https://www.dmprof.com/wp-content/uploads/2022/11/ogp.jpg"),
        "3675": .imageURL("https://www.cm-group.co.jp/assets/v2023/favicon/apple-touch-icon.png"),
        "3803": .imageURL("https://image-inf.co.jp/wp-content/uploads/2026/03/cropped-logo-icon-w-180x180.png"),
        "3927": .imageURL("https://www.fuva-brain.co.jp/wp-content/themes/fuva/images/ico/apple-touch-icon.webp"),
        "3988": .imageURL("https://www.syshd.co.jp/data/img/common/apple-touch-icon-precomposed.png"),
        "3989": .imageURL("https://www.sharing-tech.co.jp/cms/wp-content/uploads/2023/08/cropped-favicon-180x180.png"),
        "4026": .imageURL("https://www.konoshima.co.jp/common/globallogo.png"),
        "4113": .imageURL("https://www.taoka-chem.co.jp/shared/images/logo.svg"),
        "4172": .imageURL("https://hi-crates.co.jp/wp-content/plugins/hi-crates-top-g/assets/logo-hi-mark.png"),
        "4179": .imageURL("https://www.gnext.co.jp/wp-content/uploads/2026/03/favicon.webp"),
        "4220": .imageURL("https://www.rikentechnos.co.jp/img/common/image/img_logo.png"),
        "4234": .imageURL("https://www.sun-a-kaken.co.jp/assets/img/logo.png"),
        "4299": .imageURL("https://www.himacs.co.jp/Portals/0/images/logo.png"),
        "4344": .imageURL("https://sourcenext.co.jp/~/media/Images/cojp/common/logo_w"),
        "4351": .imageURL("https://www.yamada-servicer.co.jp/common/img/logo.jpg"),
        "4390": .imageURL("https://ipsism.co.jp/wp-content/uploads/cropped-ips-favicon02-180x180.png"),
        "4421": .imageURL("https://www.di-system.co.jp/wp-content/themes/di-system/assets/image/ogimage.jpg"),
        "4425": .imageURL("https://www.kudan.io/wp-content/uploads/2020/05/cropped-NoImage-192x192.png"),
        "4478": .imageURL("https://www.freee.co.jp/favicon.ico"),
        "4591": .imageURL("https://www.ribomic.com/img/logo_fbogp.jpg"),
        "4597": .imageURL("https://solasia.co.jp/common/img/apple-touch-icon.png"),
        "4616": .imageURL("https://www.kawakami-paint.co.jp/images/logo.png"),
        "4662": .imageURL("https://www.focus-s.com/media/SDO1b3MbQBU6vOTH5DVaz3gSC8LEX7D8uAy8dJP2.png"),
        "5074": .imageURL("https://www.tess-hd.co.jp/media/t4rVBb5v5VGpc9NRddYQ8aYW18TnmDfTy5AaEH6H.png"),
        "5078": .imageURL("https://www.cel-co.com/wp-content/themes/cel_co/assets/img/common/logo.png"),
        "5204": .imageURL("https://www.ishizuka.co.jp/public/wp-content/uploads/2018/12/cropped-favicon-180x180.png"),
        "5355": .imageURL("https://www.rutsubo.com/images/group_logo.svg"),
        "5537": .imageURL("https://albalink.co.jp/wp-content/uploads/2019/06/cropped-favicon-180x180.png"),
        "5576": .imageURL("https://www.obs.co.jp/assets/images/common/logo.svg"),
        "5603": .imageURL("https://www.kogi.co.jp/assets/img/common/icon_logo.svg"),
        "5609": .imageURL("https://www.nipponchuzo.co.jp/img/logo.gif"),
        "5621": .imageURL("https://www.h-t.co.jp/assets/humantechnology/img/common/isms_logo.jpg"),
        "5819": .imageURL("https://www.canare.co.jp/image/logo.svg"),
        "5891": .imageURL("https://www.sakigake-holdings.co.jp/media/uEytn9n5jSBBtnibkxNcwADqLfFsEgdaLgno6pgM.png"),
        "5905": .imageURL("https://www.nihonseikan.co.jp/cmn/img/pluslogo3.jpg"),
        "5936": .imageURL("https://www.toyo-shutter.co.jp/assets/img/common/logo.webp"),
        "5985": .imageURL("https://www.suncall.co.jp/wp/wp-content/uploads/2026/09/cropped-logo_suncall-180x180.png"),
        "6059": .imageURL("https://www.uchiyama-gr.jp/image/header/logo.gif"),
        "6063": .imageURL("https://emergency.co.jp/common/img/logo_footer_privacy01.gif"),
        "6158": .imageURL("https://www.waida.co.jp/favicon.ico"),
        "6167": .imageURL("https://www.fujidie.co.jp/assets/images/logo.png"),
        "6177": .imageURL("https://www.appbank.co.jp/cms/wp-content/themes/appbank/_assets/img/ogp.png"),
        "6266": .imageURL("https://tazmo.co.jp/wp/wp-content/themes/tazmo-new/common/img/common/img_logo.svg"),
        "6279": .imageURL("https://www.zuiko.co.jp/assets/image/favicon.ico"),
        "6316": .imageURL("https://www.maruyama.co.jp/ogp.jpg"),
        "6337": .imageURL("https://www.tesec.co.jp/wp-content/uploads/2023/03/cropped-favicon-180x180.png"),
        "6380": .imageURL("https://www.ocm.co.jp/bdflashinfo/thumbnail.png"),
        "6518": .imageURL("https://www.sanso-elec.co.jp/wordpress/wp-content/themes/sanso/images/header/logo_img_sp.gif"),
        "6571": .homepageOrigin("https://www.qbnet.jp"),
        "6623": .imageURL("https://www.aichidenki.jp/images/common/adk_logo-bl.png"),
        "6658": .imageURL("https://www.shiraidenshi.co.jp/homepage/common/images/60th_logo.png"),
        "6668": .imageURL("https://www.adtec-rf.co.jp/wpcms/wp-content/themes/adtec-rf/img/logo.png"),
        "6721": .imageURL("https://www.wintest.co.jp/cmn/img/header_logo.png"),
        "6800": .imageURL("https://www.yokowo.co.jp/common/images/apple-touch-icon.png"),
        "6864": .imageURL("https://nfhd.co.jp/jp/images/logo/logo_nfbt.png"),
        "6908": .imageURL("https://www.irisoele.com/apple-touch-icon.png"),
        "6942": .imageURL("https://www.sophia.com/img/logo_cvh.svg"),
        "6947": .imageURL("https://www.zuken.co.jp/wp-content/uploads/sites/2/2019/04/cropped-ZUKEN_flag-512-180x180.png"),
        "7058": .imageURL("https://www.kyoei-ss.co.jp/wp-content/themes/kyoei-parent/assets/images/favicon_io/apple-touch-icon.png"),
        "7244": .imageURL("https://www.ichikoh.com/_img/common/logo_valeo.png"),
        "7273": .imageURL("https://www.ikuyo194.co.jp/wp-content/themes/wp_theme/ogp_img.webp"),
        "7345": .imageURL("https://www.aipf.co.jp/img/ogp.png"),
        "7442": .imageURL("https://www.nakayamafuku.co.jp/common/img/nf_ogp.jpg"),
        "7472": .imageURL("https://www.toba.co.jp/common/img/logo.png"),
        "7481": .imageURL("https://www.oie.co.jp/img/logo.png"),
        "7531": .imageURL("https://www.seiwa-chuo-holdings.co.jp/shared/img/logo.png"),
        "7554": .imageURL("https://hd.kourakuen.co.jp/images/brand/logo.png"),
        "7590": .imageURL("https://takasho.co.jp/cms/favicon.ico"),
        "7625": .imageURL("https://www.global-dining.com/_next/static/media/logo.bc6f622a.png"),
        "7637": .imageURL("https://www.hakudo.co.jp/Portals/0/images/common/Hakudo_Net_Service_logo_A_web_190614.png?302"),
        "7791": .imageURL("https://www.dreambed.co.jp/themes/company/images/common/logo-serta.svg"),
        "8071": .imageURL("https://www.tokai-ele.com/common/img/logo.svg"),
        "8093": .imageURL("https://www.kbk.co.jp/application/themes/kbk/img/ogp.jpg"),
        "8147": .imageURL("https://www.tomitaj.co.jp/common/img/ft_logo.gif"),
        "8336": .imageURL("https://www.musashinobank.co.jp/assets/img/common/logo@2x.png"),
        "8364": .imageURL("https://www.shimizubank.co.jp/assets/images/webclip.png"),
        "8739": .imageURL("https://www.sparx.jp/icon/apple-touch-icon-144x144.png"),
        "8747": .imageURL("https://www.yutaka-trusty.co.jp/src/img/cropped-favicon-180x180.png"),
        "8783": .imageURL("https://abc-chain.com/wp-content/uploads/2026/03/cropped-favicon-180x180.png"),
        "8841": .imageURL("https://www.toc.co.jp/new1/assets/images/toc-logo.svg"),
        "8894": .imageURL("https://revolution.co.jp/assets/img/ogp/ogp.png"),
        "8908": .imageURL("https://www.maicom.co.jp/img/sp/common/logo_sp.png"),
        "8918": .imageURL("https://www.land.jp/assets/img/component/logo_footer.svg"),
        "9060": .imageURL("https://www.logitem.co.jp/common/images/headlogo.png"),
        "9218": .imageURL("https://www.mh-tec.co.jp/media/jsOI9uSvRCI49U9CZFw9v52WRtq1H96yOjdUfW9N.png"),
        "9233": .imageURL("https://www.ajiko.co.jp/assets/images/site-logo8.png"),
        "9319": .imageURL("https://www.chuosoko.co.jp/common/img/logo.svg"),
        "9322": .imageURL("https://www.kawanishi.co.jp/apple-touch-icon-180x180.png"),
        "9365": .imageURL("https://tradia.co.jp/img/common/logo.png"),
        "9635": .imageURL("https://www.musashino-k.co.jp/imgs/seff_logo_off.jpg"),
        "9644": .imageURL("https://www.tanabeconsulting-group.com/assets/img/top/logo-human-capital.png"),
        "9701": .imageURL("https://www.kaikan.co.jp/images/opening_logo_sp.png"),
        "9765": .imageURL("https://www.k-ohba.co.jp/ohba/wp-content/themes/OHBA/img/common/sns.jpg"),
        "9845": .imageURL("https://www.parkercorp.co.jp/common/img/logo_sp.png"),
        "9846": .imageURL("https://www.tenmaya-store.co.jp/assets/img/common/logo_top_02.png"),
        "9857": .imageURL("https://www.eiwa-net.co.jp/dcms_media/image/ogp.png"),
        "9986": .imageURL("https://www.zaohnet.co.jp/wp-content/uploads/logo_mark.jpg"),
    ]

    static func manualSource(for code: String) -> CompanyIconManualSource? {
        manualSources[code]
    }

    /// 手動 homepage があればそれを返す。Pronexus 掲載ドメインなら公式サイト origin。それ以外はそのまま。
    static func originForFavicon(code: String, extractedOrigin: String) -> String {
        if case .homepageOrigin(let origin)? = manualSources[code] {
            return origin
        }
        guard isPronexusDisclosureHost(extractedOrigin),
            let mapped = pronexusDisclosureHomepages[code]
        else { return extractedOrigin }
        return mapped
    }

    static func isPronexusDisclosureHost(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host?.lowercased(), !host.isEmpty else { return false }
        return host == "pronexus.co.jp" || host.hasSuffix(".pronexus.co.jp")
    }
}
