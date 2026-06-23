import Testing
import Foundation
@testable import BlueTickerCore

// ウォーターフォール分解関数の境界仕様（空・単一期入力）。
// 前年差は2期以上ないと算出できない。0件・1件のとき、トラップせず差分フィールドを nil のまま返すこと。
// 退行対象: 285A（半期 H2 が 0 件のとき 1..<0 で Range トラップしていたクラッシュ）。
@Suite struct WaterfallEmptyInputTests {

    private func entry(fyEnd: String) -> YearEntry {
        var raw = RawData()
        raw.sales = 1000
        raw.op = 200
        raw.np = 150
        var calc = CalculatedData()
        calc.grossProfit = 400
        calc.businessProfit = 200
        calc.sellingGeneralAdministrativeExpenses = 200
        calc.roe = 10
        calc.roic = 8
        calc.nopatMargin = 12
        calc.investedCapitalTurnover = 0.7
        calc.totalAssets = 5000
        calc.netAssets = 1500
        return YearEntry(fyEnd: fyEnd, financialPeriod: "FY", rawData: raw, calculatedData: calc)
    }

    // MARK: - 空配列（クラッシュ回帰）

    @Test func operatingProfitChangeDoesNotCrashOnEmpty() {
        var years: [YearEntry] = []
        applyOperatingProfitChangeToYears(&years)
        #expect(years.isEmpty)
    }

    @Test func roicWaterfallDoesNotCrashOnEmpty() {
        var years: [YearEntry] = []
        applyRoicWaterfallToYears(&years)
        #expect(years.isEmpty)
    }

    @Test func roeWaterfallDoesNotCrashOnEmpty() {
        var years: [YearEntry] = []
        applyRoeWaterfallToYears(&years)
        #expect(years.isEmpty)
    }

    // MARK: - 単一期（差分は出さない）

    @Test func singlePeriodProducesNoBusinessProfitChange() {
        var years = [entry(fyEnd: "2025-03-31")]
        applyOperatingProfitChangeToYears(&years)
        #expect(years[0].calculatedData.businessProfitChange == nil)
        #expect(years[0].calculatedData.salesChangeImpact == nil)
    }

    @Test func singlePeriodProducesNoRoicDelta() {
        var years = [entry(fyEnd: "2025-03-31")]
        applyRoicWaterfallToYears(&years)
        #expect(years[0].calculatedData.roicDelta == nil)
    }

    @Test func singlePeriodProducesNoRoeDelta() {
        var years = [entry(fyEnd: "2025-03-31")]
        applyRoeWaterfallToYears(&years)
        #expect(years[0].calculatedData.roeDelta == nil)
    }
}
