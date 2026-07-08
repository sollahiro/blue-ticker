import Testing
import Foundation
@testable import BlueTickerCore

// applyOperatingProfitChangeToYears / applyRoicWaterfallToYears / applyRoeWaterfallToYears の数値仕様。
// WaterfallEmptyInputTests が境界（空・単一期）を守るのに対し、本スイートは2期以上での
// 分解値そのもの（補完・各要因効果の値・要因和 = 前年差の整合・ソート順）を固定する。
// 厳密比較する値は2進小数で正確に表現できるもの（0.25 / 0.375 / 0.625 等）を選び、
// 除算を経由して丸めが入りうる値（マージン %）は approx で比較する。

@Suite struct WaterfallDecompositionTests {

    private func entry(
        fyEnd: String,
        sales: Double? = nil, op: Double? = nil, np: Double? = nil,
        grossProfit: Double? = nil, sga: Double? = nil,
        opLabel: String? = nil, salesLabel: String? = nil,
        roic: Double? = nil, nopatMargin: Double? = nil, turnover: Double? = nil,
        roe: Double? = nil, totalAssets: Double? = nil, netAssets: Double? = nil
    ) -> YearEntry {
        var raw = RawData()
        raw.sales = sales
        raw.op = op
        raw.np = np
        raw.salesLabel = salesLabel
        var calc = CalculatedData()
        calc.grossProfit = grossProfit
        calc.sellingGeneralAdministrativeExpenses = sga
        calc.opLabel = opLabel
        calc.roic = roic
        calc.nopatMargin = nopatMargin
        calc.investedCapitalTurnover = turnover
        calc.roe = roe
        calc.totalAssets = totalAssets
        calc.netAssets = netAssets
        return YearEntry(fyEnd: fyEnd, financialPeriod: "FY", rawData: raw, calculatedData: calc)
    }

    private func approx(_ a: Double?, _ b: Double, tolerance: Double = 1e-9) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= tolerance
    }

    // MARK: - 営業利益分解: SGA・BusinessProfit の補完

    @Test func sgaAndBusinessProfitDerivedFromGrossProfitAndOP() {
        var years = [entry(fyEnd: "2024-03-31", sales: 1000, op: 150, grossProfit: 250)]
        applyOperatingProfitChangeToYears(&years)
        let cd = years[0].calculatedData
        #expect(cd.sellingGeneralAdministrativeExpenses == 100)  // GrossProfit 250 − OP 150
        #expect(cd.businessProfit == 150)                        // 250 − SGA 100
        #expect(approx(cd.businessProfitMargin, 15))             // 150 / 1000 × 100
    }

    @Test func financialInstitutionUsesSalesAsProfitBase() {
        // 金融機関（経常利益 × 経常収益）は GrossProfit なしでも Sales を利益ベースに BP を導出する
        var years = [entry(
            fyEnd: "2024-03-31", sales: 1000, sga: 800,
            opLabel: "経常利益", salesLabel: "経常収益")]
        applyOperatingProfitChangeToYears(&years)
        #expect(years[0].calculatedData.businessProfit == 200)  // 1000 − 800
    }

    @Test func businessProfitStaysNilWithoutGrossProfitForNonFinancial() {
        // 一般事業会社は GrossProfit が無いと SGA・BP とも導出できない
        var years = [entry(fyEnd: "2024-03-31", sales: 1000, op: 150)]
        applyOperatingProfitChangeToYears(&years)
        #expect(years[0].calculatedData.sellingGeneralAdministrativeExpenses == nil)
        #expect(years[0].calculatedData.businessProfit == nil)
    }

    // MARK: - 営業利益分解: 前年差の3要因

    @Test func opChangeDecomposesSalesGrowthWithConstantMargin() {
        // 粗利率 0.25 一定・増収: prior BP 150 (SGA 100) → cur BP 180 (SGA 120)
        var years = [
            entry(fyEnd: "2023-03-31", sales: 1000, op: 150, grossProfit: 250),
            entry(fyEnd: "2024-03-31", sales: 1200, op: 180, grossProfit: 300),
        ]
        applyOperatingProfitChangeToYears(&years)
        let cd = years[1].calculatedData
        #expect(cd.businessProfitChange == 30)    // 180 − 150
        #expect(cd.salesChangeImpact == 50)       // (1200−1000) × 0.25
        #expect(cd.grossMarginChangeImpact == 0)  // マージン不変
        #expect(cd.sgaChangeImpact == -20)        // SGA 100 → 120
    }

    @Test func opChangeDecomposesGrossMarginChange() {
        // 売上一定・粗利率 0.25 → 0.375: prior BP 150 (SGA 100) → cur BP 250 (SGA 125)
        var years = [
            entry(fyEnd: "2023-03-31", sales: 1000, op: 150, grossProfit: 250),
            entry(fyEnd: "2024-03-31", sales: 1000, op: 250, grossProfit: 375),
        ]
        applyOperatingProfitChangeToYears(&years)
        let cd = years[1].calculatedData
        #expect(cd.businessProfitChange == 100)     // 250 − 150
        #expect(cd.salesChangeImpact == 0)
        #expect(cd.grossMarginChangeImpact == 125)  // 1000 × (0.375 − 0.25)
        #expect(cd.sgaChangeImpact == -25)          // SGA 100 → 125
    }

    @Test func opChangeFactorsSumToDelta() {
        // 増収 + マージン改善 + SGA 増: 3要因の和が BP 前年差に一致する（分解の完全性）
        var years = [
            entry(fyEnd: "2023-03-31", sales: 1000, op: 150, grossProfit: 250),
            entry(fyEnd: "2024-03-31", sales: 1600, op: 300, grossProfit: 600),
        ]
        applyOperatingProfitChangeToYears(&years)
        let cd = years[1].calculatedData
        #expect(cd.businessProfitChange == 150)    // 300 − 150
        #expect(cd.salesChangeImpact == 150)       // 600 × 0.25
        #expect(cd.grossMarginChangeImpact == 200) // 1600 × (0.375 − 0.25)
        #expect(cd.sgaChangeImpact == -200)        // SGA 100 → 300
        let sum = cd.salesChangeImpact! + cd.grossMarginChangeImpact! + cd.sgaChangeImpact!
        #expect(sum == cd.businessProfitChange!)
    }

    @Test func opChangeSortsByFyEndNotInputOrder() {
        // 入力順が降順でも fyEnd で時系列を組み、差分は新しい期のエントリに載る
        var years = [
            entry(fyEnd: "2024-03-31", sales: 1200, op: 180, grossProfit: 300),
            entry(fyEnd: "2023-03-31", sales: 1000, op: 150, grossProfit: 250),
        ]
        applyOperatingProfitChangeToYears(&years)
        #expect(years[0].calculatedData.businessProfitChange == 30)
        #expect(years[1].calculatedData.businessProfitChange == nil)
    }

    @Test func opChangeSkippedWhenPriorSalesMissing() {
        var years = [
            entry(fyEnd: "2023-03-31", op: 150, grossProfit: 250),
            entry(fyEnd: "2024-03-31", sales: 1200, op: 180, grossProfit: 300),
        ]
        applyOperatingProfitChangeToYears(&years)
        #expect(years[1].calculatedData.businessProfitChange == nil)
    }

    // MARK: - ROIC 前年差の2要因

    @Test func roicDeltaDecomposesIntoMarginAndTurnoverEffects() {
        // NOPATMargin 10→12・回転率 0.75→1.0: ROIC 7.5 → 12
        var years = [
            entry(fyEnd: "2023-03-31", roic: 7.5, nopatMargin: 10, turnover: 0.75),
            entry(fyEnd: "2024-03-31", roic: 12, nopatMargin: 12, turnover: 1.0),
        ]
        applyRoicWaterfallToYears(&years)
        let cd = years[1].calculatedData
        #expect(cd.roicDelta == 4.5)
        #expect(cd.roicMarginEffect == 1.5)   // (12−10) × 0.75
        #expect(cd.roicTurnoverEffect == 3.0) // 12 × (1.0−0.75)
        #expect(cd.roicMarginEffect! + cd.roicTurnoverEffect! == cd.roicDelta!)
    }

    @Test func roicSkipsFinancialInstitutions() {
        // 経常利益ベース（金融機関）の当期は分解しない
        var years = [
            entry(fyEnd: "2023-03-31", roic: 7.5, nopatMargin: 10, turnover: 0.75),
            entry(fyEnd: "2024-03-31", opLabel: "経常利益", roic: 12, nopatMargin: 12, turnover: 1.0),
        ]
        applyRoicWaterfallToYears(&years)
        #expect(years[1].calculatedData.roicDelta == nil)
    }

    @Test func roicDeltaNilWhenPriorComponentMissing() {
        var years = [
            entry(fyEnd: "2023-03-31", roic: 7.5, turnover: 0.75),
            entry(fyEnd: "2024-03-31", roic: 12, nopatMargin: 12, turnover: 1.0),
        ]
        applyRoicWaterfallToYears(&years)
        #expect(years[1].calculatedData.roicDelta == nil)
    }

    // MARK: - ROE: デュポン構成要素の導出

    @Test func roeDerivesDuPontComponents() {
        var years = [entry(
            fyEnd: "2024-03-31", sales: 1000, np: 100, totalAssets: 2000, netAssets: 500)]
        applyRoeWaterfallToYears(&years)
        let cd = years[0].calculatedData
        #expect(approx(cd.netMargin, 10))     // 100/1000 × 100
        #expect(cd.assetTurnover == 0.5)      // 1000/2000
        #expect(cd.financialLeverage == 4)    // 2000/500
    }

    @Test func roeComponentsNilWhenNetAssetsNotPositive() {
        // 債務超過（純資産 ≤ 0）ではレバレッジが意味を成さないため導出しない
        var years = [entry(
            fyEnd: "2024-03-31", sales: 1000, np: 100, totalAssets: 2000, netAssets: -500)]
        applyRoeWaterfallToYears(&years)
        #expect(years[0].calculatedData.netMargin == nil)
        #expect(years[0].calculatedData.financialLeverage == nil)
    }

    // MARK: - ROE 前年差の3要因

    @Test func roeDeltaDecomposesIntoThreeFactors() {
        // 純利益率のみ 10→12（回転率 0.5・レバレッジ 4 は不変）: ROE 20 → 24
        var years = [
            entry(fyEnd: "2023-03-31", sales: 1000, np: 100, roe: 20,
                  totalAssets: 2000, netAssets: 500),
            entry(fyEnd: "2024-03-31", sales: 1000, np: 120, roe: 24,
                  totalAssets: 2000, netAssets: 500),
        ]
        applyRoeWaterfallToYears(&years)
        let cd = years[1].calculatedData
        #expect(cd.roeDelta == 4)
        #expect(approx(cd.roeNetMarginEffect, 4))     // (12−10) × 0.5 × 4
        #expect(approx(cd.roeAssetTurnoverEffect, 0))
        #expect(approx(cd.roeLeverageEffect, 0))
    }

    @Test func roeFactorsSumToDeltaWhenAllFactorsMove() {
        // nm 10→12・at 0.5→0.625・fl 4→3.2: チェーン分解は完全（要因和 = ROE 前年差）
        var years = [
            entry(fyEnd: "2023-03-31", sales: 1000, np: 100, roe: 20,
                  totalAssets: 2000, netAssets: 500),
            entry(fyEnd: "2024-03-31", sales: 1250, np: 150, roe: 24,
                  totalAssets: 2000, netAssets: 625),
        ]
        applyRoeWaterfallToYears(&years)
        let cd = years[1].calculatedData
        #expect(cd.roeDelta == 4)
        let sum = cd.roeNetMarginEffect! + cd.roeAssetTurnoverEffect! + cd.roeLeverageEffect!
        #expect(approx(sum, cd.roeDelta!))
    }
}
