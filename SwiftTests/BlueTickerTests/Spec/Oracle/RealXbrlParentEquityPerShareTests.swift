// 実 EDINET XBRL（analysis_cache）: 1株当たり純資産の通貨と ROE の分母（親会社持分）。
//
// - 6269 三井海洋開発 S100XU6C（IFRS・米ドル建て、2025-12期）。主要な経営指標等は邦貨併記で、
//   `EquityToAssetRatioIFRSSummaryOfBusinessResults` の当期末に USDPerShares 21.26 と
//   JPYPerShares 3327.57（円換算の参考値）が同じ context で並ぶ。BPS は開示通貨の 21.26（有報 p.2）。
//   親会社持分 1,452,809 千ドル（資本合計 1,474,043 − 非支配持分 21,233）。
// - 7974 任天堂 S100W73A（日本基準、2025-03期）。親会社持分は本表に行が無いので
//   純資産合計 2,725,446 − 非支配株主持分 1,119 = 2,724,327 百万円（株主資本 2,486,746 + その他の包括利益累計額 237,581）。
//
// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、無ければ SKIP。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RealXbrlParentEquityPerShareTests {
    private static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")

    private static func dir(_ docID: String) async -> URL? {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: root)
        let dir = root.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return nil
        }
        return dir
    }

    @Test func foreignCurrencyFilingKeepsReportingCurrencyPerShareValues() async throws {
        guard let dir = await Self.dir("S100XU6C") else { return }
        let facts = XBRLUtils.collectAllNumericFacts(in: dir)
        let bpsFact = try #require(facts["EquityToAssetRatioIFRSSummaryOfBusinessResults"]?["CurrentYearInstant"])
        #expect(bpsFact.unitRef == "USDPerShares")
        #expect(bpsFact.value == 21.26)
        #expect(StatementNotesResolver.financialsCanonicalBps(xbrlDir: dir) == 21.26)
        #expect(StatementNotesResolver.financialsCanonicalEps(xbrlDir: dir) == 5.28)
    }

    @Test func ifrsParentEquityExcludesNonControllingInterests() async throws {
        guard let dir = await Self.dir("S100XU6C") else { return }
        let v = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(v.currency == "USD")
        #expect(v.netAssets == 1_474_043_000)
        #expect(v.parentEquity == 1_452_809_000)
    }

    @Test func jgaapParentEquityIsNetAssetsLessNonControllingInterests() async throws {
        guard let dir = await Self.dir("S100W73A") else { return }
        let v = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(v.netAssets == 2_725_446_000_000)
        #expect(v.parentEquity == 2_724_327_000_000)
    }
}
