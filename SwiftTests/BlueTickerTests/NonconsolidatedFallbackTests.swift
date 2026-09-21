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

    // MARK: - IFRS P&L on NonConsolidatedMember（ベイカレント S100TI4B 型）

    /// IFRS 本表 P&L が純粋な NonConsolidatedMember にだけ載る。CF 等の IFRS タグで
    /// 書類単位ゲートが立っても、sales / OP / NP は NC の値を使う。
    @Test func testIfrsPnLOnNonConsolidatedMemberFillsSummary() {
        let tagElements: XbrlTagElements = [
            "RevenueIFRS": [
                "CurrentYearDuration_NonConsolidatedMember": 93_909_000_000.0,
                "Prior1YearDuration_NonConsolidatedMember": 76_090_000_000.0,
            ],
            "OperatingProfitLossIFRS": [
                "CurrentYearDuration_NonConsolidatedMember": 34_219_000_000.0,
                "Prior1YearDuration_NonConsolidatedMember": 29_916_000_000.0,
            ],
            "ProfitLossIFRS": [
                "CurrentYearDuration_NonConsolidatedMember": 25_382_000_000.0,
                "Prior1YearDuration_NonConsolidatedMember": 21_910_000_000.0,
            ],
            "NetCashProvidedByUsedInOperatingActivitiesIFRS": [
                "CurrentYearDuration_NonConsolidatedMember": 24_348_000_000.0,
            ],
        ]
        let fs = fieldSetFromDuration(
            tagElements, fillMissingIfrsPnLFromNonConsolidated: true)
        #expect(fs["RevenueIFRS"]?.current == 93_909_000_000.0)
        #expect(fs["OperatingProfitLossIFRS"]?.current == 34_219_000_000.0)
        #expect(fs["ProfitLossIFRS"]?.current == 25_382_000_000.0)
        // CF は書類単位ゲートのまま（P&L 限定フォールバック）。
        #expect(fs["NetCashProvidedByUsedInOperatingActivitiesIFRS"]?.current ?? nil == nil)

        let result = IncomeStatementExtractor.extract(
            fieldSet: fs, accountingStandard: detectAccountingStandard(tagElements))
        #expect(result.sales == 93_909_000_000.0)
        #expect(result.operatingProfit == 34_219_000_000.0)
        #expect(result.netProfit == 25_382_000_000.0)
        #expect(result.salesPrior == 76_090_000_000.0)
    }

    /// notes / breakdown が使う既定 FieldSet には NC IFRS P&L を入れない。
    @Test func testIfrsPnLNonConsolidatedFillDoesNotLeakIntoDefaultDurationFieldSet() {
        let tagElements: XbrlTagElements = [
            "RevenueIFRS": [
                "CurrentYearDuration_NonConsolidatedMember": 93_909_000_000.0,
            ],
            "NetCashProvidedByUsedInOperatingActivitiesIFRS": [
                "CurrentYearDuration_NonConsolidatedMember": 24_348_000_000.0,
            ],
        ]
        let notesFS = fieldSetFromDuration(tagElements)
        #expect(notesFS["RevenueIFRS"]?.current ?? nil == nil)
    }

    /// S100VTPA 型: 同じ IFRS タグが plain CurrentYearDuration にあれば従来どおり連結を使う。
    @Test func testIfrsPnLOnPlainCurrentYearDurationStillFills() {
        let tagElements: XbrlTagElements = [
            "RevenueIFRS": [
                "CurrentYearDuration": 116_056_000_000.0,
                "Prior1YearDuration": 93_909_000_000.0,
            ],
            "OperatingProfitLossIFRS": [
                "CurrentYearDuration": 42_615_000_000.0,
                "Prior1YearDuration": 34_219_000_000.0,
            ],
            "ProfitLossIFRS": [
                "CurrentYearDuration": 30_760_000_000.0,
                "Prior1YearDuration": 25_382_000_000.0,
            ],
        ]
        let fs = fieldSetFromDuration(
            tagElements, fillMissingIfrsPnLFromNonConsolidated: true)
        let result = IncomeStatementExtractor.extract(
            fieldSet: fs, accountingStandard: detectAccountingStandard(tagElements))
        #expect(result.sales == 116_056_000_000.0)
        #expect(result.operatingProfit == 42_615_000_000.0)
        #expect(result.netProfit == 30_760_000_000.0)
    }

    /// 同一期に連結と NonConsolidatedMember があるときは連結を残す。
    @Test func testIfrsPnLPrefersConsolidatedOverNonConsolidatedMember() {
        let tagElements: XbrlTagElements = [
            "RevenueIFRS": [
                "CurrentYearDuration": 9_783_370_000_000.0,
                "CurrentYearDuration_NonConsolidatedMember": 1_774_233_000_000.0,
                "Prior1YearDuration": 9_728_716_000_000.0,
                "Prior1YearDuration_NonConsolidatedMember": 1_756_937_000_000.0,
            ],
            "OperatingProfitLossIFRS": [
                "CurrentYearDuration": 800.0,
                "CurrentYearDuration_NonConsolidatedMember": 100.0,
            ],
            "ProfitLossIFRS": [
                "CurrentYearDuration": 500.0,
                "CurrentYearDuration_NonConsolidatedMember": 50.0,
            ],
        ]
        let fs = fieldSetFromDuration(
            tagElements, fillMissingIfrsPnLFromNonConsolidated: true)
        #expect(fs["RevenueIFRS"]?.current == 9_783_370_000_000.0)
        #expect(fs["RevenueIFRS"]?.prior == 9_728_716_000_000.0)
        let result = IncomeStatementExtractor.extract(
            fieldSet: fs, accountingStandard: detectAccountingStandard(tagElements))
        #expect(result.sales == 9_783_370_000_000.0)
        #expect(result.operatingProfit == 800.0)
        #expect(result.netProfit == 500.0)
    }

    /// 連結 `RevenueIFRS` がある期に、優先度の高い `NetSalesIFRS` NC を入れない。
    @Test func testIfrsPnLDoesNotLetNonConsolidatedNetSalesBeatConsolidatedRevenue() {
        let tagElements: XbrlTagElements = [
            "RevenueIFRS": [
                "CurrentYearDuration": 9_783_370_000_000.0,
                "Prior1YearDuration": 9_728_716_000_000.0,
            ],
            "NetSalesIFRS": [
                "CurrentYearDuration_NonConsolidatedMember": 1_774_233_000_000.0,
                "Prior1YearDuration_NonConsolidatedMember": 1_756_937_000_000.0,
            ],
            "OperatingProfitLossIFRS": [
                "CurrentYearDuration": 800.0,
                "CurrentYearDuration_NonConsolidatedMember": 100.0,
            ],
            "ProfitLossAttributableToOwnersOfParentIFRS": [
                "CurrentYearDuration": 500.0,
            ],
            "ProfitLossIFRS": [
                "CurrentYearDuration_NonConsolidatedMember": 50.0,
            ],
        ]
        let fs = fieldSetFromDuration(
            tagElements, fillMissingIfrsPnLFromNonConsolidated: true)
        #expect(fs["RevenueIFRS"]?.current == 9_783_370_000_000.0)
        #expect(fs["NetSalesIFRS"]?.current ?? nil == nil)
        #expect(fs["NetSalesIFRS"]?.prior ?? nil == nil)
        #expect(fs["ProfitLossIFRS"]?.current ?? nil == nil)
        let result = IncomeStatementExtractor.extract(
            fieldSet: fs, accountingStandard: detectAccountingStandard(tagElements))
        #expect(result.sales == 9_783_370_000_000.0)
        #expect(result.operatingProfit == 800.0)
        #expect(result.netProfit == 500.0)
    }

    /// 連結が無い期だけ NonConsolidatedMember を埋める（期ごとの exact match）。
    @Test func testIfrsPnLFillsMissingPeriodOnlyFromNonConsolidatedMember() {
        let tagElements: XbrlTagElements = [
            "RevenueIFRS": [
                "CurrentYearDuration": 116_056_000_000.0,
                "Prior1YearDuration_NonConsolidatedMember": 93_909_000_000.0,
            ]
        ]
        let fs = fieldSetFromDuration(
            tagElements, fillMissingIfrsPnLFromNonConsolidated: true)
        #expect(fs["RevenueIFRS"]?.current == 116_056_000_000.0)
        #expect(fs["RevenueIFRS"]?.prior == 93_909_000_000.0)
    }
}
