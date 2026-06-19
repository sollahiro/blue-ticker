import Testing
import Foundation
@testable import BlueTickerCore

// applyWorkingCapitalAndCCCToYears の振る舞い仕様。
// 運転資本（売掛金+棚卸資産−買掛金）と CCC 構成（DSO/DIO/DPO/CCC）の算出契約を検証する。
// CCC 標準定義: DSO=売掛金÷売上高、DIO/DPO=÷売上原価（売上原価=売上高−売上総利益）。

@Suite struct WorkingCapitalCCCTests {

    private func entry(
        fyEnd: String = "2024-03-31",
        sales: Double? = nil,
        grossProfit: Double? = nil,
        ar: Double? = nil,
        inv: Double? = nil,
        ap: Double? = nil
    ) -> YearEntry {
        var raw = RawData()
        raw.sales = sales
        var calc = CalculatedData()
        calc.grossProfit = grossProfit
        calc.accountsReceivable = ar
        calc.inventory = inv
        calc.accountsPayable = ap
        return YearEntry(fyEnd: fyEnd, financialPeriod: "FY", rawData: raw, calculatedData: calc)
    }

    // MARK: - 運転資本

    @Test func workingCapitalIsArPlusInvMinusAp() {
        var years = [entry(ar: 200, inv: 300, ap: 150)]
        applyWorkingCapitalAndCCCToYears(&years)
        #expect(years[0].calculatedData.workingCapital == 350)  // 200 + 300 - 150
    }

    @Test func workingCapitalNilWhenAnyComponentMissing() {
        var years = [entry(ar: 200, inv: 300, ap: nil)]
        applyWorkingCapitalAndCCCToYears(&years)
        #expect(years[0].calculatedData.workingCapital == nil)
    }

    // MARK: - CCC（標準定義）

    @Test func cccUsesSalesForDsoAndCogsForDioDpo() {
        // sales=1000, grossProfit=400 → 売上原価=600
        var years = [entry(sales: 1000, grossProfit: 400, ar: 200, inv: 300, ap: 150)]
        applyWorkingCapitalAndCCCToYears(&years)
        let cd = years[0].calculatedData
        #expect(cd.dso == 200.0 / 1000.0 * 365.0)   // 73.0
        #expect(cd.dio == 300.0 / 600.0 * 365.0)    // 182.5
        #expect(cd.dpo == 150.0 / 600.0 * 365.0)    // 91.25
        #expect(cd.ccc == 73.0 + 182.5 - 91.25)     // 164.25
    }

    @Test func dsoComputedButCccNilWhenGrossProfitMissing() {
        // 売上総利益が無いと売上原価が出せず DIO/DPO/CCC は nil。DSO は算出可能。
        var years = [entry(sales: 1000, grossProfit: nil, ar: 200, inv: 300, ap: 150)]
        applyWorkingCapitalAndCCCToYears(&years)
        let cd = years[0].calculatedData
        #expect(cd.dso == 200.0 / 1000.0 * 365.0)
        #expect(cd.dio == nil)
        #expect(cd.dpo == nil)
        #expect(cd.ccc == nil)
    }

    @Test func cccNilWhenInventoryMissing() {
        // DIO が出せないと CCC も出ない（3要素必須）。
        var years = [entry(sales: 1000, grossProfit: 400, ar: 200, inv: nil, ap: 150)]
        applyWorkingCapitalAndCCCToYears(&years)
        let cd = years[0].calculatedData
        #expect(cd.dio == nil)
        #expect(cd.ccc == nil)
    }

    @Test func cccNilWhenSalesEqualsGrossProfit() {
        // 売上原価 = 0 以下のときはゼロ除算を避けて DIO/DPO/CCC を出さない。
        var years = [entry(sales: 1000, grossProfit: 1000, ar: 200, inv: 300, ap: 150)]
        applyWorkingCapitalAndCCCToYears(&years)
        let cd = years[0].calculatedData
        #expect(cd.dio == nil)
        #expect(cd.dpo == nil)
        #expect(cd.ccc == nil)
        #expect(cd.dso == 200.0 / 1000.0 * 365.0)  // DSO は売上高基準なので算出される
    }
}
