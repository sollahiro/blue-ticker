import Foundation
import Testing

@testable import BlueTickerCore

/// REST 公開契約（FinancialsResponse 等）の Codable 往復とキー存在を検証する。
@Suite struct RemoteContractTests {
    /// MetricsResult → 契約 JSON → MetricsResult で、v2 で追加したフィールドを含め往復する。
    @Test func financialsContractRoundTripsRenderedFields() throws {
        var raw = RawData.blank
        raw.sales = 1000
        raw.op = 200
        raw.np = 150
        raw.cfo = 300
        raw.capex = 50
        raw.buyback = 20
        raw.rd = 10
        raw.cashEq = 800
        raw.curPerType = "FY"

        var calc = CalculatedData.blank
        calc.docID = "S100ABC"
        calc.sellingGeneralAdministrativeExpenses = 400   // v2 追加
        calc.nopat = 140                                   // v2 追加
        calc.effectiveTaxRate = 30.5                       // v2 追加
        calc.interestExpense = 5                           // v2 追加
        calc.currentAssets = 5000                          // v2 追加
        calc.nonCurrentAssets = 7000                       // v2 追加
        calc.ppeTotal = 3000                               // v2 追加
        calc.netDE = 0.4                                   // v2 追加
        calc.opLabel = "営業利益"                            // v2 追加
        calc.roe = 12.3
        calc.ccc = 45

        let entry = YearEntry(
            fyEnd: "2025-03", financialPeriod: "FY", rawData: raw, calculatedData: calc)
        var result = MetricsResult.blank
        result.code = "7203"
        result.years = [entry]

        let response = FinancialsResponse(
            code: "7203", name: "トヨタ自動車", sector: "輸送用機器", market: "プライム", result: result)

        // サーバー出力（全キー存在）→ シリアライズ → クライアント側デコード。
        let object = response.jsonObject()
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(FinancialsResponse.self, from: data)

        #expect(decoded.schemaVersion == Api.financialsSchemaVersion)
        #expect(decoded.name == "トヨタ自動車")

        let back = decoded.toMetricsResult().years?.first
        let r = try #require(back)
        #expect(r.fyEnd == "2025-03")
        #expect(r.rawData.sales == 1000)
        #expect(r.rawData.capex == 50)
        #expect(r.rawData.cashEq == 800)
        #expect(r.calculatedData.docID == "S100ABC")
        #expect(r.calculatedData.sellingGeneralAdministrativeExpenses == 400)
        #expect(r.calculatedData.nopat == 140)
        #expect(r.calculatedData.effectiveTaxRate == 30.5)
        #expect(r.calculatedData.interestExpense == 5)
        #expect(r.calculatedData.currentAssets == 5000)
        #expect(r.calculatedData.nonCurrentAssets == 7000)
        #expect(r.calculatedData.ppeTotal == 3000)
        #expect(r.calculatedData.netDE == 0.4)
        #expect(r.calculatedData.opLabel == "営業利益")
        #expect(r.calculatedData.ccc == 45)
    }

    /// jsonObject() は CodingKeys 全キーを欠落なく含む（既存契約「全キー存在」の維持）。
    @Test func jsonObjectContainsAllContractKeys() throws {
        var result = MetricsResult.blank
        result.years = [
            YearEntry(
                fyEnd: "2025-03", financialPeriod: "FY",
                rawData: .blank, calculatedData: .blank)
        ]
        let object = FinancialsResponse(
            code: "x", name: "x", sector: "", market: "", result: result
        ).jsonObject()
        let year = try #require((object["years"] as? [[String: Any]])?.first)
        for key in FinancialsYear.CodingKeys.allCases {
            #expect(year.keys.contains(key.rawValue), "missing key: \(key.rawValue)")
        }
    }

    /// companies の公開 JSON は location を含む。
    @Test func companyJSONDecodesLocation() throws {
        let json = #"[{"code":"7203","name":"トヨタ","sector":"輸送用機器","market":"プライム","location":"愛知県"}]"#
        let arr = try JSONDecoder().decode([StockSearchResult].self, from: Data(json.utf8))
        #expect(arr.first?.location == "愛知県")
    }

    /// ExtractedBreakdown.toDictionary() ↔ init(dictionary:) が往復する。
    @Test func extractedBreakdownRoundTripsThroughDictionary() {
        let original = ExtractedBreakdown(
            method: "html_table",
            tables: [BreakdownTable(heading: "セグメント別売上", markdown: "| a | b |", period: "当期")],
            facts: [
                BreakdownFact(
                    tag: "Sales", contextRef: "CurrentYearDuration",
                    dimensions: ["Segment": "AutoMember"], value: 12345,
                    label: "売上", unitRef: "JPY", decimals: "-6")
            ])
        let restored = ExtractedBreakdown(dictionary: original.toDictionary())
        #expect(restored == original)
    }
}
