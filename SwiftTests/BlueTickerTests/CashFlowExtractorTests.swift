// Python tests/test_xbrl_cash_flow.py 相当
// J-GAAP/IFRS 各タグで CFO・CFI を取得できること、タグが存在しない場合は nil を返すことを検証する。

import XCTest
@testable import BlueTicker

final class CashFlowExtractorTests: XCTestCase {

    func testJgaapCfoAndCfi() {
        let fs = makeFieldSet(
            ("NetCashProvidedByUsedInOperatingActivities", 500_000.0, 450_000.0),
            ("NetCashProvidedByUsedInInvestingActivities", -300_000.0, -250_000.0)
        )
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertEqual(result.cfo, 500_000.0)
        XCTAssertEqual(result.cfoPrior, 450_000.0)
        XCTAssertEqual(result.cfi, -300_000.0)
        XCTAssertEqual(result.cfiPrior, -250_000.0)
        XCTAssertEqual(result.accountingStandard, "J-GAAP")
    }

    func testJgaapCfiSpellingVariant() {
        // NetCashProvidedByUsedInInvestmentActivities（表記ゆれ）でも取得できる
        let fs = makeFieldSet(("NetCashProvidedByUsedInInvestmentActivities", -200_000.0, nil))
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertEqual(result.cfi, -200_000.0)
    }

    func testIfrsCfoAndCfi() {
        let fs = makeFieldSet(
            ("CashFlowsFromUsedInOperationsIFRS", 600_000.0, 580_000.0),
            ("CashFlowsUsedInInvestingActivitiesIFRS", -200_000.0, -180_000.0)
        )
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        XCTAssertEqual(result.cfo, 600_000.0)
        XCTAssertEqual(result.cfi, -200_000.0)
        XCTAssertEqual(result.accountingStandard, "IFRS")
    }

    func testNotFoundReturnsNil() {
        let result = CashFlowExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        XCTAssertNil(result.cfo)
        XCTAssertNil(result.cfoPrior)
        XCTAssertNil(result.cfi)
        XCTAssertNil(result.cfiPrior)
    }

    func testCfoFoundCfiMissing() {
        let fs = makeFieldSet(("NetCashProvidedByUsedInOperatingActivities", 500_000.0, nil))
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertEqual(result.cfo, 500_000.0)
        XCTAssertNil(result.cfi)
    }

    func testAccountingStandardPropagated() {
        let fs = makeFieldSet(("CashFlowsFromUsedInOperatingActivitiesIFRS", 100_000.0, nil))
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        XCTAssertEqual(result.accountingStandard, "IFRS")
    }

    func testPriorOnlyWhenCurrentNone() {
        let fs = makeFieldSet(("NetCashProvidedByUsedInOperatingActivities", nil, 450_000.0))
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertNil(result.cfo)
        XCTAssertEqual(result.cfoPrior, 450_000.0)
    }
}
