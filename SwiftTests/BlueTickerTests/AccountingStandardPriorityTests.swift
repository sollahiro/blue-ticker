// Python tests/test_xbrl_accounting_standard_priority.py 相当
// IFRS/US-GAAP 要約タグが J-GAAP 要約タグより優先されることを検証する。

import XCTest
@testable import BlueTicker

final class AccountingStandardPriorityTests: XCTestCase {

    private func incomeStatement(_ tagElements: XbrlTagElements) -> (IncomeStatementResult, String) {
        let std = detectAccountingStandard(tagElements)
        let fs = fieldSetFromDuration(tagElements)
        return (IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: std), std)
    }

    private func cashFlow(_ tagElements: XbrlTagElements) -> (CashFlowResult, String) {
        let std = detectAccountingStandard(tagElements)
        let fs = fieldSetFromDuration(tagElements)
        return (CashFlowExtractor.extract(fieldSet: fs, accountingStandard: std), std)
    }

    func testIncomeStatementPrefersIfrsSummaryOverJgaapSummary() {
        let (result, std) = incomeStatement([
            "OperatingRevenuesIFRSKeyFinancialData": ["CurrentYearDuration": 5_825_161_000_000.0],
            "NetSalesSummaryOfBusinessResults": ["CurrentYearDuration": 5_843_087_000_000.0],
            "ProfitLossAttributableToOwnersOfParentIFRSSummaryOfBusinessResults": ["CurrentYearDuration": 416_050_000_000.0],
            "NetIncomeLossSummaryOfBusinessResults": ["CurrentYearDuration": 422_818_000_000.0],
        ])
        XCTAssertEqual(std, "IFRS")
        XCTAssertEqual(result.sales, 5_825_161_000_000.0)
        XCTAssertEqual(result.netProfit, 416_050_000_000.0)
    }

    func testIncomeStatementPrefersConsolidatedRevenueIfrsOverNonconsolidatedRevenue() {
        let (result, std) = incomeStatement([
            "RevenueIFRS": [
                "CurrentYearDuration": 9_783_370_000_000.0,
                "Prior1YearDuration": 9_728_716_000_000.0,
            ],
            "Revenue": [
                "CurrentYearDuration_NonConsolidatedMember": 1_774_233_000_000.0,
                "Prior1YearDuration_NonConsolidatedMember": 1_756_937_000_000.0,
            ],
        ])
        XCTAssertEqual(std, "IFRS")
        XCTAssertEqual(result.sales, 9_783_370_000_000.0)
        XCTAssertEqual(result.salesPrior, 9_728_716_000_000.0)
        XCTAssertEqual(result.salesLabel, "売上収益")
    }

    func testIncomeStatementReadsIfrsRevenueSummaryValues() {
        let (result, std) = incomeStatement([
            "RevenueIFRSSummaryOfBusinessResults": [
                "Prior1YearDuration": 1_091_195_000_000.0,
                "CurrentYearDuration": 1_150_209_000_000.0,
            ],
            "BusinessProfitIFRSSummaryOfBusinessResults": ["CurrentYearDuration": 97_322_000_000.0],
            "ProfitLossAttributableToOwnersOfParentIFRSSummaryOfBusinessResults": ["CurrentYearDuration": 60_741_000_000.0],
        ])
        XCTAssertEqual(std, "IFRS")
        XCTAssertEqual(result.sales, 1_150_209_000_000.0)
        XCTAssertEqual(result.salesPrior, 1_091_195_000_000.0)
        XCTAssertEqual(result.salesLabel, "売上収益")
    }

    func testCashFlowPrefersIfrsSummaryOverJgaapSummary() {
        let (result, std) = cashFlow([
            "CashFlowsFromUsedInOperatingActivitiesIFRSSummaryOfBusinessResults": ["CurrentYearDuration": 669_784_000_000.0],
            "NetCashProvidedByUsedInOperatingActivitiesSummaryOfBusinessResults": ["CurrentYearDuration": 596_949_000_000.0],
            "CashFlowsFromUsedInInvestingActivitiesIFRSSummaryOfBusinessResults": ["CurrentYearDuration": -475_605_000_000.0],
            "NetCashProvidedByUsedInInvestingActivitiesSummaryOfBusinessResults": ["CurrentYearDuration": -419_630_000_000.0],
        ])
        XCTAssertEqual(std, "IFRS")
        XCTAssertEqual(result.cfo, 669_784_000_000.0)
        XCTAssertEqual(result.cfi, -475_605_000_000.0)
    }

    func testIncomeStatementReadsUsgaapSummaryValues() {
        let (result, std) = incomeStatement([
            "RevenuesUSGAAPSummaryOfBusinessResults": ["CurrentYearDuration": 3_195_828_000_000.0],
            "NetIncomeLossAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults": ["CurrentYearDuration": 260_951_000_000.0],
        ])
        XCTAssertEqual(std, "US-GAAP")
        XCTAssertEqual(result.sales, 3_195_828_000_000.0)
        XCTAssertEqual(result.netProfit, 260_951_000_000.0)
    }

    func testIncomeStatementReadsJgaapOperatingRevenueSummary() {
        let (result, std) = incomeStatement([
            "OperatingRevenue1SummaryOfBusinessResults": [
                "Prior1YearDuration": 26_512_000_000.0,
                "CurrentYearDuration": 27_840_000_000.0,
            ],
            "OperatingIncome": ["CurrentYearDuration": 2_189_902_000.0],
            "NetIncomeLossSummaryOfBusinessResults": ["CurrentYearDuration": 1_588_000_000.0],
        ])
        XCTAssertEqual(std, "J-GAAP")
        XCTAssertEqual(result.sales, 27_840_000_000.0)
        XCTAssertEqual(result.salesPrior, 26_512_000_000.0)
        XCTAssertEqual(result.salesLabel, "営業収益")
        XCTAssertEqual(result.operatingProfit, 2_189_902_000.0)
        XCTAssertEqual(result.netProfit, 1_588_000_000.0)
    }

    func testCashFlowReadsUsgaapSummaryValues() {
        let (result, std) = cashFlow([
            "CashFlowsFromUsedInOperatingActivitiesUSGAAPSummaryOfBusinessResults": ["CurrentYearDuration": 428_162_000_000.0],
            "CashFlowsFromUsedInInvestingActivitiesUSGAAPSummaryOfBusinessResults": ["CurrentYearDuration": -541_953_000_000.0],
        ])
        XCTAssertEqual(std, "US-GAAP")
        XCTAssertEqual(result.cfo, 428_162_000_000.0)
        XCTAssertEqual(result.cfi, -541_953_000_000.0)
    }
}
