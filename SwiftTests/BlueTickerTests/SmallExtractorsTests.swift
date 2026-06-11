// Python tests/test_xbrl_small_extractors.py 相当
// employees / capital_expenditure / research_development を FieldSet ダイレクト構築でテストする。
// net_revenue / share_buyback は Swift 未実装のため対象外（Python 側にのみ存在）。

import XCTest
@testable import BlueTicker

final class SmallExtractorsTests: XCTestCase {

    // MARK: - EmployeesExtractor

    func testEmployeesConsolidatedDirect() {
        let tagElements: XbrlTagElements = [
            "NumberOfEmployees": [
                "CurrentYearInstant": 5000.0,
                "Prior1YearInstant": 4800.0,
            ]
        ]
        let fs = makeFieldSet(("NumberOfEmployees", 5000.0, 4800.0))
        let result = EmployeesExtractor.extract(fieldSet: fs, tagElements: tagElements)
        XCTAssertEqual(result.current, 5000.0)
        XCTAssertEqual(result.prior, 4800.0)
        XCTAssertEqual(result.method, "direct")
    }

    func testEmployeesFallbackToGroupEmployees() {
        let tagElements: XbrlTagElements = [
            "NumberOfGroupEmployees": ["CurrentYearInstant": 3000.0]
        ]
        let fs = makeFieldSet(("NumberOfGroupEmployees", 3000.0, nil))
        let result = EmployeesExtractor.extract(fieldSet: fs, tagElements: tagElements)
        XCTAssertEqual(result.current, 3000.0)
        XCTAssertEqual(result.method, "direct")
    }

    func testEmployeesNotFound() {
        let result = EmployeesExtractor.extract(fieldSet: [:], tagElements: [:])
        XCTAssertNil(result.current)
        XCTAssertEqual(result.method, "not_found")
        XCTAssertEqual(result.scope, "unknown")
    }

    func testEmployeesScopeConsolidatedWhenInstantContext() {
        let tagElements: XbrlTagElements = [
            "NumberOfEmployees": ["CurrentYearInstant": 5000.0]
        ]
        let fs = makeFieldSet(("NumberOfEmployees", 5000.0, nil))
        let result = EmployeesExtractor.extract(fieldSet: fs, tagElements: tagElements)
        XCTAssertEqual(result.scope, "consolidated")
    }

    // MARK: - CapexExtractor

    func testCapexOverviewMethodJgaap() {
        let fs = makeFieldSet(("CapitalExpendituresOverviewOfCapitalExpendituresEtc", 5_000_000.0, 4_000_000.0))
        let result = CapexExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertEqual(result.current, 5_000_000.0)
        XCTAssertEqual(result.method, "overview")
    }

    func testCapexCfInvestingJgaapNegatesValue() {
        // J-GAAP CF は負値で記録 → 正値に変換
        let fs = makeFieldSet(("PurchaseOfPropertyPlantAndEquipmentInvCF", -3_000_000.0, -2_500_000.0))
        let result = CapexExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertEqual(result.current, 3_000_000.0)
        XCTAssertEqual(result.method, "cf_investing")
    }

    func testCapexCfInvestingIfrsNegatesValue() {
        let fs = makeFieldSet(("AcquisitionOfPropertyPlantAndEquipmentInvCFIFRS", -4_000_000.0, nil))
        let result = CapexExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        XCTAssertEqual(result.current, 4_000_000.0)
        XCTAssertEqual(result.method, "cf_investing")
    }

    func testCapexNotFound() {
        let result = CapexExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        XCTAssertNil(result.current)
        XCTAssertEqual(result.method, "not_found")
    }

    // MARK: - RDExtractor

    func testRdCommonTagFound() {
        let fs = makeFieldSet(("ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities", 1_000_000.0, 900_000.0))
        let result = RDExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertEqual(result.current, 1_000_000.0)
    }

    func testRdJgaapFallback() {
        // 共通タグなし → J-GAAP フォールバック
        let fs = makeFieldSet(("ResearchAndDevelopmentExpenses", 800_000.0, 750_000.0))
        let result = RDExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        XCTAssertEqual(result.current, 800_000.0)
    }

    func testRdIfrsFallback() {
        let fs = makeFieldSet(("ResearchAndDevelopmentExpensesIFRS", 600_000.0, nil))
        let result = RDExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        XCTAssertEqual(result.current, 600_000.0)
    }

    func testRdNotFound() {
        let result = RDExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        XCTAssertNil(result.current)
        XCTAssertEqual(result.method, "not_found")
    }
}
