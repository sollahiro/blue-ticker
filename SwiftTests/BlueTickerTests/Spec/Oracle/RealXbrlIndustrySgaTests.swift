// 実 EDINET XBRL（analysis_cache）での業種別販管費の golden（百万円）。差額 GP − OP ではなく開示値を読む。
//
// - 大阪瓦斯 9532 / S100YFQT（26/03）: 標準タグ SellingGeneralAndAdministrativeExpenses 262,706（変わらない）
// - 東邦瓦斯 9533 / S100YGFW（26/03）: 供給販売費及び一般管理費 147,511（…GAS）
// - ケイヒン 9312 / S100YHI4（26/03）: 一般管理費 2,185（GeneralAndAdministrativeExpensesSGA）
// - ナブテスコ 6268 / S100XTOY（25/12）: IFRS 継続事業の販管費 71,964（GP − OP = 73,055 はその他収益・費用込み）
//
// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、無ければ SKIP。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RealXbrlIndustrySgaTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private func expectSga(_ docID: String, sga: Double, label: String?) async throws {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: Self.xbrlRoot)
        let dir = Self.xbrlRoot.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return
        }
        let v = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(v.sga == sga * 1_000_000)
        #expect(v.sgaLabel == label)
        #expect(v.operatingProfitLabel == "営業利益")
    }

    @Test func osakaGasStandardTagUnchanged() async throws {
        try await expectSga("S100YFQT", sga: 262_706, label: nil)
    }

    @Test func tohoGasSupplySellingAndAdministrative() async throws {
        try await expectSga("S100YGFW", sga: 147_511, label: "供給販売費及び一般管理費")
    }

    @Test func keihinGeneralAdministrativeOnly() async throws {
        try await expectSga("S100YHI4", sga: 2_185, label: "一般管理費")
    }

    @Test func nabtescoIfrsContinuingOperations() async throws {
        try await expectSga("S100XTOY", sga: 71_964, label: nil)
    }
}
