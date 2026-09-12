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
    /// 公式 `logo.png`（600×600）を直指定（2026-09-12 icons audit priority A）。
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
    static let manualSources: [String: CompanyIconManualSource] = [
        "7203": .homepageOrigin("https://toyota.jp"),
        "9267": .imageURL("https://genky.co.jp/common/cmn_img/logo.png"),
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
        "4452": .imageURL("https://www.kao.com/content/dam/sites/kao/www-kao-com/jp/ja/index/ogp_logo.png"),
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
        "3539": .imageURL("https://jm-holdings.co.jp/img/ogp.jpg"),
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
