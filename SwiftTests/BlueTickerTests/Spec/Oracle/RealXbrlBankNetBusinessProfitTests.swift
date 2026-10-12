// 実 EDINET XBRL（analysis_cache）での銀行 Summary 業務純益 / 営業経費 golden。
//
// 業務純益 = 連結業務粗利益（資金・信託・役務・特定・その他業務の各純額）
//          − 営業経費（GeneralAndAdministrativeExpensesOEBNK）
//          + 持分法による投資損益（CF EquityInEarningsLossesOfAffiliatesOpeCF の符号反転。無ければ 0）
// 期待値は原本 CurrentYearDuration の円単位（百万円 × 1e6）。
//
// - 三菱UFJ 8306 / S100YJQO（26/03）: 5,944,287 − 3,489,570 + 845,545 = 3,300,262
// - 千葉銀行 8331 / S100YDSE（26/03）: 223,275 − 104,888 + 623 = 119,010
// - みずほ 8411 / S100YF8Y（26/03）: 単体 OperatingIncome タグだけあり連結 OP 値が空（旧: 経常利益・op_label null）
//   3,477,300 − 2,103,458 + 52,266 = 1,426,108
// - 七十七銀行 8341 / S100YAM0（26/03）: 持分法なし 106,460 − 55,360 = 51,100
// - 信金中央金庫 8421 / S100YH59（26/03）: 営業経費タグ無し（「経費」GeneralAndAdministrativeExpenses）
//   → operating_profit / sga とも null（経常利益・差額で埋めない）
// - HSホールディングス 8699 / S100YJQ6: 預金はあるが営業利益行がある → 営業利益のまま（銀行経路にしない）
//
// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、無ければ SKIP。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RealXbrlBankNetBusinessProfitTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func ensureAvailable(_ docID: String) async -> URL? {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        let dir = xbrlRoot.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return nil
        }
        return dir
    }

    private static let million = 1_000_000.0

    private func expectBank(
        _ docID: String, grossProfit: Double, expenses: Double, equity: Double, netBusinessProfit: Double
    ) async throws {
        guard let dir = await Self.ensureAvailable(docID) else { return }
        let v = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(v.grossProfit == grossProfit * Self.million)
        #expect(v.grossProfitLabel == "連結業務粗利益")
        #expect(v.sga == expenses * Self.million)
        #expect(v.sgaLabel == "営業経費")
        #expect(v.equityMethodIncome == equity * Self.million)
        #expect(v.operatingProfit == netBusinessProfit * Self.million)
        #expect(v.operatingProfitLabel == "業務純益")
        #expect(v.salesLabel == "経常収益")
    }

    @Test func mufgS100YJQONetBusinessProfit() async throws {
        try await expectBank(
            "S100YJQO", grossProfit: 5_944_287, expenses: 3_489_570, equity: 845_545,
            netBusinessProfit: 3_300_262)
    }

    @Test func chibaBankS100YDSERegionalNetBusinessProfit() async throws {
        try await expectBank(
            "S100YDSE", grossProfit: 223_275, expenses: 104_888, equity: 623,
            netBusinessProfit: 119_010)
    }

    @Test func mizuhoS100YF8YWithNonConsolidatedOperatingIncomeTagStillUsesNetBusinessProfit() async throws {
        try await expectBank(
            "S100YF8Y", grossProfit: 3_477_300, expenses: 2_103_458, equity: 52_266,
            netBusinessProfit: 1_426_108)
    }

    @Test func shichijushichiS100YAM0WithoutEquityMethodUsesZero() async throws {
        try await expectBank(
            "S100YAM0", grossProfit: 106_460, expenses: 55_360, equity: 0,
            netBusinessProfit: 51_100)
    }

    @Test func shinkinCentralBankS100YH59WithoutOperatingExpensesFailsClosed() async throws {
        guard let dir = await Self.ensureAvailable("S100YH59") else { return }
        let v = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(v.operatingProfit == nil)
        #expect(v.operatingProfitLabel == nil)
        #expect(v.sga == nil)
        #expect(v.sgaLabel == nil)
        #expect(v.equityMethodIncome == nil)
    }

    @Test func hsHoldingsS100YJQ6WithOperatingIncomeLineStaysOperatingProfit() async throws {
        guard let dir = await Self.ensureAvailable("S100YJQ6") else { return }
        let v = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(v.operatingProfitLabel == "営業利益")
        #expect(v.sgaLabel == nil)
        #expect(v.equityMethodIncome == nil)
    }
}
