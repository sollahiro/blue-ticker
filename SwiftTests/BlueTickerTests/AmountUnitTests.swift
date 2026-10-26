import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct AmountUnitTests {
    @Test func exactTokensMapToYenMultipliers() {
        #expect(AmountUnit.yenMultiplier(forToken: "円") == 1)
        #expect(AmountUnit.yenMultiplier(forToken: "千円") == 1_000)
        #expect(AmountUnit.yenMultiplier(forToken: "百万円") == 1_000_000)
        #expect(AmountUnit.yenMultiplier(forToken: "億円") == 100_000_000)
        #expect(AmountUnit.yenMultiplier(forToken: "十億円") == 1_000_000_000)
        #expect(AmountUnit.yenMultiplier(forToken: "兆円") == 1_000_000_000_000)
        #expect(AmountUnit.yenMultiplier(forToken: "百万米ドル") == nil)
        #expect(AmountUnit.yenMultiplier(forToken: "株") == nil)
        #expect(AmountUnit.captionScale(forToken: "千米ドル")
            == AmountUnit.CaptionScale(token: "千米ドル", currency: "USD", multiplier: 1_000))
    }

    @Test func containedTokensPreferLargerUnitAndDoNotCountTenBillionAsHundredMillion() {
        #expect(AmountUnit.yenMultiplier(containedIn: "十億円") == 1_000_000_000)
        #expect(AmountUnit.yenMultiplier(containedIn: "百万円、%") == 1_000_000)
        #expect(AmountUnit.yenMultiplier(containedIn: "円") == 1)
        #expect(AmountUnit.yenMultiplier(containedIn: "円/株") == nil)
        #expect(AmountUnit.yenScale(containedIn: "設備投資金額（十億円）")?.token == "十億円")
        #expect(AmountUnit.yenScale(containedIn: "（億円）")?.token == "億円")
    }

    @Test func lastYenScaleTakesTheUnitNearestTheTable() {
        let heading = "前期（単位：百万円）… 当期の明細（単位：千円）"
        #expect(AmountUnit.lastYenScale(in: heading)?.token == "千円")
        #expect(AmountUnit.lastYenScale(in: "（単位：十億円）")?.token == "十億円")
        #expect(AmountUnit.lastYenScale(in: "（単位：十億円）", among: ["千円", "億円"]) == nil)
    }

    @Test func inferredLlmDeclaredUnitNeedsExactlyOneHit() {
        let sales = 2_000_000_000.0
        #expect(AmountUnit.inferredLlmDeclaredUnit(
            tableTotal: 2_000, consolidatedSales: sales, tolerance: 0.9...1.1) == "million_yen")
        #expect(AmountUnit.inferredLlmDeclaredUnit(
            tableTotal: 2_000_000, consolidatedSales: sales, tolerance: 0.9...1.1) == "thousand_yen")
        #expect(AmountUnit.inferredLlmDeclaredUnit(
            tableTotal: 7, consolidatedSales: sales, tolerance: 0.9...1.1) == "other")
        #expect(AmountUnit.inferredLlmDeclaredUnit(
            tableTotal: nil, consolidatedSales: sales, tolerance: 0.9...1.1) == "other")
    }

    /// 三井海洋開発 6269（S100XU6C）は米ドル建て開示で、statement の unitRef が USD / USDPerShares。
    @Test func xbrlUnitRefsMapToCurrencyAndCode() {
        #expect(AmountUnit.currency(unitRef: "JPY") == "JPY")
        #expect(AmountUnit.currency(unitRef: "USD") == "USD")
        #expect(AmountUnit.currency(unitRef: "USDPerShares") == "USD")
        #expect(AmountUnit.currency(unitRef: "shares") == nil)
        #expect(AmountUnit.currency(unitRef: "pure") == nil)
        #expect(AmountUnit.code(unitRef: "JPY") == .currencyAmount)
        #expect(AmountUnit.code(unitRef: "JPYPerShares") == .currencyPerShare)
        #expect(AmountUnit.code(unitRef: "USDPerShares") == .currencyPerShare)
        #expect(AmountUnit.code(unitRef: "shares") == .shares)
        #expect(AmountUnit.code(unitRef: "pure") == nil)
        #expect(AmountUnit.isPerShare(unitRef: "USDPerShares"))
        #expect(!AmountUnit.isPerShare(unitRef: "USD"))
    }
}
