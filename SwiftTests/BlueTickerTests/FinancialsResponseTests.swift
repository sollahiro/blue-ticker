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
        #expect(resp["unit"] == nil)
        #expect((resp["units"] as? [String: String])?["sales"] == "currency_amount")
        #expect((resp["units"] as? [String: String])?["roe"] == "percent")
        #expect((resp["years"] as? [[String: Any]])?.isEmpty == true)
    }

    /// 金額は格納（百万）から基本単位の整数へ。通貨は年度ごとで、混在するとトップは null。
    @Test func amountsAreBaseUnitsAndCurrencyIsPerYear() throws {
        let result = try decodeResult(#"""
        {"code":"6269","years":[
          {"fy_end":"2025-12-31","FinancialPeriod":"FY",
           "RawData":{"Sales":4581.232,"EPS":5.28,"Currency":"USD"},"CalculatedData":{"ROE":12.5,"DSO":40}},
          {"fy_end":"2024-12-31","FinancialPeriod":"FY",
           "RawData":{"Sales":3700.5},"CalculatedData":{}}
        ]}
        """#)
        let resp = FinancialsResponse(
            code: "6269", name: "三井海洋開発", sector: "機械", market: "プライム", result: result)
        let summary = resp.summaryJsonObject()
        let years = try #require(summary["years"] as? [[String: Any]])
        #expect(years[0]["currency"] as? String == "USD")
        #expect(years[0]["sales"] as? Double == 4_581_232_000)
        #expect(years[0]["eps"] as? Double == 5.28)
        #expect(years[0]["roe"] as? Double == 12.5)
        #expect(years[1]["currency"] as? String == "JPY")
        #expect(summary["currency"] is NSNull)
        let units = try #require(summary["units"] as? [String: String])
        #expect(units["sales"] == "currency_amount")
        #expect(units["eps"] == "currency_per_share")
        #expect(units["employees"] == "persons")
        #expect(units["issued_shares"] == "shares")
        #expect(units["dso"] == nil)  // Waterfall 専用キーは Summary の units に載せない
        let waterfallUnits = try #require(resp.analysisJsonObject()["units"] as? [String: String])
        #expect(waterfallUnits["dso"] == "days")
        #expect(waterfallUnits["ccc_dpo_effect"] == "days")
        #expect(waterfallUnits["roe_delta"] == "percentage_points")
        #expect(waterfallUnits["asset_turnover"] == "times")
        // 格納形（Codable）は百万のまま往復する。
        let stored = try JSONDecoder().decode(
            FinancialsResponse.self, from: JSONEncoder().encode(resp))
        #expect(stored.years[0].sales == 4581.232)
        #expect(stored.years[0].currency == "USD")
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
        #expect(companyFinancialsMinServableVersion == 4)
        #expect(isServableCompanyFinancialsCacheVersion("fin-v1") == false)
        #expect(isServableCompanyFinancialsCacheVersion("fin-v2") == false)
        #expect(isServableCompanyFinancialsCacheVersion("fin-v3") == false)
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
        #expect(y.keys.contains("eps"))
        #expect(y.keys.contains("bps"))
        #expect(y.keys.contains("roe"))
        #expect(y.keys.contains("ccc"))
        #expect(y["RawData"] == nil)  // ネスト構造ではない
    }

    @Test func schemaVersionIsStableInteger() {
        #expect(Api.financialsSchemaVersion == 4)
    }

    @Test func assemblyFingerprintJoinsCanonicalVersionsInFixedOrder() {
        let fingerprint = financialsAssemblyFingerprint()
        let parts = fingerprint.split(separator: "|").map(String.init)
        #expect(parts == [
            statementCacheVersion,
            perShareInformationNoteCacheVersion,
            issuedSharesAndCapitalNoteCacheVersion,
            capitalExpendituresOverviewBreakdownCacheVersion,
            borrowingsScheduleNoteCacheVersion,
            leaseLiabilitiesNoteCacheVersion,
            employeesBreakdownCacheVersion,
            researchAndDevelopmentBreakdownCacheVersion,
            interestBearingDebtBreakdownCacheVersion,
        ])
        #expect(isCurrentFinancialsAssemblyFingerprint(fingerprint))
        #expect(isCurrentFinancialsAssemblyFingerprint(nil) == false)
        #expect(isCurrentFinancialsAssemblyFingerprint("statement-v0") == false)
    }

    // MARK: - Summary / Waterfall の境界（docs/financials-summary-separation.md）

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
            #expect(y.keys.contains(key) == false, "\(key) は Waterfall 専用のため Summary に含めない")
        }
        // 水準値（ticker summarize が表示する項目）は残る。
        #expect(y["roic"] as? Double == 9.0)
        #expect(y["net_cash"] as? Double == 110000000)
        #expect(y["accounts_receivable"] as? Double == 200000000)
    }

    // MARK: - `?fields=` 射影（BLT-57）

    @Test func summaryFieldKeysExcludeAnalysisOnlyKeys() {
        #expect(financialsSummaryFieldKeys.contains("sales"))
        #expect(financialsSummaryFieldKeys.contains("operating_profit"))
        #expect(financialsSummaryFieldKeys.contains("net_profit"))
        #expect(financialsSummaryFieldKeys.isSuperset(of: financialsSummaryIdentityKeys))
        #expect(financialsSummaryFieldKeys.isDisjoint(with: FinancialsYear.analysisOnlyKeys))
    }

    @Test func fieldsQueryParsesKeysAndRejectsUnknown() {
        #expect(parseFinancialsFieldsQuery(nil) == .all)
        #expect(parseFinancialsFieldsQuery("") == .all)
        #expect(parseFinancialsFieldsQuery(" , ") == .all)
        #expect(parseFinancialsFieldsQuery("sales, operating_profit") == .projection(["sales", "operating_profit"]))
        // Waterfall 専用キーは Summary の射影対象外。
        #expect(parseFinancialsFieldsQuery("roic_delta") == .unknownFields(["roic_delta"]))
        #expect(parseFinancialsFieldsQuery("zzz,sales,aaa") == .unknownFields(["aaa", "zzz"]))
    }

    @Test func summaryProjectionKeepsIdentityKeysAndValues() throws {
        let full = try #require(financialsResponse().summaryJsonObject()["years"] as? [[String: Any]])
        let projected = try #require(
            financialsResponse().summaryJsonObject(fields: ["net_cash"])["years"] as? [[String: Any]])

        #expect(projected.count == full.count)
        let y = projected[0]
        #expect(Set(y.keys) == financialsSummaryIdentityKeys.union(["net_cash"]))
        #expect(y["net_cash"] as? Double == 110000000)
    }

    @Test func summaryProjectionKeepsEnvelopeKeys() throws {
        let resp = try financialsResponse().summaryJsonObject(fields: ["sales"])
        #expect(resp["schema_version"] as? Int == Api.financialsSchemaVersion)
        #expect(resp["code"] as? String == "7203")
        #expect(resp["currency"] as? String == "JPY")
        #expect(resp["units"] as? [String: String] == ["sales": "currency_amount"])
    }

    /// 銀行業の期（cash はあるが net_cash を出さない）は有利子負債ベースの Waterfall 差分も null。
    @Test func analysisJsonObjectNullsDebtDeltasForBankYears() throws {
        let result = try decodeResult(#"""
        {"code":"8306","years":[
          {"fy_end":"2025-03","FinancialPeriod":"FY",
           "RawData":{"CashEq":150},
           "CalculatedData":{"InterestBearingDebt":40}},
          {"fy_end":"2024-03","FinancialPeriod":"FY",
           "RawData":{"CashEq":100},
           "CalculatedData":{"InterestBearingDebt":60}}
        ]}
        """#)
        let resp = FinancialsResponse(
            code: "8306", name: "三菱UFJ", sector: "銀行業", market: "プライム", result: result)
        #expect(resp.years.allSatisfy { $0.withholdsBankRatios })
        let years = try #require(resp.analysisJsonObject()["years"] as? [[String: Any]])
        let newer = years[0]
        #expect(newer["net_cash"] is NSNull)
        #expect(newer["net_cash_change"] is NSNull)
        #expect(newer["debt_change_impact"] is NSNull)
        // 預金を除く有利子負債と現金の差分自体は残す。
        #expect(newer["interest_bearing_debt"] as? Double == 40000000)
        #expect(newer["cash_change_impact"] as? Double == 50000000)
    }

    @Test func nonBankYearsDoNotWithholdRatios() throws {
        let years = try financialsResponse().years
        #expect(years.allSatisfy { !$0.withholdsBankRatios })
    }

    @Test func analysisJsonObjectComputesFourthAndFifthBlockDeltas() throws {
        let years = try #require(financialsResponse().analysisJsonObject()["years"] as? [[String: Any]])
        #expect(years.count == 2)
        let newer = years[0]
        let older = years[1]

        // ④ ネットキャッシュ前年差
        #expect(newer["net_cash_change"] as? Double == 70000000)
        #expect(newer["cash_change_impact"] as? Double == 50000000)
        #expect(newer["debt_change_impact"] as? Double == 20000000)

        // ⑤ 運転資本前年差
        #expect(newer["working_capital_change"] as? Double == 20000000)
        #expect(newer["accounts_receivable_change_impact"] as? Double == 20000000)
        #expect(newer["inventory_change_impact"] as? Double == 10000000)
        #expect(newer["accounts_payable_change_impact"] as? Double == -10000000)

        // ⑤ CCC前年差
        #expect(newer["ccc_change"] as? Double == 8)
        #expect(newer["ccc_dso_effect"] as? Double == 5)
        #expect(newer["ccc_dio_effect"] as? Double == 5)
        #expect(newer["ccc_dpo_effect"] as? Double == -2)
        #expect(newer["dso_change_impact"] == nil)

        // 最古年（前期なし）は新規④⑤フィールドが null。
        #expect(older["net_cash_change"] is NSNull)
        #expect(older["ccc_change"] is NSNull)

        // Waterfall は Summary の水準値も含むスーパーセット。
        #expect(newer["roic"] as? Double == 9.0)
    }

    @Test func uniquedByFyEndKeepsFirstOfDuplicateFiscalYearEnds() throws {
        let dict: [String: Any] = [
            "schema_version": 2, "code": "4376", "name": "くふう",
            "sector": "", "market": "", "currency": "JPY", "unit": "百万円",
            "years": [
                ["fy_end": "2025-09-30", "doc_id": "S100XC6R", "sales": 14110.0],
                ["fy_end": "2022-09-30", "doc_id": "S100PUYZ", "sales": 18625.0],
                ["fy_end": "2022-09-30", "doc_id": "S100PYLV", "sales": 18625.0],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let resp = try JSONDecoder().decode(FinancialsResponse.self, from: data)
        let uniqued = resp.uniquedByFyEnd()
        #expect(uniqued.years.count == 2)
        #expect(uniqued.years.map(\.docId) == ["S100XC6R", "S100PUYZ"])

        let trimmed = resp.trimmed(toYears: 5)
        #expect(trimmed.years.count == 2)
        #expect(trimmed.years.map(\.docId) == ["S100XC6R", "S100PUYZ"])
    }

    @Test func uniquedByFyEndKeepsFirstWhenAmendmentPrecedesOriginal() throws {
        let dict: [String: Any] = [
            "schema_version": 2, "code": "4376", "name": "くふう",
            "sector": "", "market": "", "currency": "JPY", "unit": "百万円",
            "years": [
                ["fy_end": "2022-09-30", "doc_id": "S100PYLV", "sales": 18625.0],
                ["fy_end": "2022-09-30", "doc_id": "S100PUYZ", "sales": 18625.0],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let resp = try JSONDecoder().decode(FinancialsResponse.self, from: data)
        let uniqued = resp.uniquedByFyEnd()
        #expect(uniqued.years.map(\.docId) == ["S100PYLV"])
    }
}
