// J-GAAP/IFRS 各タグで売上高・営業利益・純利益を取得できること、
// ordinary_income フォールバック・salesLabel 付与・not_found を検証する。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct IncomeStatementExtractorTests {

    @Test func testJgaapExtractsSalesOperatingProfitAndNetProfit() {
        let fs = makeFieldSet(
            ("NetSales", 1_000_000.0, 900_000.0),
            ("OperatingIncomeLoss", 100_000.0, 80_000.0),
            ("ProfitLossAttributableToOwnersOfParent", 60_000.0, 50_000.0)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 1_000_000.0)
        #expect(result.salesPrior == 900_000.0)
        #expect(result.operatingProfit == 100_000.0)
        #expect(result.operatingProfitPrior == 80_000.0)
        #expect(result.netProfit == 60_000.0)
        #expect(result.netProfitPrior == 50_000.0)
        #expect(result.accountingStandard == "J-GAAP")
    }

    @Test func testOrdinaryIncomeFallbackWhenNoOperatingProfit() {
        let fs = makeFieldSet(
            ("NetSales", 1_000_000.0, nil),
            ("OrdinaryIncome", 90_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.operatingProfit == 90_000.0)
    }

    @Test func testOperatingProfitTakesPrecedenceOverOrdinaryIncome() {
        let fs = makeFieldSet(
            ("OperatingIncomeLoss", 100_000.0, nil),
            ("OrdinaryIncome", 90_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.operatingProfit == 100_000.0)
    }

    @Test func testIfrsTags() {
        let fs = makeFieldSet(
            ("RevenueIFRS", 2_000_000.0, 1_900_000.0),
            ("OperatingProfitLossIFRS", 200_000.0, nil),
            ("ProfitLossAttributableToOwnersOfParentIFRS", 120_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.sales == 2_000_000.0)
        #expect(result.salesLabel == "売上収益")
        #expect(result.operatingProfit == 200_000.0)
        #expect(result.accountingStandard == "IFRS")
    }

    @Test func testSalesLabelOrdinaryRevenue() {
        let fs = makeFieldSet(("OrdinaryIncomeBNK", 500_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.salesLabel == "経常収益")
    }

    @Test func testSalesLabelOperatingRevenue() {
        let fs = makeFieldSet(("OperatingRevenue1SummaryOfBusinessResults", 300_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.salesLabel == "営業収益")
    }

    @Test func testSalesLabelDefaultNetSales() {
        let fs = makeFieldSet(("NetSales", 1_000_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.salesLabel == "売上高")
    }

    @Test func testSalesLabelAbsentWhenSalesNone() {
        let result = IncomeStatementExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        #expect(result.salesLabel == nil)
    }

    @Test func testNotFoundAllNone() {
        let result = IncomeStatementExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        #expect(result.sales == nil)
        #expect(result.operatingProfit == nil)
        #expect(result.netProfit == nil)
        #expect(result.method == "not_found")
    }

    @Test func testMethodIncludesFoundFields() {
        let fs = makeFieldSet(
            ("NetSales", 1_000_000.0, nil),
            ("OperatingIncomeLoss", 100_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        let fields = result.method.split(separator: ",").map(String.init)
        #expect(fields.contains("sales"))
        #expect(fields.contains("operating_profit"))
        #expect(!(fields.contains("net_profit")))
    }

    @Test func testOrdinaryIncomeFallbackBlockedByPriorOnlyOp() {
        // OperatingIncomeLoss が前期のみ存在する場合は経常利益フォールバックを使わない
        let fs = makeFieldSet(
            ("OperatingIncomeLoss", nil, 80_000.0),
            ("OrdinaryIncome", 90_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.operatingProfit == nil)
        #expect(result.operatingProfitPrior == 80_000.0)
    }

    @Test func testPriorValuesIncluded() {
        let fs = makeFieldSet(("NetSales", nil, 900_000.0))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == nil)
        #expect(result.salesPrior == 900_000.0)
    }
}
