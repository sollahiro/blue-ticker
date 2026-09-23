import Foundation
import Testing

@testable import BlueTickerCore

/// Screen 公開契約（最新 FY 投影・3 期売上 CAGR・クエリ解析・応答形）の仕様。
@Suite struct ScreenContractTests {
    private func response(market: String = "プライム", years: [[String: Any]]) throws -> FinancialsResponse {
        let dict: [String: Any] = [
            "schema_version": 2, "code": "7203", "name": "トヨタ", "sector": "輸送用機器",
            "market": market, "currency": "JPY", "unit": "百万円", "years": years,
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(FinancialsResponse.self, from: data)
    }

    @Test func screenRowPicksLatestFyAndDerivesSalesCagr3y() throws {
        let row = try response(years: [
            ["fy_end": "2023-03-31", "sales": 1000.0],
            ["fy_end": "2024-03-31", "sales": 1100.0],
            ["fy_end": "2025-03-31", "sales": 1210.0, "roic": 10.0, "operating_margin": 9.5,
             "roe": 12.0, "net_de": 0.3],
        ]).screenRow()
        let unwrapped = try #require(row)
        #expect(unwrapped.periodEnd == "2025-03-31")
        #expect(unwrapped[.sales] == 1210)
        #expect(unwrapped[.roic] == 10)
        #expect(unwrapped[.netDe] == 0.3)
        let cagr = try #require(unwrapped[.salesCagr3y])
        #expect(abs(cagr - 10) < 1e-9)
    }

    @Test func screenRowDerivesSalesCagr3yFromMoreThanThreeYears() throws {
        let row = try response(years: [
            ["fy_end": "2021-03-31", "sales": 27_214_594.0],
            ["fy_end": "2022-03-31", "sales": 31_379_507.0],
            ["fy_end": "2023-03-31", "sales": 37_154_298.0],
            ["fy_end": "2024-03-31", "sales": 45_095_325.0],
            ["fy_end": "2025-03-31", "sales": 48_036_704.0],
            ["fy_end": "2026-03-31", "sales": 50_684_952.0, "roic": 8.0],
        ]).screenRow()
        let cagr = try #require(row?[.salesCagr3y])
        let expected = ((50_684_952.0 / 45_095_325.0).squareRoot() - 1) * 100
        #expect(abs(cagr - expected) < 1e-9)
    }

    @Test func screenRowLeavesSalesCagrNullWithoutThreePositivePeriods() throws {
        let two = try response(years: [
            ["fy_end": "2024-03-31", "sales": 1000.0],
            ["fy_end": "2025-03-31", "sales": 1100.0],
        ]).screenRow()
        #expect(two?[.salesCagr3y] == nil)
        #expect(two?[.roic] == nil)

        let zeros = try response(years: [
            ["fy_end": "2023-03-31", "sales": 0.0],
            ["fy_end": "2024-03-31", "sales": 1000.0],
            ["fy_end": "2025-03-31", "sales": 1210.0],
        ]).screenRow()
        #expect(zeros?[.salesCagr3y] == nil)
    }

    @Test func screenRowCagrDedupesDuplicateFyEnd() throws {
        let twoDistinct = try response(years: [
            ["fy_end": "2025-03-31", "sales": 1210.0],
            ["fy_end": "2025-03-31", "sales": 1210.0],
            ["fy_end": "2024-03-31", "sales": 1100.0],
        ]).screenRow()
        #expect(twoDistinct?[.salesCagr3y] == nil)

        let threeDistinct = try response(years: [
            ["fy_end": "2025-03-31", "sales": 1210.0],
            ["fy_end": "2025-03-31", "sales": 1210.0],
            ["fy_end": "2024-03-31", "sales": 1100.0],
            ["fy_end": "2023-03-31", "sales": 1000.0],
        ]).screenRow()
        let cagr = try #require(threeDistinct?[.salesCagr3y])
        #expect(abs(cagr - 10) < 1e-9)
    }

    @Test func screenRowCagrSkipsNonPositiveSalesAndIgnoresOlderFourthYear() throws {
        let row = try response(years: [
            ["fy_end": "2021-03-31", "sales": 100.0],
            ["fy_end": "2022-03-31", "sales": 1000.0],
            ["fy_end": "2023-03-31", "sales": 1100.0],
            ["fy_end": "2024-03-31", "sales": 0.0],
            ["fy_end": "2025-03-31", "sales": 1210.0],
        ]).screenRow()
        let cagr = try #require(row?[.salesCagr3y])
        #expect(abs(cagr - 10) < 1e-9)
    }

    @Test func screenRowPayoutRatioUsesParentNetProfit() throws {
        // 親会社帰属とグループ当期利益がずれるとき、分母は Summary `net_profit`（親会社）。
        // コカ・コーラBJH S100XR1L は赤字期なので payout は null。黒字の差額は親会社側。
        let loss = try response(years: [
            ["fy_end": "2025-12-31", "net_profit": -50_763.0, "dividend_ss": 9_763.0],
        ]).screenRow()
        #expect(loss?[.payoutRatio] == nil)

        let profit = try response(years: [
            ["fy_end": "2025-12-31", "net_profit": 90.0, "dividend_ss": 9.0],
        ]).screenRow()
        #expect(profit?[.payoutRatio] == 10)
    }

    @Test func screenRowCagrUsesLatestYearOnceSalesIsProjected() throws {
        // 最新年 sales が null だとその期を飛ばす（ニッカトー S100Y9NY 修正前）。
        // 投影後は最新年を CAGR の newest にする。
        let before = try response(years: [
            ["fy_end": "2023-03-31", "sales": 10_733.0],
            ["fy_end": "2024-03-31", "sales": 10_239.0],
            ["fy_end": "2025-03-31", "sales": 10_076.0],
            ["fy_end": "2026-03-31"],
        ]).screenRow()
        let beforeCagr = try #require(before?[.salesCagr3y])
        let beforeExpected = ((10_076.0 / 10_733.0).squareRoot() - 1) * 100
        #expect(abs(beforeCagr - beforeExpected) < 1e-9)

        let after = try response(years: [
            ["fy_end": "2023-03-31", "sales": 10_733.0],
            ["fy_end": "2024-03-31", "sales": 10_239.0],
            ["fy_end": "2025-03-31", "sales": 10_076.0],
            ["fy_end": "2026-03-31", "sales": 11_340.9, "operating_margin": 9.4],
        ]).screenRow()
        let afterCagr = try #require(after?[.salesCagr3y])
        let afterExpected = ((11_340.9 / 10_239.0).squareRoot() - 1) * 100
        #expect(abs(afterCagr - afterExpected) < 1e-9)
        #expect(after?[.sales] == 11_340.9)
        #expect(after?[.operatingMargin] == 9.4)
    }

    @Test func screenRowDerivesScreenV3Metrics() throws {
        let row = try response(years: [
            ["fy_end": "2023-03-31", "operating_margin": 6.0, "roic": 8.0],
            ["fy_end": "2024-03-31", "operating_margin": 9.0, "roic": 11.0],
            ["fy_end": "2025-03-31", "sales": 2000.0, "cfo": 300.0, "capex": 100.0,
             "operating_margin": 12.0, "roic": 14.0, "dividend_ss": 60.0, "net_profit": 200.0],
        ]).screenRow()
        let unwrapped = try #require(row)
        #expect(unwrapped[.cfo] == 300)
        #expect(unwrapped[.cfoMargin] == 15)
        #expect(unwrapped[.fcf] == 200)
        // 3 期年平均変化幅 =（最新 − 最古）÷ 2。
        #expect(unwrapped[.operatingMarginCagr3y] == 3)
        #expect(unwrapped[.roicCagr3y] == 3)
        #expect(unwrapped[.payoutRatio] == 30)
    }

    @Test func screenRowScreenV3NullPolicies() throws {
        // 3 期に満たない → CAGR は null（新規上場は sales_cagr_3y と同じ null 方針）。
        let noPrior = try response(years: [
            ["fy_end": "2025-03-31", "operating_margin": 12.0, "roic": 14.0],
        ]).screenRow()
        #expect(noPrior?[.operatingMarginCagr3y] == nil)
        #expect(noPrior?[.roicCagr3y] == nil)

        // sales ≤ 0 → cfo_margin は null。capex 欠測 → fcf は null。
        let zeroSales = try response(years: [
            ["fy_end": "2025-03-31", "sales": 0.0, "cfo": 300.0],
        ]).screenRow()
        #expect(zeroSales?[.cfoMargin] == nil)
        #expect(zeroSales?[.fcf] == nil)

        // net_profit ≤ 0（赤字期）・配当行無し → payout_ratio は null（無配と未抽出を区別しない）。
        let loss = try response(years: [
            ["fy_end": "2025-03-31", "net_profit": -50.0, "dividend_ss": 10.0],
        ]).screenRow()
        #expect(loss?[.payoutRatio] == nil)
        let noDividend = try response(years: [
            ["fy_end": "2025-03-31", "net_profit": 200.0],
        ]).screenRow()
        #expect(noDividend?[.payoutRatio] == nil)
    }

    @Test func screenRowMetricCagrDedupesDuplicateFyEnd() throws {
        // 同一 fy_end が 2 行あるとき配列順の先勝ちで latest を決め、
        // CAGR の期選定は一意期のみ（配信側 `uniquedByFyEnd` と同じ規則）。
        let row = try response(years: [
            ["fy_end": "2025-03-31", "roic": 14.0],
            ["fy_end": "2025-03-31", "roic": 99.0],
            ["fy_end": "2024-03-31", "roic": 11.0],
            ["fy_end": "2023-03-31", "roic": 8.0],
        ]).screenRow()
        #expect(row?[.roic] == 14)
        #expect(row?[.roicCagr3y] == 3)
    }

    @Test func screenRowIsNilForPlaceholderOrEmptyMarket() throws {
        #expect(FinancialsResponse.notApplicablePlaceholder(code: "9999").screenRow() == nil)
        #expect(try response(market: "", years: [["fy_end": "2025-03-31"]]).screenRow() == nil)
        #expect(try response(years: []).screenRow() == nil)
    }

    @Test func parseScreenQueryDefaultsAndRanges() throws {
        let query = try parseScreenQuery([
            "sector": "電気機器", "roic_min": "15", "sales_min": "10000", "sales_max": "500000",
            "net_de_max": "1",
        ]).get()
        #expect(query.sector == "電気機器")
        #expect(query.sort == .roic)
        #expect(query.order == .desc)
        #expect(query.limit == Api.screenLimitDefault)
        #expect(query.ranges[.roic] == ScreenRange(min: 15, max: nil))
        #expect(query.ranges[.sales] == ScreenRange(min: 10000, max: 500000))
        #expect(query.ranges[.netDe] == ScreenRange(min: nil, max: 1))
        #expect(query.projectedMetrics == [.sales, .operatingMargin, .roic, .netDe, .salesCagr3y])
    }

    @Test func parseScreenQueryAcceptsMultipleSectors() throws {
        // カンマ区切りは OR。空白トリム・重複除去・空要素は落とす。
        let comma = try parseScreenQuery(["sector": "電気機器, 輸送用機器 ,電気機器,,"]).get()
        #expect(comma.sectors == ["電気機器", "輸送用機器"])
        // キー重複は呼び出し側でカンマ連結済みなので同じ形になる。
        #expect(comma.sector == nil)
        let single = try parseScreenQuery(["sector": "電気機器"]).get()
        #expect(single.sector == "電気機器")
        #expect(single.sectors == ["電気機器"])
        let empty = try parseScreenQuery(["sector": " , "]).get()
        #expect(empty.sectors == [])
        #expect(empty.sector == nil)
    }

    @Test func parseScreenQueryRejectsUnknownAndInvalid() {
        #expect(parseScreenQuery(["foo": "1"]) == .failure(.unknownKeys(["foo"])))
        #expect(parseScreenQuery(["working_capital_min": "1"]) == .failure(.unknownKeys(["working_capital_min"])))
        #expect(parseScreenQuery(["sales_growth_min": "1"]) == .failure(.unknownKeys(["sales_growth_min"])))
        #expect(parseScreenQuery(["gross_profit_margin_min": "1"]) == .failure(.unknownKeys(["gross_profit_margin_min"])))
        #expect(parseScreenQuery(["roic_min": "abc"]) == .failure(.invalidValue(key: "roic_min", value: "abc")))
        #expect(parseScreenQuery(["sort": "sales_growth"]) == .failure(.invalidValue(key: "sort", value: "sales_growth")))
        #expect(parseScreenQuery(["sort": "ccc"]) == .failure(.invalidValue(key: "sort", value: "ccc")))
        #expect(parseScreenQuery(["order": "up"]) == .failure(.invalidValue(key: "order", value: "up")))
        #expect(parseScreenQuery(["limit": "0"]) == .failure(.invalidValue(key: "limit", value: "0")))
        #expect(parseScreenQuery(["roe_min": "10", "roe_max": "5"]) == .failure(.emptyRange(.roe)))
    }

    @Test func parseScreenQueryAcceptsScreenV3Keys() throws {
        let query = try parseScreenQuery([
            "cfo_margin_min": "10", "fcf_min": "0", "roic_cagr_3y_min": "2",
            "operating_margin_cagr_3y_max": "10", "payout_ratio_min": "30",
            "sort": "fcf", "order": "desc",
        ]).get()
        #expect(query.sort == .fcf)
        #expect(query.ranges[.cfoMargin] == ScreenRange(min: 10, max: nil))
        #expect(query.ranges[.fcf] == ScreenRange(min: 0, max: nil))
        #expect(query.ranges[.roicCagr3y] == ScreenRange(min: 2, max: nil))
        #expect(query.ranges[.operatingMarginCagr3y] == ScreenRange(min: nil, max: 10))
        #expect(query.ranges[.payoutRatio] == ScreenRange(min: 30, max: nil))
        // フィルタ・ソートに使った新指標は投影される（core4 のみ既定投影）。
        #expect(query.projectedMetrics.contains(.fcf))
        #expect(query.projectedMetrics.contains(.payoutRatio))
        #expect(!query.projectedMetrics.contains(.cfo))
    }

    @Test func parseScreenQueryClampsLimitAndParsesSort() throws {
        let query = try parseScreenQuery(["limit": "99999", "sort": "sales_cagr_3y", "order": "ASC"]).get()
        #expect(query.limit == Api.screenLimitMax)
        #expect(query.sort == .salesCagr3y)
        #expect(query.order == .asc)
    }

    @Test func responseJsonAlwaysProjectsCore4() {
        let row = ScreenRow(
            code: "7203", name: "トヨタ", market: "プライム", sector: "輸送用機器",
            periodEnd: "2025-03-31", metrics: [.roic: 10, .sales: 1100, .roe: 12])
        let query = ScreenQuery(ranges: [.sales: ScreenRange(min: 1, max: nil), .netDe: ScreenRange(min: nil, max: 1)])
        let json = screenResponseJSON(rows: [row], matched: 7, query: query)
        #expect(json["returned"] as? Int == 1)
        #expect(json["matched"] as? Int == 7)
        #expect((json["sort"] as? [String: String]) == ["key": "roic", "order": "desc"])
        let item = (json["items"] as? [[String: Any]])?.first
        #expect(item?["code"] as? String == "7203")
        #expect(item?["period_end"] as? String == "2025-03-31")
        #expect(item?["roic"] as? Double == 10)
        #expect(item?["sales"] as? Double == 1100)
        #expect(item?["net_de"] is NSNull)
        #expect(item?["operating_margin"] is NSNull)
        #expect(item?["sales_cagr_3y"] is NSNull)
        #expect(item?["roe"] == nil)
    }
}
