// Python tests/test_xbrl_income_statement.py 相当
// J-GAAP/IFRS 各タグで売上高・営業利益・純利益を取得できること、
// ordinary_income フォールバック・salesLabel 付与・not_found を検証する。

import XCTest
@testable import BlueTicker

final class IncomeStatementExtractorTests: XCTestCase {

    func testJgaapBasic() {
        let fs = makeFieldSet(
            ("NetSales", 1_000_000.0, 900_000.0),
            ("OperatingIncomeLoss", 100_000.0, 80_000.0),
            ("ProfitLossAttributableToOwnersOfParent", 60_000.0, 50_000.0)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertEqual(result.sales, 1_000_000.0)
        XCTAssertEqual(result.salesPrior, 900_000.0)
        XCTAssertEqual(result.operatingProfit, 100_000.0)
        XCTAssertEqual(result.operatingProfitPrior, 80_000.0)
        XCTAssertEqual(result.netProfit, 60_000.0)
        XCTAssertEqual(result.netProfitPrior, 50_000.0)
        XCTAssertEqual(result.accountingStandard, "J-GAAP")
    }

    func testOrdinaryIncomeFallbackWhenNoOperatingProfit() {
        let fs = makeFieldSet(
            ("NetSales", 1_000_000.0, nil),
            ("OrdinaryIncome", 90_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertEqual(result.operatingProfit, 90_000.0)
    }

    func testOperatingProfitTakesPrecedenceOverOrdinaryIncome() {
        let fs = makeFieldSet(
            ("OperatingIncomeLoss", 100_000.0, nil),
            ("OrdinaryIncome", 90_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertEqual(result.operatingProfit, 100_000.0)
    }

    func testIfrsTags() {
        let fs = makeFieldSet(
            ("RevenueIFRS", 2_000_000.0, 1_900_000.0),
            ("OperatingProfitLossIFRS", 200_000.0, nil),
            ("ProfitLossAttributableToOwnersOfParentIFRS", 120_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        XCTAssertEqual(result.sales, 2_000_000.0)
        XCTAssertEqual(result.salesLabel, "売上収益")
        XCTAssertEqual(result.operatingProfit, 200_000.0)
        XCTAssertEqual(result.accountingStandard, "IFRS")
    }

    func testSalesLabelOrdinaryRevenue() {
        let fs = makeFieldSet(("OrdinaryIncomeBNK", 500_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertEqual(result.salesLabel, "経常収益")
    }

    func testSalesLabelOperatingRevenue() {
        let fs = makeFieldSet(("OperatingRevenue1SummaryOfBusinessResults", 300_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertEqual(result.salesLabel, "営業収益")
    }

    func testSalesLabelDefaultNetSales() {
        let fs = makeFieldSet(("NetSales", 1_000_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertEqual(result.salesLabel, "売上高")
    }

    func testSalesLabelAbsentWhenSalesNone() {
        let result = IncomeStatementExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        XCTAssertNil(result.salesLabel)
    }

    func testNotFoundAllNone() {
        let result = IncomeStatementExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        XCTAssertNil(result.sales)
        XCTAssertNil(result.operatingProfit)
        XCTAssertNil(result.netProfit)
        XCTAssertEqual(result.method, "not_found")
    }

    func testMethodIncludesFoundFields() {
        let fs = makeFieldSet(
            ("NetSales", 1_000_000.0, nil),
            ("OperatingIncomeLoss", 100_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        let fields = result.method.split(separator: ",").map(String.init)
        XCTAssertTrue(fields.contains("sales"))
        XCTAssertTrue(fields.contains("operating_profit"))
        XCTAssertFalse(fields.contains("net_profit"))
    }

    func testOrdinaryIncomeFallbackBlockedByPriorOnlyOp() {
        // OperatingIncomeLoss が前期のみ存在する場合は経常利益フォールバックを使わない
        let fs = makeFieldSet(
            ("OperatingIncomeLoss", nil, 80_000.0),
            ("OrdinaryIncome", 90_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertNil(result.operatingProfit)
        XCTAssertEqual(result.operatingProfitPrior, 80_000.0)
    }

    func testPriorValuesIncluded() {
        let fs = makeFieldSet(("NetSales", nil, 900_000.0))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertNil(result.sales)
        XCTAssertEqual(result.salesPrior, 900_000.0)
    }
}
