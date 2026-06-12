// Python tests/test_xbrl_small_extractors.py 相当
// employees / capital_expenditure / research_development を FieldSet ダイレクト構築でテストする。
// net_revenue / share_buyback は Swift 未実装のため対象外（Python 側にのみ存在）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct SmallExtractorsTests {

    // MARK: - EmployeesExtractor

    @Test func testEmployeesConsolidatedDirect() {
        let tagElements: XbrlTagElements = [
            "NumberOfEmployees": [
                "CurrentYearInstant": 5000.0,
                "Prior1YearInstant": 4800.0,
            ]
        ]
        let fs = makeFieldSet(("NumberOfEmployees", 5000.0, 4800.0))
        let result = EmployeesExtractor.extract(fieldSet: fs, tagElements: tagElements)
        #expect(result.current == 5000.0)
        #expect(result.prior == 4800.0)
        #expect(result.method == "direct")
    }

    @Test func testEmployeesFallbackToGroupEmployees() {
        let tagElements: XbrlTagElements = [
            "NumberOfGroupEmployees": ["CurrentYearInstant": 3000.0]
        ]
        let fs = makeFieldSet(("NumberOfGroupEmployees", 3000.0, nil))
        let result = EmployeesExtractor.extract(fieldSet: fs, tagElements: tagElements)
        #expect(result.current == 3000.0)
        #expect(result.method == "direct")
    }

    @Test func testEmployeesNotFound() {
        let result = EmployeesExtractor.extract(fieldSet: [:], tagElements: [:])
        #expect(result.current == nil)
        #expect(result.method == "not_found")
        #expect(result.scope == "unknown")
    }

    @Test func testEmployeesScopeConsolidatedWhenInstantContext() {
        let tagElements: XbrlTagElements = [
            "NumberOfEmployees": ["CurrentYearInstant": 5000.0]
        ]
        let fs = makeFieldSet(("NumberOfEmployees", 5000.0, nil))
        let result = EmployeesExtractor.extract(fieldSet: fs, tagElements: tagElements)
        #expect(result.scope == "consolidated")
    }

    // MARK: - CapexExtractor

    @Test func testCapexOverviewMethodJgaap() {
        let fs = makeFieldSet(("CapitalExpendituresOverviewOfCapitalExpendituresEtc", 5_000_000.0, 4_000_000.0))
        let result = CapexExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 5_000_000.0)
        #expect(result.method == "overview")
    }

    @Test func testCapexCfInvestingJgaapNegatesValue() {
        // J-GAAP CF は負値で記録 → 正値に変換
        let fs = makeFieldSet(("PurchaseOfPropertyPlantAndEquipmentInvCF", -3_000_000.0, -2_500_000.0))
        let result = CapexExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 3_000_000.0)
        #expect(result.method == "cf_investing")
    }

    @Test func testCapexCfInvestingIfrsNegatesValue() {
        let fs = makeFieldSet(("AcquisitionOfPropertyPlantAndEquipmentInvCFIFRS", -4_000_000.0, nil))
        let result = CapexExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 4_000_000.0)
        #expect(result.method == "cf_investing")
    }

    @Test func testCapexNotFound() {
        let result = CapexExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        #expect(result.current == nil)
        #expect(result.method == "not_found")
    }

    // MARK: - RDExtractor

    @Test func testRdCommonTagFound() {
        let fs = makeFieldSet(("ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities", 1_000_000.0, 900_000.0))
        let result = RDExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 1_000_000.0)
    }

    @Test func testRdJgaapFallback() {
        // 共通タグなし → J-GAAP フォールバック
        let fs = makeFieldSet(("ResearchAndDevelopmentExpenses", 800_000.0, 750_000.0))
        let result = RDExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 800_000.0)
    }

    @Test func testRdIfrsFallback() {
        let fs = makeFieldSet(("ResearchAndDevelopmentExpensesIFRS", 600_000.0, nil))
        let result = RDExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 600_000.0)
    }

    @Test func testRdNotFound() {
        let result = RDExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        #expect(result.current == nil)
        #expect(result.method == "not_found")
    }
}
