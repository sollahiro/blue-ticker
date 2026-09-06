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
    static let manualSources: [String: CompanyIconManualSource] = [
        "7203": .homepageOrigin("https://toyota.jp"),
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
