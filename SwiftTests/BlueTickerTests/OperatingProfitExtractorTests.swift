// Python tests/test_xbrl_operating_profit.py 相当
// 営業利益の直接取得・GP−SGA 計算・経常利益フォールバック・連結優先を検証する。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct OperatingProfitExtractorTests {

    private func extract(in dir: URL) -> OperatingProfitResult {
        let (fs, std) = XBRLTestSupport.durationFieldSet(in: dir)
        return OperatingProfitExtractor.extract(fieldSet: fs, accountingStandard: std)
    }

    // MARK: - 直接法

    @Test func testJgaapDirectTagReturnsCurrentAndPriorOperatingProfit() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:OperatingIncomeLoss contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">500000000000</jppfs_cor:OperatingIncomeLoss>
            <jppfs_cor:OperatingIncomeLoss contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">450000000000</jppfs_cor:OperatingIncomeLoss>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "direct")
            #expect(result.label == "営業利益")
            #expect(result.accountingStandard == "J-GAAP")
            #expect(result.operatingProfit == 500_000_000_000)
            #expect(result.operatingProfitPrior == 450_000_000_000)
        }
    }

    @Test func testIfrsDirectTagReturnsCurrentAndPriorOperatingProfit() {
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
            #expect(result.method == "direct")
            #expect(result.accountingStandard == "IFRS")
            #expect(result.operatingProfit == 755_816_000_000)
            #expect(result.operatingProfitPrior == 696_000_000_000)
        }
    }

    // MARK: - 計算法（GP − SGA）

    @Test func testComputedIfrsGpMinusSga() {
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
            #expect(result.method == "computed")
            #expect(result.label == "営業利益")
            #expect(result.accountingStandard == "IFRS")
            #expect(result.operatingProfit == gpCurrent - sgaCurrent)
            #expect(result.operatingProfitPrior == gpPrior - sgaPrior)
            #expect(result.sga == sgaCurrent)
            #expect(result.sgaPrior == sgaPrior)
        }
    }

    @Test func testComputedIfrsPriorOnly() {
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
            #expect(result.method == "computed")
            #expect(result.operatingProfit == nil)
            #expect(result.operatingProfitPrior == 500_000_000_000)
        }
    }

    @Test func testComputedPrefersDirectOverGpSga() {
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
            #expect(result.method == "direct")
            #expect(result.operatingProfit == 800_000_000_000)
            #expect(result.sga == 1_500_000_000_000)
        }
    }

    // MARK: - フォールバック

    @Test func testOrdinaryIncomeFallback() {
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
            #expect(result.method == "ordinary_income")
            #expect(result.label == "経常利益")
            #expect(result.operatingProfit == 300_000_000_000)
        }
    }

    @Test func testConsolidatedPreferredOverNonconsolidated() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:OperatingIncomeLoss contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">900000000000</jppfs_cor:OperatingIncomeLoss>
            <jppfs_cor:OperatingIncomeLoss contextRef="CurrentYearDuration_NonConsolidatedMember"
                unitRef="JPY" decimals="-6">100000000000</jppfs_cor:OperatingIncomeLoss>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "direct")
            #expect(result.operatingProfit == 900_000_000_000)
        }
    }

    @Test func testPureContextOverSegmentContext() {
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
            #expect(result.method == "direct")
            #expect(result.operatingProfit == 900_000_000_000)
            #expect(result.operatingProfitPrior == 850_000_000_000)
        }
    }

    @Test func testSingleEntityUsesPlainContext() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:OperatingIncomeLoss contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">150000000000</jppfs_cor:OperatingIncomeLoss>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "direct")
            #expect(result.operatingProfit == 150_000_000_000)
        }
    }

    @Test func testSingleEntityPureContextOverSegmentContext() {
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
            #expect(result.method == "direct")
            #expect(result.operatingProfit == 150_000_000_000)
            #expect(result.operatingProfitPrior == 140_000_000_000)
        }
    }

    @Test func testNotFound() {
        let xml = XBRLTestSupport.makeXbrlDuration("")
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "not_found")
            #expect(result.operatingProfit == nil)
            #expect(result.operatingProfitPrior == nil)
        }
    }
}
