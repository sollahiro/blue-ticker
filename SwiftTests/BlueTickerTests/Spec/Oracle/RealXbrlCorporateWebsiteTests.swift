// 実 EDINET XBRL キャッシュ（analysis_cache）での CorporateWebsiteExtractor 回帰テスト
// （2026-08-08 実データ検証）。
//
// 「第6 提出会社の株式事務の概要」の「公告掲載方法」行から電子公告URLを抽出できることを、
// URL直前の表記が異なる複数社（ラベル無し・「電子公告掲載ＵＲＬ：」・「公告掲載URL　」）で確認する。
// 抽出結果はscheme+hostのみ（パス・クエリは破棄）。
//
// キャッシュが無い環境では `.enabled(if:)` で自動 SKIP（`swift test` は鍵なしでも緑）。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct RealXbrlCorporateWebsiteTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func cacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: xbrlDir(docID).path)
    }

    // MARK: - 味の素 S100VXJA（URL直前にラベル文言なし、段落分離）

    @Test(.enabled(if: cacheAvailable("S100VXJA"), "XBRL cache S100VXJA not available"))
    func ajinomotoExtractsElectronicPublicNoticeURL() {
        let result = CorporateWebsiteExtractor.extract(xbrlDir: Self.xbrlDir("S100VXJA"))
        #expect(result.method == "xbrl_url")
        #expect(result.url == "https://www.ajinomoto.co.jp")
    }

    // MARK: - ニチレイ S100VYA0

    @Test(.enabled(if: cacheAvailable("S100VYA0"), "XBRL cache S100VYA0 not available"))
    func nichireiExtractsElectronicPublicNoticeURL() {
        let result = CorporateWebsiteExtractor.extract(xbrlDir: Self.xbrlDir("S100VYA0"))
        #expect(result.method == "xbrl_url")
        #expect(result.url == "https://www.nichirei.co.jp")
    }

    // MARK: - スズキ S100W4MT（「公告掲載URL　」ラベル＋IRサブページ、originのみへ正規化）

    @Test(.enabled(if: cacheAvailable("S100W4MT"), "XBRL cache S100W4MT not available"))
    func suzukiNormalizesToOriginDroppingPath() {
        let result = CorporateWebsiteExtractor.extract(xbrlDir: Self.xbrlDir("S100W4MT"))
        #expect(result.method == "xbrl_url")
        #expect(result.url == "https://www.suzuki.co.jp")
    }

    // MARK: - レーザーテック S100JRT9（スキーム直後が全角コロン「https：//」）

    @Test(.enabled(if: cacheAvailable("S100JRT9"), "XBRL cache S100JRT9 not available"))
    func lasertecNormalizesFullWidthColonAfterScheme() {
        let result = CorporateWebsiteExtractor.extract(xbrlDir: Self.xbrlDir("S100JRT9"))
        #expect(result.method == "xbrl_url")
        #expect(result.url == "https://www.lasertec.co.jp")
    }

    // MARK: - テルモ S100R4TX（URL直後に空白なく日本語「です。」が続く。監査レビューで発見:
    // 除外方式の正規表現だとIDNA punycode化された不正ホストを生成していた）

    @Test(.enabled(if: cacheAvailable("S100R4TX"), "XBRL cache S100R4TX not available"))
    func terumoStopsURLBeforeTrailingJapaneseText() {
        let result = CorporateWebsiteExtractor.extract(xbrlDir: Self.xbrlDir("S100R4TX"))
        #expect(result.method == "xbrl_url")
        #expect(result.url == "https://www.terumo.co.jp")
    }

    // MARK: - S100L0TZ（紙媒体（日本経済新聞）のみ、電子公告なし＝正当な not_applicable）

    @Test(.enabled(if: cacheAvailable("S100L0TZ"), "XBRL cache S100L0TZ not available"))
    func paperOnlyPublicNoticeCompanyReturnsNotApplicable() {
        let result = CorporateWebsiteExtractor.extract(xbrlDir: Self.xbrlDir("S100L0TZ"))
        #expect(result.method == "not_applicable")
        #expect(result.url == nil)
    }

    // MARK: - 該当節自体が無い場合（四半期報告書等）は not_found（正当な非対象、抽出失敗ではない）

    @Test func directoryWithoutSectionReturnsNotFound() throws {
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blue-ticker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let result = CorporateWebsiteExtractor.extract(xbrlDir: emptyDir)
        #expect(result.method == "not_found")
        #expect(result.url == nil)
    }
}
