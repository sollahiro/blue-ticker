import Foundation
import Testing

@testable import BlueTickerCore

/// financials 公開契約レスポンス（flatten 形 + schema_version）の仕様を検証する。
@Suite struct FinancialsResponseTests {
    private func decodeResult(_ json: String) throws -> MetricsResult {
        try JSONDecoder().decode(MetricsResult.self, from: Data(json.utf8))
    }

    @Test func envelopeCarriesSchemaVersionAndMetadata() throws {
        let result = try decodeResult(#"{"code":"7203","years":[]}"#)
        let resp = FinancialsResponse(
            code: "7203", name: "トヨタ自動車", sector: "輸送用機器", market: "プライム",
            result: result).jsonObject()

        #expect(resp["schema_version"] as? Int == Api.financialsSchemaVersion)
        #expect(resp["code"] as? String == "7203")
        #expect(resp["name"] as? String == "トヨタ自動車")
        #expect(resp["sector"] as? String == "輸送用機器")
        #expect(resp["market"] as? String == "プライム")
        #expect(resp["currency"] as? String == "JPY")
        #expect(resp["unit"] as? String == "百万円")
        #expect((resp["years"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func cacheVersionNumberParsesFinVN() {
        #expect(companyFinancialsCacheVersionNumber("fin-v1") == 1)
        #expect(companyFinancialsCacheVersionNumber("fin-v2") == 2)
        #expect(companyFinancialsCacheVersionNumber("fin-v10") == 10)
        #expect(companyFinancialsCacheVersionNumber("fin-v") == nil)
        #expect(companyFinancialsCacheVersionNumber("0.0.0") == nil)
        #expect(companyFinancialsCacheVersionNumber("fin-v2b") == nil)
    }

    @Test func isServableUsesNumericFloorNotLexicographicOrder() throws {
        #expect(companyFinancialsMinServableVersion == 2)
        #expect(isServableCompanyFinancialsCacheVersion("fin-v1") == false)
        #expect(isServableCompanyFinancialsCacheVersion("fin-v2") == true)
        #expect(isServableCompanyFinancialsCacheVersion("fin-v3") == true)
        #expect(isServableCompanyFinancialsCacheVersion("fin-v4") == true)
        #expect(isServableCompanyFinancialsCacheVersion("fin-v10") == true)
        #expect(isServableCompanyFinancialsCacheVersion("0.0.0") == false)
        // 現行版番号は床以上（不変条件）。
        let current = try #require(companyFinancialsCacheVersionNumber(companyFinancialsCacheVersion))
        #expect(current >= companyFinancialsMinServableVersion)
    }

    @Test func yearsAreFlattenedSnakeCase() throws {
        // RawData/CalculatedData は全 Optional なので最小 JSON から組み立てる。
        let result = try decodeResult(#"""
        {"code":"7203","years":[
          {"fy_end":"2025-03","FinancialPeriod":"FY","RawData":{},"CalculatedData":{}}
        ]}
        """#)
        let resp = FinancialsResponse(
            code: "7203", name: "x", sector: "", market: "", result: result).jsonObject()

        let years = try #require(resp["years"] as? [[String: Any]])
        #expect(years.count == 1)
        let y = years[0]
        // flatten 形のフラットなキーが存在する（ネストしない）。
        #expect(y["fy_end"] as? String == "2025-03")
        #expect(y["financial_period"] as? String == "FY")
        #expect(y.keys.contains("sales"))
        #expect(y.keys.contains("roe"))
        #expect(y.keys.contains("ccc"))
        #expect(y["RawData"] == nil)  // ネスト構造ではない
    }

    @Test func schemaVersionIsStableInteger() {
        // 公開契約バージョンは現状 2（v2 で remote CLI 用フィールドを追加）。
        #expect(Api.financialsSchemaVersion == 2)
    }

    // MARK: - Summarize / Analyze の境界（docs/feature-tiers.md）

    private func twoYearResult() throws -> MetricsResult {
        try decodeResult(#"""
        {"code":"7203","years":[
          {"fy_end":"2025-03","FinancialPeriod":"FY",
           "RawData":{"CashEq":150},
           "CalculatedData":{
             "ROIC":9.0,"NetCash":110,"InterestBearingDebt":40,
             "BusinessProfitChange":5,"ROICDelta":1.2,
             "AccountsReceivable":200,"Inventory":100,"AccountsPayable":80,
             "WorkingCapital":220,"DSO":50,"DIO":30,"DPO":20,"CCC":60
           }},
          {"fy_end":"2024-03","FinancialPeriod":"FY",
           "RawData":{"CashEq":100},
           "CalculatedData":{
             "ROIC":8.0,"NetCash":40,"InterestBearingDebt":60,
             "AccountsReceivable":180,"Inventory":90,"AccountsPayable":70,
             "WorkingCapital":200,"DSO":45,"DIO":25,"DPO":18,"CCC":52
           }}
        ]}
        """#)
    }

    private func financialsResponse() throws -> FinancialsResponse {
        FinancialsResponse(
            code: "7203", name: "トヨタ自動車", sector: "輸送用機器", market: "プライム",
            result: try twoYearResult())
    }

    @Test func summaryJsonObjectExcludesAnalysisOnlyKeys() throws {
        let years = try #require(financialsResponse().summaryJsonObject()["years"] as? [[String: Any]])
        let y = years[0]

        for key in FinancialsYear.analysisOnlyKeys {
            #expect(y.keys.contains(key) == false, "\(key) は Analyze 専用のため Summarize に含めない")
        }
        // 水準値（ticker summarize が表示する項目）は残る。
        #expect(y["roic"] as? Double == 9.0)
        #expect(y["net_cash"] as? Double == 110)
        #expect(y["accounts_receivable"] as? Double == 200)
    }

    @Test func analysisJsonObjectComputesFourthAndFifthBlockDeltas() throws {
        let years = try #require(financialsResponse().analysisJsonObject()["years"] as? [[String: Any]])
        #expect(years.count == 2)
        let newer = years[0]
        let older = years[1]

        // ④ ネットキャッシュ前年差
        #expect(newer["net_cash_change"] as? Double == 70)
        #expect(newer["cash_change_impact"] as? Double == 50)
        #expect(newer["debt_change_impact"] as? Double == 20)

        // ⑤ 運転資本前年差
        #expect(newer["working_capital_change"] as? Double == 20)
        #expect(newer["accounts_receivable_change_impact"] as? Double == 20)
        #expect(newer["inventory_change_impact"] as? Double == 10)
        #expect(newer["accounts_payable_change_impact"] as? Double == -10)

        // ⑤ CCC前年差
        #expect(newer["ccc_change"] as? Double == 8)
        #expect(newer["dso_change_impact"] as? Double == 5)
        #expect(newer["dio_change_impact"] as? Double == 5)
        #expect(newer["dpo_change_impact"] as? Double == -2)

        // 最古年（前期なし）は新規④⑤フィールドが null。
        #expect(older["net_cash_change"] is NSNull)
        #expect(older["ccc_change"] is NSNull)

        // Analyze は Summarize の水準値も含むスーパーセット。
        #expect(newer["roic"] as? Double == 9.0)
    }
}
