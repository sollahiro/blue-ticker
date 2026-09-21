// SPEC_INVARIANT: LLM 内訳の unit=million_yen は分母を約 1e12 に膨らませない。
// 表示百万円（493,677）×1e6＝円が正しく、円相当を再乗算した 4.93677e+17 は不可。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct BreakdownLLMAmountScaleTests {

    @Test func millionYenDisplayAmountsScaleToYen() {
        let sales = 493_677 * Financial.millionYen
        let scale = BreakdownLLMAmountScale.yenMultiplier(
            declaredUnit: "million_yen",
            rawAmounts: [370_225, 25_295, 43_062, 49_146, 5_949, 493_677],
            consolidatedSales: sales
        )
        #expect(scale.unresolved == false)
        #expect(scale.multiplier == Financial.millionYen)
        #expect(493_677 * scale.multiplier == sales)
    }

    @Test func millionYenDeclaredButYenScaleAmountsAreNotInflatedBy1e12() {
        let sales = 493_677 * Financial.millionYen
        let yenScaleAmounts = [370_225, 25_295, 43_062, 49_146, 5_949, 493_677]
            .map { $0 * Financial.millionYen }
        let scale = BreakdownLLMAmountScale.yenMultiplier(
            declaredUnit: "million_yen",
            rawAmounts: yenScaleAmounts,
            consolidatedSales: sales
        )
        #expect(scale.unresolved == false)
        #expect(scale.multiplier == 1)
        let denominator = 493_677 * Financial.millionYen * scale.multiplier
        #expect(denominator == sales)
        #expect(denominator / sales < 10)
        #expect(abs(log10(denominator / (493_677))) < 8)
    }

    @Test func yenUnitDoesNotMultiply() {
        let scale = BreakdownLLMAmountScale.yenMultiplier(
            declaredUnit: "yen",
            rawAmounts: [493_677_000_000],
            consolidatedSales: 493_677_000_000
        )
        #expect(scale.multiplier == 1)
        #expect(scale.unresolved == false)
    }

    @Test func unknownUnitIsUnresolved() {
        let scale = BreakdownLLMAmountScale.yenMultiplier(
            declaredUnit: "other",
            rawAmounts: [100],
            consolidatedSales: 100 * Financial.millionYen
        )
        #expect(scale.unresolved == true)
        #expect(scale.multiplier == 1)
    }
}
