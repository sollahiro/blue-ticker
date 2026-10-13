// 実 EDINET XBRL（analysis_cache）での銀行 Summary 業務純益 / 営業経費 golden。
//
// 業務純益 = 連結業務粗利益（資金・信託・役務・特定・その他業務の各純額）
//          − 営業経費（GeneralAndAdministrativeExpensesOEBNK）。持分法は足さない。
// 期待値は原本 CurrentYearDuration の円単位（百万円 × 1e6）。
//
// - 三菱UFJ 8306 / S100YJQO（26/03）: 5,944,287 − 3,489,570 = 2,454,717
// - 千葉銀行 8331 / S100YDSE（26/03）: 223,275 − 104,888 = 118,387
// - みずほ 8411 / S100YF8Y（26/03）: 単体 OperatingIncome タグだけあり連結 OP 値が空（旧: 経常利益・op_label null）
//   3,477,300 − 2,103,458 = 1,373,842
// - 七十七銀行 8341 / S100YAM0（26/03）: 106,460 − 55,360 = 51,100
// - 信金中央金庫 8421 / S100YH59（26/03）: 営業経費タグ無し（「経費」GeneralAndAdministrativeExpenses）
//   → operating_profit / sga とも null（経常利益・差額で埋めない）
// - HSホールディングス 8699 / S100YJQ6: 預金はあるが営業利益行がある → 営業利益のまま（銀行経路にしない）
//
//
// Waterfall（2期の実書類）: 既存3スロット = 経常収益差 / 業務粗利益率差 / 営業経費差 の和が Δ業務純益 に一致。
// - 三菱UFJ S100W4FB（25/03）→ S100YJQO（26/03）
// - 豊和銀行 8559 S100W0EY（25/03）→ S100YF85（26/03）
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
        _ docID: String, grossProfit: Double, expenses: Double, netBusinessProfit: Double
    ) async throws {
        guard let dir = await Self.ensureAvailable(docID) else { return }
        let v = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(v.grossProfit == grossProfit * Self.million)
        #expect(v.grossProfitLabel == "連結業務粗利益")
        #expect(v.sga == expenses * Self.million)
        #expect(v.sgaLabel == "営業経費")
        #expect(v.operatingProfit == netBusinessProfit * Self.million)
        #expect(v.operatingProfitLabel == "業務純益")
        #expect(v.salesLabel == "経常収益")
    }

    @Test func mufgS100YJQONetBusinessProfit() async throws {
        try await expectBank(
            "S100YJQO", grossProfit: 5_944_287, expenses: 3_489_570,
            netBusinessProfit: 2_454_717)
    }

    @Test func chibaBankS100YDSERegionalNetBusinessProfit() async throws {
        try await expectBank(
            "S100YDSE", grossProfit: 223_275, expenses: 104_888,
            netBusinessProfit: 118_387)
    }

    @Test func mizuhoS100YF8YWithNonConsolidatedOperatingIncomeTagStillUsesNetBusinessProfit() async throws {
        try await expectBank(
            "S100YF8Y", grossProfit: 3_477_300, expenses: 2_103_458,
            netBusinessProfit: 1_373_842)
    }

    @Test func shichijushichiS100YAM0RegionalNetBusinessProfit() async throws {
        try await expectBank(
            "S100YAM0", grossProfit: 106_460, expenses: 55_360,
            netBusinessProfit: 51_100)
    }

    @Test func shinkinCentralBankS100YH59WithoutOperatingExpensesFailsClosed() async throws {
        guard let dir = await Self.ensureAvailable("S100YH59") else { return }
        let v = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(v.operatingProfit == nil)
        #expect(v.operatingProfitLabel == nil)
        #expect(v.sga == nil)
        #expect(v.sgaLabel == nil)
    }

    @Test func hsHoldingsS100YJQ6WithOperatingIncomeLineStaysOperatingProfit() async throws {
        guard let dir = await Self.ensureAvailable("S100YJQ6") else { return }
        let v = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(v.operatingProfitLabel == "営業利益")
        #expect(v.sgaLabel == nil)
    }

    // MARK: - Waterfall（2期）

    private func bankYear(_ docID: String, fyEnd: String) async throws -> YearEntry? {
        guard let dir = await Self.ensureAvailable(docID) else { return nil }
        let v = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        var raw = RawData()
        raw.sales = v.sales.map { $0 / Self.million }
        raw.op = v.operatingProfit.map { $0 / Self.million }
        raw.salesLabel = v.salesLabel
        var calc = CalculatedData()
        calc.grossProfit = v.grossProfit.map { $0 / Self.million }
        calc.sellingGeneralAdministrativeExpenses = v.sga.map { $0 / Self.million }
        calc.opLabel = v.operatingProfitLabel
        calc.sgaLabel = v.sgaLabel
        return YearEntry(fyEnd: fyEnd, financialPeriod: "FY", rawData: raw, calculatedData: calc)
    }

    private func expectExactBankWaterfall(prior: String, current: String) async throws {
        guard let p = try await bankYear(prior, fyEnd: "2025-03-31"),
              let c = try await bankYear(current, fyEnd: "2026-03-31") else { return }
        var years = [c, p]
        applyOperatingProfitChangeToYears(&years)
        let cur = years[0], pri = years[1]
        #expect(cur.calculatedData.opLabel == "業務純益" && pri.calculatedData.opLabel == "業務純益")
        #expect(cur.rawData.salesLabel == "経常収益" && pri.rawData.salesLabel == "経常収益")
        // business_profit = 業務純益 = Summary operating_profit
        #expect(cur.calculatedData.businessProfit == cur.rawData.op)
        #expect(pri.calculatedData.businessProfit == pri.rawData.op)
        let cd = cur.calculatedData
        let change = try #require(cd.businessProfitChange)
        let sales = try #require(cd.salesChangeImpact)
        let margin = try #require(cd.grossMarginChangeImpact)
        let sga = try #require(cd.sgaChangeImpact)
        #expect(abs(change - (cur.rawData.op! - pri.rawData.op!)) < 1e-6)
        #expect(abs(sales + margin + sga - change) < 1e-6)
        // 各スロットの中身: 経常収益差 × 前期業務粗利益率 / 当期経常収益 × 業務粗利益率差 / −営業経費差
        let cs = cur.rawData.sales!, ps = pri.rawData.sales!
        let cg = cur.calculatedData.grossProfit!, pg = pri.calculatedData.grossProfit!
        #expect(abs(sales - (cs - ps) * (pg / ps)) < 1e-6)
        #expect(abs(margin - cs * (cg / cs - pg / ps)) < 1e-6)
        #expect(sga == -(cur.calculatedData.sellingGeneralAdministrativeExpenses!
                         - pri.calculatedData.sellingGeneralAdministrativeExpenses!))
    }

    @Test func mufgWaterfallSumsExactlyToNetBusinessProfitChange() async throws {
        try await expectExactBankWaterfall(prior: "S100W4FB", current: "S100YJQO")
    }

    @Test func howaRegionalWaterfallSumsExactlyToNetBusinessProfitChange() async throws {
        try await expectExactBankWaterfall(prior: "S100W0EY", current: "S100YF85")
    }
}
