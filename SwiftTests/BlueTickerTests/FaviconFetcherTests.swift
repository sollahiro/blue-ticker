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

    @Test func extractIconHrefsPrefersRelIconOverAppleTouchAndDropsDuplicates() {
        // 実データ検証: 三井松島は theme favicon.ico と apple-touch-icon の両方を宣言する。
        let html = """
        <link rel="apple-touch-icon" href="/theme/apple-touch-icon.png">
        <link rel="shortcut icon" href="/theme/favicon.ico">
        <link rel="icon" href="/theme/favicon.ico">
        """
        #expect(
            FaviconFetcher.extractIconHrefs(html: html) == [
                "/theme/favicon.ico",
                "/theme/apple-touch-icon.png",
            ])
        #expect(FaviconFetcher.extractIconHref(html: html) == "/theme/favicon.ico")
    }

    @Test func rejectsWordPressDefaultIconHashesAndKeepsOrdinaryPNG() {
        let ordinaryPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(!FaviconFetcher.isWordPressDefaultIcon(ordinaryPNG))
        #expect(FaviconFetcher.wordPressDefaultIconSHA256.count == 2)
        #expect(
            FaviconFetcher.wordPressDefaultIconSHA256.contains(
                "6bdb369337ac2496761c6f063bffea0aa6a91d4662279c399071a468251f51f0"))
        #expect(
            FaviconFetcher.wordPressDefaultIconSHA256.contains(
                "c965a500f698483526faf92ac286047cecd825608cd1d83276de392b30a13a83"))
    }

    @Test func exceedsByteLimitWhenContentLengthIsOverCap() {
        #expect(FaviconFetcher.exceedsByteLimit(expectedContentLength: 3_000_000, accumulated: 0, incoming: 0))
        #expect(!FaviconFetcher.exceedsByteLimit(expectedContentLength: -1, accumulated: 0, incoming: 100))
        #expect(!FaviconFetcher.exceedsByteLimit(expectedContentLength: 100, accumulated: 0, incoming: 0))
    }

    @Test func exceedsByteLimitWhenAccumulatedChunksCrossCap() {
        #expect(FaviconFetcher.exceedsByteLimit(accumulated: 2 * 1024 * 1024, incoming: 1))
        #expect(!FaviconFetcher.exceedsByteLimit(accumulated: 2 * 1024 * 1024 - 10, incoming: 10))
        #expect(FaviconFetcher.exceedsByteLimit(accumulated: 100, incoming: 50, limit: 149))
    }

    @Test func fetchImageURLRejectsPrivateAndNonHTTP() async {
        #expect(await FaviconFetcher.fetch(imageURL: "http://127.0.0.1/logo.png") == nil)
        #expect(await FaviconFetcher.fetch(imageURL: "not-a-url") == nil)
        #expect(await FaviconFetcher.fetch(imageURL: "ftp://example.com/logo.png") == nil)
    }
}
