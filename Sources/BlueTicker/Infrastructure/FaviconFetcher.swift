// 会社の公式サイト（CorporateWebsiteExtractorが抽出したorigin）からfaviconを取得する。
//
// 実データ検証（2026-08-08、有報から抽出した11ドメインで実測）:
// `/favicon.ico` 直GETのみでは 8/11 (73%)。3社は200を返すがContent-Typeがtext/html
// （実体は404/SPAフォールバックページ）、うち1社（旧fujifilmholdings.com）はドメイン自体が
// 別ドメインへ301リダイレクト済みだった。ルートページを取得しリダイレクトを追従したうえで
// `<link rel="icon">` 系タグをパースするフォールバックを追加したところ 11/11 (100%) に到達。
//
// WordPress 既定ファビコン（2026-09-02、本番 company_icons 3267 件）: `/favicon.ico` を先に取ると
// `wp-includes/images/w-logo-*-white-bg.png` へリダイレクトして打ち切る（青 W 175 + 灰 W 71）。
// 同じページの `<link rel="icon"|"shortcut icon">` はテーマ固有ファイルを指す（ホーブ・ハッチ・ワーク・
// 三井松島で実測）。HTML の icon リンクを先に試し、WordPress 既定画像ハッシュは棄てて次候補へ進む。
// また、あるドメインはfaviconの実体がICOファイルにもかかわらずサーバーが
// `Content-Type: text/plain` を返した（マジックバイトでの検証を確認: `00 00 01 00`）。
// Content-Typeヘッダーは信用せず、取得バイト列の先頭シグネチャで画像かどうかを判定する。
//
// User-Agent実データ検証（2026-08-09、日経225本番ingestの実失敗24件で確認）: 自己申告Bot UA
// （`BlueTickerBot/1.0`）だとオムロン・NEC・パナソニックHD・パンパシフィックHD等、実在する
// favicon取得を明確に403拒否するサイトが複数あった。実ブラウザ相当のUAへ変更したところ同サイトは
// 200で取得できることをcurlで直接確認。ただしTDK・荏原等、TLSフィンガープリント等UA以外の
// シグナルでBot判定する高度なWAFを使うサイトはUA変更だけでは救えない（既知の限界）。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftSoup

enum FaviconFetcher {

    struct FetchedIcon {
        let data: Data
        let contentType: String
    }

    private static let requestTimeout: TimeInterval = 8
    private static let maxBytes = 2 * 1024 * 1024
    /// 自己申告Bot UAは複数の実企業サイトで403拒否される（上記コメント参照）ため、実ブラウザ相当を送る。
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    /// WordPress コア同梱の既定サイトアイコン（`w-logo-blue-white-bg.png` / `w-logo-gray-white-bg.png`）。
    /// `/favicon.ico` がここに 301 するサイトを会社ロゴと誤認しないための棄却リスト。
    static let wordPressDefaultIconSHA256: Set<String> = [
        "6bdb369337ac2496761c6f063bffea0aa6a91d4662279c399071a468251f51f0",
        "c965a500f698483526faf92ac286047cecd825608cd1d83276de392b30a13a83",
    ]

    /// `origin` は `CorporateWebsiteExtractor` が返す `scheme://host`（パス無し）。
    static func fetch(origin: String) async -> FetchedIcon? {
        guard let originURL = URL(string: origin),
              let scheme = originURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = originURL.host, PrivateNetworkGuard.isPublicHost(host)
        else { return nil }

        if let htmlIcon = await fetchViaHtmlLink(origin: originURL) { return htmlIcon }
        return await fetchDirect(origin: originURL)
    }

    private static func fetchDirect(origin: URL) async -> FetchedIcon? {
        guard let url = URL(string: "/favicon.ico", relativeTo: origin)?.absoluteURL else { return nil }
        return await fetchImage(url)
    }

    private static func fetchViaHtmlLink(origin: URL) async -> FetchedIcon? {
        guard let (html, finalURL) = await safeGetHTML(origin) else { return nil }
        for iconHref in extractIconHrefs(html: html) {
            guard let iconURL = URL(string: iconHref, relativeTo: finalURL)?.absoluteURL,
                  let iconHost = iconURL.host, PrivateNetworkGuard.isPublicHost(iconHost)
            else { continue }
            if let icon = await fetchImage(iconURL) { return icon }
        }
        return nil
    }

    private static func fetchImage(_ url: URL) async -> FetchedIcon? {
        guard let data = await safeGet(url) else { return nil }
        guard let sniffed = sniffImageContentType(data) else { return nil }
        guard !isWordPressDefaultIcon(data) else { return nil }
        return FetchedIcon(data: data, contentType: sniffed)
    }

    static func isWordPressDefaultIcon(_ data: Data) -> Bool {
        wordPressDefaultIconSHA256.contains(SigV4Signer.sha256Hex(data))
    }

    /// `<link rel="icon"|"shortcut icon"|"apple-touch-icon"...>` の href を探す。
    /// `rel`トークンに完全一致で"icon"を含む標準宣言（icon／shortcut icon）を優先し、
    /// apple-touch-icon系（部分一致のみ）はそれが無い場合のフォールバックとする。
    /// SwiftSoupの属性正規表現セレクタには依存せず、`rel`値を取得後にSwift側で判定する。
    static func extractIconHref(html: String) -> String? {
        extractIconHrefs(html: html).first
    }

    /// `rel` に `icon` トークンがある宣言を先に、apple-touch-icon 系を後に、出現順で返す（重複除去）。
    static func extractIconHrefs(html: String) -> [String] {
        guard let soup = try? SwiftSoup.parse(html),
              let links = try? soup.select("link") else { return [] }
        var preferred: [String] = []
        var fallback: [String] = []
        for link in links {
            let rel = ((try? link.attr("rel")) ?? "").lowercased()
            guard let href = try? link.attr("href"), !href.isEmpty else { continue }
            if rel.split(separator: " ").contains("icon") {
                preferred.append(href)
            } else if rel.contains("icon") {
                fallback.append(href)
            }
        }
        var seen = Set<String>()
        var ordered: [String] = []
        for href in preferred + fallback where seen.insert(href).inserted {
            ordered.append(href)
        }
        return ordered
    }

    private static func safeGet(_ url: URL) async -> Data? {
        guard let host = url.host, PrivateNetworkGuard.isPublicHost(host) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              data.count <= maxBytes
        else { return nil }
        return data
    }

    private static func safeGetHTML(_ url: URL) async -> (html: String, finalURL: URL)? {
        guard let host = url.host, PrivateNetworkGuard.isPublicHost(host) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              data.count <= maxBytes,
              let html = String(data: data, encoding: .utf8) ?? decodeCP932(data),
              let finalURL = response.url
        else { return nil }
        return (html, finalURL)
    }

    /// Content-Typeヘッダーは信用せず、先頭バイトのマジックシグネチャで画像形式を判定する
    /// （実データ検証: 正真正銘のICOファイルにContent-Type: text/plainを返すサーバーを確認）。
    static func sniffImageContentType(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4 else { return nil }
        if bytes[0...3] == [0x00, 0x00, 0x01, 0x00] { return "image/x-icon" }
        if bytes[0...3] == [0x89, 0x50, 0x4E, 0x47] { return "image/png" }
        if bytes[0...2] == [0xFF, 0xD8, 0xFF] { return "image/jpeg" }
        if bytes[0...2] == [0x47, 0x49, 0x46] { return "image/gif" }
        if bytes[0...1] == [0x42, 0x4D] { return "image/bmp" }
        if let text = String(data: data.prefix(256), encoding: .utf8)?.lowercased(),
           text.contains("<svg") { return "image/svg+xml" }
        return nil
    }

    /// リダイレクト先ホストごとにSSRFガードを適用する。private/loopback等へのリダイレクトは
    /// completionHandler(nil)で追従を止める（＝そのレスポンスを最終応答として扱わせる）。
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let host = request.url?.host, PrivateNetworkGuard.isPublicHost(host) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
