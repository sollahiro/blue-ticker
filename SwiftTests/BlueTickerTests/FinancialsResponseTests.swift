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
        let resp = buildFinancialsResponse(
            code: "7203", name: "トヨタ自動車", sector: "輸送用機器", market: "プライム",
            result: result)

        #expect(resp["schema_version"] as? Int == Api.financialsSchemaVersion)
        #expect(resp["code"] as? String == "7203")
        #expect(resp["name"] as? String == "トヨタ自動車")
        #expect(resp["sector"] as? String == "輸送用機器")
        #expect(resp["market"] as? String == "プライム")
        #expect(resp["currency"] as? String == "JPY")
        #expect(resp["unit"] as? String == "百万円")
        #expect((resp["years"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func yearsAreFlattenedSnakeCase() throws {
        // RawData/CalculatedData は全 Optional なので最小 JSON から組み立てる。
        let result = try decodeResult(#"""
        {"code":"7203","years":[
          {"fy_end":"2025-03","FinancialPeriod":"FY","RawData":{},"CalculatedData":{}}
        ]}
        """#)
        let resp = buildFinancialsResponse(
            code: "7203", name: "x", sector: "", market: "", result: result)

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
        // 公開契約バージョンは現状 1（破壊的変更時のみ +1）。
        #expect(Api.financialsSchemaVersion == 1)
    }
}
