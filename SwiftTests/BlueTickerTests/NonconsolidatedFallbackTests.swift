// Python tests/test_xbrl_nonconsolidated_fallback.py 相当
// 単体のみ企業は plain context を使い、連結企業は連結タグ欠落時に単体へフォールバックしない
// （nil を返す）ことを検証する。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct NonconsolidatedFallbackTests {

    /// 連結グループあり企業の最小限 tagElements ベース。
    /// 同一財務タグに「純粋な連結コンテキスト」と「_NonConsolidatedMember コンテキスト」の両方を置く。
    private func consolidatedCompanyBase() -> XbrlTagElements {
        [
            "ProfitLossAttributableToOwnersOfParent": [
                "CurrentYearDuration": 800_000_000.0,
                "CurrentYearDuration_NonConsolidatedMember": 600_000_000.0,
            ]
        ]
    }

    // MARK: - 単体のみ企業: plain context を使う

    @Test func testIncomeStatementSingleEntityUsesPlainContext() {
        let tagElements: XbrlTagElements = [
            "NetSalesSummaryOfBusinessResults": ["CurrentYearDuration": 4_547_599_000.0],
            "OperatingIncomeLoss": ["CurrentYearDuration": -120_634_000.0],
            "NetIncomeLossSummaryOfBusinessResults": ["CurrentYearDuration": 17_478_000.0],
        ]
        let fs = fieldSetFromDuration(tagElements)
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: detectAccountingStandard(tagElements))
        #expect(result.sales == 4_547_599_000.0)
        #expect(result.operatingProfit == -120_634_000.0)
        #expect(result.netProfit == 17_478_000.0)
    }

    @Test func testCashFlowSingleEntityUsesPlainContext() {
        let tagElements: XbrlTagElements = [
            "NetCashProvidedByUsedInOperatingActivities": ["CurrentYearDuration": -482_098_000.0],
            "NetCashProvidedByUsedInInvestmentActivities": ["CurrentYearDuration": -306_697_000.0],
        ]
        let fs = fieldSetFromDuration(tagElements)
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: detectAccountingStandard(tagElements))
        #expect(result.cfo == -482_098_000.0)
        #expect(result.cfi == -306_697_000.0)
    }

    @Test func testBalanceSheetSingleEntityUsesPlainContext() {
        let tagElements: XbrlTagElements = [
            "NetAssets": ["CurrentYearInstant": 4_521_695_000.0],
            "TotalAssetsSummaryOfBusinessResults": ["CurrentYearInstant": 6_705_070_000.0],
        ]
        let fs = fieldSetFromInstant(tagElements)
        let result = BalanceSheetExtractor.extract(fieldSet: fs, accountingStandard: detectAccountingStandard(tagElements))
        #expect(result.totalAssets == 6_705_070_000.0)
        #expect(result.netAssets == 4_521_695_000.0)
    }

    // MARK: - 連結企業: 単体へフォールバックしない

    @Test func testIncomeStatementConsolidatedCompanyBlocksNonconsolidatedFallback() {
        var tagElements = consolidatedCompanyBase()
        tagElements["NetSalesSummaryOfBusinessResults"] = [
            "CurrentYearDuration_NonConsolidatedMember": 4_547_599_000.0
        ]
        let fs = fieldSetFromDuration(tagElements)
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: detectAccountingStandard(tagElements))
        #expect(result.sales == nil)
    }

    @Test func testCashFlowConsolidatedCompanyBlocksNonconsolidatedFallback() {
        var tagElements = consolidatedCompanyBase()
        tagElements["NetCashProvidedByUsedInOperatingActivities"] = [
            "CurrentYearDuration_NonConsolidatedMember": -482_098_000.0
        ]
        let fs = fieldSetFromDuration(tagElements)
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: detectAccountingStandard(tagElements))
        #expect(result.cfo == nil)
        #expect(result.cfi == nil)
    }

    @Test func testBalanceSheetConsolidatedCompanyBlocksNonconsolidatedFallback() {
        var tagElements = consolidatedCompanyBase()
        tagElements["NetAssets"] = [
            "CurrentYearInstant_NonConsolidatedMember": 4_521_695_000.0
        ]
        tagElements["TotalAssets"] = [
            "CurrentYearInstant_NonConsolidatedMember": 6_705_070_000.0
        ]
        let fs = fieldSetFromInstant(tagElements)
        let result = BalanceSheetExtractor.extract(fieldSet: fs, accountingStandard: detectAccountingStandard(tagElements))
        #expect(result.netAssets == nil)
        #expect(result.totalAssets == nil)
    }
}
