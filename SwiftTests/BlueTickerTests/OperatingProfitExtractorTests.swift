// Python tests/test_xbrl_operating_profit.py 相当
// 営業利益の直接取得・GP−SGA 計算・経常利益フォールバック・連結優先を検証する。

import XCTest
@testable import BlueTicker

final class OperatingProfitExtractorTests: XCTestCase {

    private func extract(in dir: URL) -> OperatingProfitResult {
        let (fs, std) = XBRLTestSupport.durationFieldSet(in: dir)
        return OperatingProfitExtractor.extract(fieldSet: fs, accountingStandard: std)
    }

    // MARK: - 直接法

    func testDirectJgaap() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:OperatingIncomeLoss contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">500000000000</jppfs_cor:OperatingIncomeLoss>
            <jppfs_cor:OperatingIncomeLoss contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">450000000000</jppfs_cor:OperatingIncomeLoss>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "direct")
            XCTAssertEqual(result.label, "営業利益")
            XCTAssertEqual(result.accountingStandard, "J-GAAP")
            XCTAssertEqual(result.operatingProfit, 500_000_000_000)
            XCTAssertEqual(result.operatingProfitPrior, 450_000_000_000)
        }
    }

    func testDirectIfrs() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jpifrs_cor:BorrowingsCLIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">100000000000</jpifrs_cor:BorrowingsCLIFRS>
            <jpifrs_cor:OperatingProfitLossIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">755816000000</jpifrs_cor:OperatingProfitLossIFRS>
            <jpifrs_cor:OperatingProfitLossIFRS contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">696000000000</jpifrs_cor:OperatingProfitLossIFRS>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "direct")
            XCTAssertEqual(result.accountingStandard, "IFRS")
            XCTAssertEqual(result.operatingProfit, 755_816_000_000)
            XCTAssertEqual(result.operatingProfitPrior, 696_000_000_000)
        }
    }

    // MARK: - 計算法（GP − SGA）

    func testComputedIfrsGpMinusSga() {
        let gpCurrent = 2_607_357_000_000.0
        let gpPrior = 2_434_185_000_000.0
        let sgaCurrent = 1_851_541_000_000.0
        let sgaPrior = 1_686_041_000_000.0

        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jpifrs_cor:BorrowingsCLIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">100000000000</jpifrs_cor:BorrowingsCLIFRS>
            <jpifrs_cor:GrossProfitIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">\(Int(gpCurrent))</jpifrs_cor:GrossProfitIFRS>
            <jpifrs_cor:GrossProfitIFRS contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">\(Int(gpPrior))</jpifrs_cor:GrossProfitIFRS>
            <jpifrs_cor:SellingGeneralAndAdministrativeExpensesIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">\(Int(sgaCurrent))</jpifrs_cor:SellingGeneralAndAdministrativeExpensesIFRS>
            <jpifrs_cor:SellingGeneralAndAdministrativeExpensesIFRS contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">\(Int(sgaPrior))</jpifrs_cor:SellingGeneralAndAdministrativeExpensesIFRS>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "computed")
            XCTAssertEqual(result.label, "営業利益")
            XCTAssertEqual(result.accountingStandard, "IFRS")
            XCTAssertEqual(result.operatingProfit, gpCurrent - sgaCurrent)
            XCTAssertEqual(result.operatingProfitPrior, gpPrior - sgaPrior)
            XCTAssertEqual(result.sga, sgaCurrent)
            XCTAssertEqual(result.sgaPrior, sgaPrior)
        }
    }

    func testComputedIfrsPriorOnly() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jpifrs_cor:BorrowingsCLIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">100000000000</jpifrs_cor:BorrowingsCLIFRS>
            <jpifrs_cor:GrossProfitIFRS contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">2000000000000</jpifrs_cor:GrossProfitIFRS>
            <jpifrs_cor:SellingGeneralAndAdministrativeExpensesIFRS contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">1500000000000</jpifrs_cor:SellingGeneralAndAdministrativeExpensesIFRS>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "computed")
            XCTAssertNil(result.operatingProfit)
            XCTAssertEqual(result.operatingProfitPrior, 500_000_000_000)
        }
    }

    func testComputedPrefersDirectOverGpSga() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jpifrs_cor:BorrowingsCLIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">100000000000</jpifrs_cor:BorrowingsCLIFRS>
            <jpifrs_cor:OperatingProfitLossIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">800000000000</jpifrs_cor:OperatingProfitLossIFRS>
            <jpifrs_cor:GrossProfitIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">2000000000000</jpifrs_cor:GrossProfitIFRS>
            <jpifrs_cor:SellingGeneralAndAdministrativeExpensesIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">1500000000000</jpifrs_cor:SellingGeneralAndAdministrativeExpensesIFRS>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "direct")
            XCTAssertEqual(result.operatingProfit, 800_000_000_000)
            XCTAssertEqual(result.sga, 1_500_000_000_000)
        }
    }

    // MARK: - フォールバック

    func testOrdinaryIncomeFallback() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:OrdinaryIncomeSummaryOfBusinessResults contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">1200000000000</jppfs_cor:OrdinaryIncomeSummaryOfBusinessResults>
            <jppfs_cor:OrdinaryIncomeSummaryOfBusinessResults contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">1000000000000</jppfs_cor:OrdinaryIncomeSummaryOfBusinessResults>
            <jppfs_cor:OrdinaryIncome contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">300000000000</jppfs_cor:OrdinaryIncome>
            <jppfs_cor:OrdinaryIncome contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">280000000000</jppfs_cor:OrdinaryIncome>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "ordinary_income")
            XCTAssertEqual(result.label, "経常利益")
            XCTAssertEqual(result.operatingProfit, 300_000_000_000)
        }
    }

    func testConsolidatedPreferredOverNonconsolidated() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:OperatingIncomeLoss contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">900000000000</jppfs_cor:OperatingIncomeLoss>
            <jppfs_cor:OperatingIncomeLoss contextRef="CurrentYearDuration_NonConsolidatedMember"
                unitRef="JPY" decimals="-6">100000000000</jppfs_cor:OperatingIncomeLoss>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "direct")
            XCTAssertEqual(result.operatingProfit, 900_000_000_000)
        }
    }

    func testPureContextOverSegmentContext() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:OperatingIncomeLoss contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">900000000000</jppfs_cor:OperatingIncomeLoss>
            <jppfs_cor:OperatingIncomeLoss contextRef="CurrentYearDuration_SomeSegmentMember"
                unitRef="JPY" decimals="-6">100000000000</jppfs_cor:OperatingIncomeLoss>
            <jppfs_cor:OperatingIncomeLoss contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">850000000000</jppfs_cor:OperatingIncomeLoss>
            <jppfs_cor:OperatingIncomeLoss contextRef="Prior1YearDuration_SomeSegmentMember"
                unitRef="JPY" decimals="-6">90000000000</jppfs_cor:OperatingIncomeLoss>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "direct")
            XCTAssertEqual(result.operatingProfit, 900_000_000_000)
            XCTAssertEqual(result.operatingProfitPrior, 850_000_000_000)
        }
    }

    func testSingleEntityUsesPlainContext() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:OperatingIncomeLoss contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">150000000000</jppfs_cor:OperatingIncomeLoss>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "direct")
            XCTAssertEqual(result.operatingProfit, 150_000_000_000)
        }
    }

    func testSingleEntityPureContextOverSegmentContext() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:OperatingIncomeLoss contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">150000000000</jppfs_cor:OperatingIncomeLoss>
            <jppfs_cor:OperatingIncomeLoss contextRef="CurrentYearDuration_SomeSegmentMember"
                unitRef="JPY" decimals="-6">25000000000</jppfs_cor:OperatingIncomeLoss>
            <jppfs_cor:OperatingIncomeLoss contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">140000000000</jppfs_cor:OperatingIncomeLoss>
            <jppfs_cor:OperatingIncomeLoss contextRef="Prior1YearDuration_SomeSegmentMember"
                unitRef="JPY" decimals="-6">20000000000</jppfs_cor:OperatingIncomeLoss>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "direct")
            XCTAssertEqual(result.operatingProfit, 150_000_000_000)
            XCTAssertEqual(result.operatingProfitPrior, 140_000_000_000)
        }
    }

    func testNotFound() {
        let xml = XBRLTestSupport.makeXbrlDuration("")
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "not_found")
            XCTAssertNil(result.operatingProfit)
            XCTAssertNil(result.operatingProfitPrior)
        }
    }
}
