// SPEC_INVARIANT: LLM 内訳の金額単位は表ヘッダーを正とし、LLM 申告はフォールバック。
// 千円ヘッダー × LLM million_yen は ×1000（×1e6 で約 1e12 に膨らませない）。
// 単位が一つも決まらないときは倍率 1 のまま unresolved（推測スケールを trusted にしない）。

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

    /// 332A / S100YKM2 型: 表は「単位：千円」、LLM は million_yen。ヘッダーが勝ち ×1000。
    @Test func senYenHeaderBeatsMillionYenLLM() {
        let sales = 5_120_400 * BreakdownLLMAmountScale.thousandYen
        let raw = [5_120_400.0, 1_234_000.0]
        let resolved = BreakdownLLMAmountScale.resolve(
            headerToken: "千円",
            declaredUnit: "million_yen",
            rawAmounts: raw,
            consolidatedSales: sales
        )
        #expect(resolved.unresolved == false)
        #expect(resolved.headerLlmMismatch == true)
        #expect(resolved.multiplier == BreakdownLLMAmountScale.thousandYen)
        #expect(5_120_400 * resolved.multiplier == sales)
        let legacy = BreakdownLLMAmountScale.legacyYenMultiplier(
            declaredUnit: "million_yen", rawAmounts: raw, consolidatedSales: sales)
        #expect(legacy.multiplier == Financial.millionYen)
        #expect(resolved.multiplier / legacy.multiplier == 0.001)
    }

    @Test func millionYenHeaderKeepsMillionScale() {
        let sales = 493_677 * Financial.millionYen
        let raw = [370_225.0, 493_677.0]
        let resolved = BreakdownLLMAmountScale.resolve(
            headerToken: "百万円",
            declaredUnit: "million_yen",
            rawAmounts: raw,
            consolidatedSales: sales
        )
        #expect(resolved.unresolved == false)
        #expect(resolved.headerLlmMismatch == false)
        #expect(resolved.multiplier == Financial.millionYen)
    }

    @Test func yenHeaderDoesNotMultiply() {
        let resolved = BreakdownLLMAmountScale.resolve(
            headerToken: "円",
            declaredUnit: "yen",
            rawAmounts: [5_120_400_000],
            consolidatedSales: 5_120_400_000
        )
        #expect(resolved.multiplier == 1)
        #expect(resolved.unresolved == false)
        #expect(resolved.headerLlmMismatch == false)
    }

    @Test func noHeaderFallsBackToLLMDeclaredUnit() {
        let sales = 493_677 * Financial.millionYen
        let resolved = BreakdownLLMAmountScale.resolve(
            headerToken: nil,
            declaredUnit: "million_yen",
            rawAmounts: [370_225, 493_677],
            consolidatedSales: sales
        )
        #expect(resolved.headerToken == nil)
        #expect(resolved.unresolved == false)
        #expect(resolved.headerLlmMismatch == false)
        #expect(resolved.multiplier == Financial.millionYen)
    }

    @Test func senYenHeaderScalesEvenWhenLLMSaysOther() {
        let resolved = BreakdownLLMAmountScale.resolve(
            headerToken: "千円",
            declaredUnit: "other",
            rawAmounts: [5_120_400],
            consolidatedSales: 5_120_400_000
        )
        #expect(resolved.multiplier == BreakdownLLMAmountScale.thousandYen)
        #expect(resolved.unresolved == false)
        #expect(resolved.headerLlmMismatch == false)
    }

    @Test func senYenHeaderDoesNotRescaleAlreadyYenAmounts() {
        let sales = 5_120_400 * BreakdownLLMAmountScale.thousandYen
        let resolved = BreakdownLLMAmountScale.resolve(
            headerToken: "千円",
            declaredUnit: "yen",
            rawAmounts: [sales],
            consolidatedSales: sales
        )
        #expect(resolved.multiplier == 1)
        #expect(resolved.headerLlmMismatch == true)
        #expect(resolved.unresolved == false)
    }

    @Test func mismatchIsFlaggedWhenYenHeaderAndMillionYenLLMDisagree() {
        let resolved = BreakdownLLMAmountScale.resolve(
            headerToken: "円",
            declaredUnit: "million_yen",
            rawAmounts: [100],
            consolidatedSales: 100
        )
        #expect(resolved.multiplier == 1)
        #expect(resolved.headerLlmMismatch == true)
        #expect(resolved.unresolved == false)
    }

    @Test func unmappedHeaderUnitFailsClosed() {
        let resolved = BreakdownLLMAmountScale.resolve(
            headerToken: "百万ユーロ",
            declaredUnit: "million_yen",
            rawAmounts: [100],
            consolidatedSales: 100 * Financial.millionYen
        )
        #expect(resolved.unresolved == true)
        #expect(resolved.multiplier == 1)
        #expect(resolved.headerLlmMismatch == true)
    }

    @Test func headerUnitTokenPrefersCaptionThenMarkdown() {
        let table = BreakdownTable(
            heading: "収益認識関係",
            markdown: "| 区分 | 当期 |\n| MVNEサービス | 5,120,400 |\n",
            period: "当期",
            unitCaption: "千円"
        )
        #expect(BreakdownLLMAmountScale.headerUnitToken(from: table) == "千円")
        let fromMarkdown = BreakdownTable(
            heading: "収益認識関係",
            markdown: "（単位：百万円）\n| 区分 | 当期 |\n| 製品A | 10,000 |\n",
            period: "当期"
        )
        #expect(BreakdownLLMAmountScale.headerUnitToken(from: fromMarkdown) == "百万円")
    }

    @Test func scalingUsesSourceTableIndexCaption() {
        let tables = [
            BreakdownTable(
                heading: "前期", markdown: "| a | 1 |", period: "前期", unitCaption: "百万円"),
            BreakdownTable(
                heading: "当期", markdown: "| MVNEサービス | 5,120,400 |", period: "当期",
                unitCaption: "千円"),
        ]
        let resolved = BreakdownLLMAmountScale.scaling(
            declaredUnit: "million_yen",
            tables: tables,
            sourceTableIndex: 1,
            rawAmounts: [5_120_400],
            consolidatedSales: 5_120_400_000
        )
        #expect(resolved.headerToken == "千円")
        #expect(resolved.multiplier == BreakdownLLMAmountScale.thousandYen)
        #expect(resolved.headerLlmMismatch == true)
    }

    @Test func uniqueSiblingHeaderUnitFillsMissingSourceTable() {
        let tables = [
            BreakdownTable(
                heading: "契約資産", markdown: "| a | 1 |", period: "当期", unitCaption: "千円"),
            BreakdownTable(
                heading: "収益分解", markdown: "| MVNEサービス | 5,120,400 |", period: "当期"),
        ]
        #expect(BreakdownLLMAmountScale.headerUnitToken(tables: tables, sourceTableIndex: 1) == "千円")
    }

    @Test func mixedSiblingHeaderUnitsDoNotStealFirstTable() {
        let tables = [
            BreakdownTable(
                heading: "a", markdown: "| a | 1 |", period: "当期", unitCaption: "百万円"),
            BreakdownTable(
                heading: "b", markdown: "| b | 2 |", period: "当期", unitCaption: "千円"),
            BreakdownTable(
                heading: "c", markdown: "| c | 3 |", period: "当期"),
        ]
        #expect(BreakdownLLMAmountScale.headerUnitToken(tables: tables, sourceTableIndex: 2) == nil)
        let resolved = BreakdownLLMAmountScale.scaling(
            declaredUnit: "million_yen",
            tables: tables,
            sourceTableIndex: 2,
            rawAmounts: [100],
            consolidatedSales: 100 * Financial.millionYen
        )
        #expect(resolved.headerToken == nil)
        #expect(resolved.multiplier == Financial.millionYen)
        #expect(resolved.headerLlmMismatch == false)
    }
}
