// 「第6 提出会社の株式事務の概要」内の「公告掲載方法」行から、電子公告のURLを抽出する。
//
// 実データ検証（2026-08-08、有報キャッシュ全150件中148件が対象=四半期報告書にはこの節が無い）:
// ラベル「公告掲載方法」は全社で一致する。URL直前の表記（「電子公告掲載ＵＲＬ：」「公告掲載URL　」
// 「なお、電子公告は…」等）は会社ごとに揺れるため、ラベルに固定せずセル全体から URL を正規表現で拾う。
// パス・クエリはfavicon取得に不要かつ年度間で変わりやすいため、scheme+hostのみへ正規化する
// （www有無は開示どおり保持し、勝手に剥がさない）。
//
// レーザーテック（S100JRT9等、複数年度で再現）実データ検証: `https：//www.lasertec.co.jp` のように
// スキーム直後が全角コロンの会社がある。半角`:`のみ許容すると取りこぼすため両方受理し、
// マッチ後に半角へ正規化してから `URL(string:)` に渡す。
//
// 対象148件中136件（92%）でURL抽出に成功。残り12件は「日本経済新聞」等の紙媒体のみ、または
// 「電子公告（注）」のように別注記にURLを委譲する会社で、この行単体からは正当に抽出不能
// （`not_applicable`）。花王（S100XT6G）はスキーム省略のベアドメイン表記（`www.kao.com/...`）を
// 使っており未対応（既知の限界、影響は1/148のみのためスコープ外）。
//
// 三越伊勢丹HD（S100YD7C）実データ検証（2026-08-09）: ラベルが「公告掲載方法」ではなく
// 「公告掲載URL」の会社があり、旧ラベル固定判定では該当行自体を見つけられず not_found に
// 落ちていた（本来は xbrl_url で救えるケース）。ラベル判定を複数候補の部分一致に拡張。
//
// 日立建機（S100YIBR）実データ検証（2026-08-09）: ラベルが「掲載」抜きの「公告方法」の会社もあり、
// 本文中に `https://www.hitachicm.com/global/ja/` という有効URLがあるにもかかわらず not_found に
// 落ちていた。「公告方法」を候補へ追加（「公告掲載方法」はこの部分文字列を含まないため衝突しない）。

import Foundation
import SwiftSoup

enum CorporateWebsiteExtractor {

    struct Result {
        let url: String?
        let method: String
    }

    /// 「公告掲載方法」行のラベル文字列。表記揺れは実データで確認され次第ここに追加する。
    private static let publicNoticeMethodLabels = ["公告掲載方法", "公告掲載URL", "公告方法"]

    static func extract(xbrlDir: URL) -> Result {
        guard let html = XBRLUtils.extractTextblockHtml(
            in: xbrlDir, textblockTag: Xbrl.overviewOfOperationalProceduresForSharesTextblockTag
        ), let soup = try? SwiftSoup.parse(html), let rows = try? soup.select("tr") else {
            return Result(url: nil, method: "not_found")
        }

        for row in rows {
            guard let cells = try? row.select("td, th"), cells.count >= 2 else { continue }
            let label = (try? cells[0].text(trimAndNormaliseWhitespace: true)) ?? ""
            guard publicNoticeMethodLabels.contains(where: label.contains) else { continue }

            let content = (try? cells[1].text(trimAndNormaliseWhitespace: true)) ?? ""
            guard let rawURL = firstURL(in: content), let origin = originOnly(rawURL) else {
                return Result(url: nil, method: "not_applicable")
            }
            return Result(url: origin, method: "xbrl_url")
        }
        return Result(url: nil, method: "not_found")
    }

    /// URL本体はASCII印字可能文字（`!`〜`~`）のみを許可する（RFC3986のURI文字集合を包含する
    /// ホワイトリスト）。除外方式（`[^\s<>"'　]+`）だと、開示文でURL直後に空白なく日本語が続く
    /// 表記（例: テルモ「…https://www.terumo.co.jpです。」）を巻き込み、`URL(string:)`が
    /// 末尾の日本語をIDNA punycode化して不正ホスト（`terumo.co.xn--jp-883a6b.`等）を生成する
    /// 実データ不具合があった（監査レビューで発見、157件中1件）。
    private static func firstURL(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "https?[:：]//[!-~]+"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range]).replacingOccurrences(of: "：", with: ":")
    }

    /// scheme+hostのみへ正規化する（パス・クエリは破棄。www有無は開示どおり保持）。
    private static func originOnly(_ urlString: String) -> String? {
        guard let url = URL(string: urlString), let scheme = url.scheme, let host = url.host,
              !host.isEmpty else { return nil }
        return "\(scheme)://\(host)"
    }
}
