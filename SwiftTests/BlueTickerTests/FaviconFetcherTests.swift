// FaviconFetcherの純粋ロジック（マジックバイト判定・<link rel="icon">パース）のユニットテスト。
// 実ネットワークには依存しない（CI/ローカルで常に決定的に緑）。実際のドメインに対する
// 取得成功率（11/11）はセッション内で実測済み（favicon.ico直GET 8/11 → HTML linkフォールバック併用で11/11）。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct FaviconFetcherTests {

    // MARK: - マジックバイト判定

    @Test func sniffsICOFromMagicBytesEvenWithWrongContentType() {
        // 実データ検証: kawasaki-sk.co.jp は正真正銘のICOファイルにContent-Type: text/plainを返す。
        // Content-Typeヘッダーに頼らずマジックバイトのみで判定できることを確認する。
        let icoBytes = Data([0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x10, 0x10])
        #expect(FaviconFetcher.sniffImageContentType(icoBytes) == "image/x-icon")
    }

    @Test func sniffsPNG() {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(FaviconFetcher.sniffImageContentType(pngBytes) == "image/png")
    }

    @Test func sniffsJPEG() {
        let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        #expect(FaviconFetcher.sniffImageContentType(jpegBytes) == "image/jpeg")
    }

    @Test func rejectsHTMLFallbackPage() {
        // 実データ検証: azplan.co.jp / kawasaki-sk.co.jp は /favicon.ico が200だが実体はHTML
        // （SPAフォールバック等）。画像として誤認しないことを確認する。
        let html = Data("<!DOCTYPE html><html></html>".utf8)
        #expect(FaviconFetcher.sniffImageContentType(html) == nil)
    }

    @Test func rejectsEmptyData() {
        #expect(FaviconFetcher.sniffImageContentType(Data()) == nil)
    }

    // MARK: - <link rel="icon"> パース

    @Test func extractsIconHrefFromRealFujifilmMarkup() {
        // 実データ検証: fujifilmholdings.com はドメイン移転済みで /favicon.ico が失敗する。
        // 着地先ページ（holdings.fujifilm.com）の実マークアップから抽出できることを確認する。
        let html = """
        <link rel="apple-touch-icon-precomposed" href="/themes/custom/fujifilm_com_g2/apple-touch-icon-precomposed.png" />
        <link rel="icon" href="/themes/custom/holdings_fujifilm_com_g2/favicon.ico" type="image/vnd.microsoft.icon" />
        """
        #expect(FaviconFetcher.extractIconHref(html: html) == "/themes/custom/holdings_fujifilm_com_g2/favicon.ico")
    }

    @Test func extractsShortcutIconVariant() {
        let html = """
        <link rel="shortcut icon" href="/assets/img/global/favicon.ico">
        """
        #expect(FaviconFetcher.extractIconHref(html: html) == "/assets/img/global/favicon.ico")
    }

    @Test func returnsNilWhenNoIconLinkPresent() {
        let html = "<html><head><title>no icon here</title></head></html>"
        #expect(FaviconFetcher.extractIconHref(html: html) == nil)
    }
}
