import Testing
import Foundation
@testable import BlueTickerCore

// waterfall / summary --format json の出力キー契約。
// MetricsJSON.print は JSONEncoder().encode(MetricsResult) の結果を
// 整形して出力するだけなので、CodingKeys のキー名がそのまま CLI JSON 出力の公開契約になる。
// キー名の変更（リネーム・大文字小文字の変更を含む）は破壊的変更であることをここで固定する。
// リモート REST 契約（FinancialsResponse）は RemoteContractTests が守る。本スイートはローカル
// 分析パス（MetricsResult）の契約を守る。

@Suite struct MetricsJSONContractTests {

    private func encodeToDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let obj = try JSONSerialization.jsonObject(with: data)
        let dict = obj as? [String: Any]
        try #require(dict != nil)
        return dict!
    }

    private func makeYearEntry() -> YearEntry {
        var raw = RawData()
        raw.curPerType = "FY"
        raw.curFYSt = "2023-04-01"
        raw.curFYEn = "2024-03-31"
        raw.discDate = "2024-06-25"
        raw.salesLabel = "売上高"
        raw.sales = 1000
        raw.op = 100
        raw.np = 70
        raw.netAssets = 500
        raw.cfo = 120
        raw.cfi = -80
        raw.capex = 90
        raw.buyback = 10
        raw.rd = 30
        raw.eps = 120.5
        raw.bps = 850.0
        raw.shOutFY = 1_000_000
        raw.cashEq = 200
        var calc = CalculatedData()
        calc.roe = 14
        calc.roic = 8
        calc.grossProfit = 400
        calc.workingCapital = 350
        calc.dso = 73
        calc.dio = 100
        calc.dpo = 50
        calc.ccc = 123
        calc.nopatMargin = 7
        calc.investedCapitalTurnover = 1.1
        calc.roeDelta = 1.5
        calc.docID = "S100TEST"
        return YearEntry(
            fyEnd: "2024-03-31", financialPeriod: "2024年03月期",
            rawData: raw, calculatedData: calc)
    }

    // MARK: - MetricsResult（annual）

    @Test func metricsResultUsesSnakeCaseTopLevelKeys() throws {
        var result = MetricsResult()
        result.code = "7203"
        result.latestFyEnd = "2024-03-31"
        result.analysisYears = 5
        result.availableYears = 5
        result.years = [makeYearEntry()]
        result.dataAvailability = "full"
        result.dataAvailabilityMessage = "5年分のデータが利用可能"
        result.dataValid = true
        result.validationMessage = "OK"

        let dict = try encodeToDictionary(result)
        #expect(Set(dict.keys) == [
            "code", "latest_fy_end", "analysis_years", "available_years", "years",
            "data_availability", "data_availability_message", "data_valid",
            "validation_message",
        ])
    }

    @Test func yearEntryExposesPythonCompatibleContainerKeys() throws {
        let dict = try encodeToDictionary(makeYearEntry())
        #expect(Set(dict.keys) == ["fy_end", "FinancialPeriod", "RawData", "CalculatedData"])
    }

    @Test func rawDataKeysMatchPythonNames() throws {
        let entry = try encodeToDictionary(makeYearEntry())
        let raw = entry["RawData"] as? [String: Any]
        try #require(raw != nil)
        // makeYearEntry は RawData の全フィールドを設定している。
        // ここが落ちたら CLI JSON 出力（RawData）の破壊的変更。
        #expect(Set(raw!.keys) == [
            "CurPerType", "CurFYSt", "CurFYEn", "DiscDate", "SalesLabel",
            "Sales", "OP", "NP", "NetAssets", "CFO", "CFI", "Capex", "Buyback",
            "RD", "EPS", "BPS", "ShOutFY", "CashEq",
        ])
    }

    @Test func calculatedDataUsesUpperCamelAndAcronymKeys() throws {
        let entry = try encodeToDictionary(makeYearEntry())
        let calc = entry["CalculatedData"] as? [String: Any]
        try #require(calc != nil)
        // makeYearEntry で設定した代表フィールドのキー綴りを固定する
        // （ROE/ROIC/CCC 等の頭字語は大文字、他は UpperCamelCase）。
        #expect(Set(calc!.keys) == [
            "ROE", "ROIC", "GrossProfit", "WorkingCapital",
            "DSO", "DIO", "DPO", "CCC",
            "NOPATMargin", "InvestedCapitalTurnover", "ROEDelta", "DocID",
        ])
    }

    @Test func nilFieldsAreOmittedFromOutput() throws {
        // Optional の nil フィールドはキーごと出力されない（null を出さない）
        let dict = try encodeToDictionary(MetricsResult(code: "7203"))
        #expect(Set(dict.keys) == ["code"])
    }
}
