// Python tests/test_xbrl_gross_profit.py 相当
// 損益計算書（Duration コンテキスト）から売上総利益を抽出するロジックを検証する。
// 抽出戦略: 直接法 → 銀行業務粗利益 → 営業総利益 → 計算法（売上高 − 売上原価）

import XCTest
@testable import BlueTicker

final class GrossProfitExtractorTests: XCTestCase {

    private func extract(in dir: URL) -> GrossProfitResult {
        let (fs, std) = XBRLTestSupport.durationFieldSet(in: dir)
        return GrossProfitExtractor.extract(fieldSet: fs, accountingStandard: std, xbrlDir: dir)
    }

    // MARK: - 直接法

    func testDirectTagJgaap() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:GrossProfit contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">120000000000</jppfs_cor:GrossProfit>
            <jppfs_cor:GrossProfit contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">110000000000</jppfs_cor:GrossProfit>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "direct")
            XCTAssertEqual(result.accountingStandard, "J-GAAP")
            XCTAssertEqual(result.grossProfit, 120_000_000_000)
            XCTAssertEqual(result.grossProfitPrior, 110_000_000_000)
        }
    }

    func testDirectTagIfrs() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jpifrs_cor:BorrowingsCLIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">10000000000</jpifrs_cor:BorrowingsCLIFRS>
            <jpifrs_cor:GrossProfitIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">550764000000</jpifrs_cor:GrossProfitIFRS>
            <jpifrs_cor:GrossProfitIFRS contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">520000000000</jpifrs_cor:GrossProfitIFRS>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "direct")
            XCTAssertEqual(result.accountingStandard, "IFRS")
            XCTAssertEqual(result.grossProfit, 550_764_000_000)
            XCTAssertEqual(result.grossProfitPrior, 520_000_000_000)
        }
    }

    // MARK: - 計算法

    func testComputedJgaapNetsalesCostofsales() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:NetSales contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">300000000000</jppfs_cor:NetSales>
            <jppfs_cor:NetSales contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">280000000000</jppfs_cor:NetSales>
            <jppfs_cor:CostOfSales contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">180000000000</jppfs_cor:CostOfSales>
            <jppfs_cor:CostOfSales contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">170000000000</jppfs_cor:CostOfSales>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "computed")
            XCTAssertEqual(result.accountingStandard, "J-GAAP")
            XCTAssertEqual(result.grossProfit, 120_000_000_000)
            XCTAssertEqual(result.grossProfitPrior, 110_000_000_000)
        }
    }

    func testDirectJgaapOperatingGrossProfit() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:OperatingRevenue1 contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">27840047000</jppfs_cor:OperatingRevenue1>
            <jppfs_cor:OperatingRevenue1 contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">26512364000</jppfs_cor:OperatingRevenue1>
            <jppfs_cor:OperatingGrossProfit contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">3320406000</jppfs_cor:OperatingGrossProfit>
            <jppfs_cor:OperatingGrossProfit contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">2932980000</jppfs_cor:OperatingGrossProfit>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "operating_gross_profit")
            XCTAssertEqual(result.grossProfit, 3_320_406_000)
            XCTAssertEqual(result.grossProfitPrior, 2_932_980_000)
            XCTAssertEqual(result.grossProfitLabel, "営業総利益")
        }
    }

    func testComputedJgaapOperatingRevenueOperatingCost() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:OperatingRevenue1 contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">27840047000</jppfs_cor:OperatingRevenue1>
            <jppfs_cor:OperatingCost contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">24519640000</jppfs_cor:OperatingCost>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "computed")
            XCTAssertEqual(result.grossProfit, 3_320_407_000)
        }
    }

    func testComputedIfrsRevenueCostofsales() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jpifrs_cor:BorrowingsCLIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">10000000000</jpifrs_cor:BorrowingsCLIFRS>
            <jpifrs_cor:NetSalesIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">500000000000</jpifrs_cor:NetSalesIFRS>
            <jpifrs_cor:NetSalesIFRS contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">460000000000</jpifrs_cor:NetSalesIFRS>
            <jpifrs_cor:CostOfSalesIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">300000000000</jpifrs_cor:CostOfSalesIFRS>
            <jpifrs_cor:CostOfSalesIFRS contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">280000000000</jpifrs_cor:CostOfSalesIFRS>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "computed")
            XCTAssertEqual(result.accountingStandard, "IFRS")
            XCTAssertEqual(result.grossProfit, 200_000_000_000)
            XCTAssertEqual(result.grossProfitPrior, 180_000_000_000)
        }
    }

    func testComputedNoCogsUsesSalesOnly() {
        // 売上原価タグがない場合、売上高がそのまま売上総利益になる（COGS=0扱い）
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:NetSales contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">100000000000</jppfs_cor:NetSales>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "computed")
            XCTAssertEqual(result.grossProfit, 100_000_000_000)
        }
    }

    // MARK: - 銀行業務粗利益

    func testComputedBankBusinessGrossProfit() {
        // 三菱UFJ 2025年3月期相当
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:OrdinaryIncomeBNK contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">13629997000000</jppfs_cor:OrdinaryIncomeBNK>
            <jppfs_cor:OrdinaryIncomeBNK contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">11890350000000</jppfs_cor:OrdinaryIncomeBNK>
            <jppfs_cor:InterestIncomeOIBNK contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">8467719000000</jppfs_cor:InterestIncomeOIBNK>
            <jppfs_cor:InterestIncomeOIBNK contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">7468679000000</jppfs_cor:InterestIncomeOIBNK>
            <jppfs_cor:InterestExpensesOEBNK contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">5591266000000</jppfs_cor:InterestExpensesOEBNK>
            <jppfs_cor:InterestExpensesOEBNK contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">5011105000000</jppfs_cor:InterestExpensesOEBNK>
            <jppfs_cor:TrustFeesBNK contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">144395000000</jppfs_cor:TrustFeesBNK>
            <jppfs_cor:TrustFeesBNK contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">139363000000</jppfs_cor:TrustFeesBNK>
            <jppfs_cor:FeesAndCommissionsOIBNK contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">2360111000000</jppfs_cor:FeesAndCommissionsOIBNK>
            <jppfs_cor:FeesAndCommissionsOIBNK contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">2047232000000</jppfs_cor:FeesAndCommissionsOIBNK>
            <jppfs_cor:FeesAndCommissionsPaymentsOEBNK contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">414289000000</jppfs_cor:FeesAndCommissionsPaymentsOEBNK>
            <jppfs_cor:FeesAndCommissionsPaymentsOEBNK contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">365940000000</jppfs_cor:FeesAndCommissionsPaymentsOEBNK>
            <jppfs_cor:TradingIncomeOIBNK contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">454258000000</jppfs_cor:TradingIncomeOIBNK>
            <jppfs_cor:TradingIncomeOIBNK contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">368172000000</jppfs_cor:TradingIncomeOIBNK>
            <jppfs_cor:OtherOrdinaryIncomeOIBNK contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">505980000000</jppfs_cor:OtherOrdinaryIncomeOIBNK>
            <jppfs_cor:OtherOrdinaryIncomeOIBNK contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">679329000000</jppfs_cor:OtherOrdinaryIncomeOIBNK>
            <jppfs_cor:OtherOrdinaryExpensesOEBNK contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">1107697000000</jppfs_cor:OtherOrdinaryExpensesOEBNK>
            <jppfs_cor:OtherOrdinaryExpensesOEBNK contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">593515000000</jppfs_cor:OtherOrdinaryExpensesOEBNK>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "business_gross_profit")
            XCTAssertEqual(result.grossProfit, 4_819_211_000_000)
            XCTAssertEqual(result.grossProfitPrior, 4_732_215_000_000)
            XCTAssertEqual(result.grossProfitLabel, "連結業務粗利益")
        }
    }

    func testBankBusinessGrossProfitAllowsTradingIncomeWithoutExpense() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:TradingIncomeOIBNK contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">454258000000</jppfs_cor:TradingIncomeOIBNK>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "business_gross_profit")
            XCTAssertEqual(result.grossProfit, 454_258_000_000)
        }
    }

    func testBankBusinessGrossProfitAllowsTradingExpenseWithoutIncome() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:TradingExpensesOEBNK contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">12000000000</jppfs_cor:TradingExpensesOEBNK>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "business_gross_profit")
            XCTAssertEqual(result.grossProfit, -12_000_000_000)
        }
    }

    // MARK: - 連結優先

    func testConsolidatedOverNonconsolidated() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:GrossProfit contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">200000000000</jppfs_cor:GrossProfit>
            <jppfs_cor:GrossProfit contextRef="CurrentYearDuration_NonConsolidatedMember"
                unitRef="JPY" decimals="-6">50000000000</jppfs_cor:GrossProfit>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "direct")
            XCTAssertEqual(result.grossProfit, 200_000_000_000)
        }
    }

    func testPureContextOverSegmentContext() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:GrossProfit contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">200000000000</jppfs_cor:GrossProfit>
            <jppfs_cor:GrossProfit contextRef="CurrentYearDuration_SomeSegmentMember"
                unitRef="JPY" decimals="-6">50000000000</jppfs_cor:GrossProfit>
            <jppfs_cor:GrossProfit contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">180000000000</jppfs_cor:GrossProfit>
            <jppfs_cor:GrossProfit contextRef="Prior1YearDuration_SomeSegmentMember"
                unitRef="JPY" decimals="-6">45000000000</jppfs_cor:GrossProfit>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "direct")
            XCTAssertEqual(result.grossProfit, 200_000_000_000)
            XCTAssertEqual(result.grossProfitPrior, 180_000_000_000)
        }
    }

    func testSingleEntityUsesPlainContext() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:GrossProfit contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">50000000000</jppfs_cor:GrossProfit>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "direct")
            XCTAssertEqual(result.grossProfit, 50_000_000_000)
        }
    }

    func testSingleEntityPureContextOverSegmentContext() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:GrossProfit contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">50000000000</jppfs_cor:GrossProfit>
            <jppfs_cor:GrossProfit contextRef="CurrentYearDuration_SomeSegmentMember"
                unitRef="JPY" decimals="-6">10000000000</jppfs_cor:GrossProfit>
            <jppfs_cor:GrossProfit contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">45000000000</jppfs_cor:GrossProfit>
            <jppfs_cor:GrossProfit contextRef="Prior1YearDuration_SomeSegmentMember"
                unitRef="JPY" decimals="-6">9000000000</jppfs_cor:GrossProfit>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "direct")
            XCTAssertEqual(result.grossProfit, 50_000_000_000)
            XCTAssertEqual(result.grossProfitPrior, 45_000_000_000)
        }
    }

    // MARK: - not_found

    func testNotFoundEmptyDir() {
        XBRLTestSupport.withXbrlDir(nil) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "not_found")
            XCTAssertNil(result.grossProfit)
            XCTAssertNil(result.grossProfitPrior)
        }
    }

    func testNotFoundNoMatchingTags() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:TotalAssets contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">999000000000</jppfs_cor:TotalAssets>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "not_found")
            XCTAssertNil(result.grossProfit)
        }
    }

    func testUsgaapHtmlGrossProfit() {
        // US-GAAP: 連結損益計算書 HTML から売上総利益を抽出する
        let html = """
        <html><body><table>
          <tr><th></th><th>前連結会計年度</th><th>当連結会計年度</th></tr>
          <tr><td>売上総利益</td><td>1,033,224</td><td>1,137,928</td></tr>
        </table></body></html>
        """
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jpcrp_cor:CashAndCashEquivalentsUSGAAPSummaryOfBusinessResults
                contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">1000000</jpcrp_cor:CashAndCashEquivalentsUSGAAPSummaryOfBusinessResults>
        """)
        XBRLTestSupport.withXbrlDir(xml, extraFiles: ["0105010.htm": html]) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "usgaap_html")
            XCTAssertEqual(result.accountingStandard, "US-GAAP")
            XCTAssertEqual(result.grossProfit, 1_137_928 * Financial.millionYen)
            XCTAssertEqual(result.grossProfitPrior, 1_033_224 * Financial.millionYen)
        }
    }

    func testIfrsTextblockFallbackWhenNoCogsTag() {
        // IFRS Summary型: 売上原価タグが存在しない場合、PL TextBlock から粗利益を抽出する
        // （売上高のみの computed で過大値を返さない）
        let tableHtml = "&lt;table&gt;"
            + "&lt;tr&gt;&lt;td&gt;売上原価&lt;/td&gt;&lt;td&gt;300,000&lt;/td&gt;&lt;td&gt;320,000&lt;/td&gt;&lt;/tr&gt;"
            + "&lt;tr&gt;&lt;td&gt;売上総利益&lt;/td&gt;&lt;td&gt;180,000&lt;/td&gt;&lt;td&gt;200,000&lt;/td&gt;&lt;/tr&gt;"
            + "&lt;/table&gt;"
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jpifrs_cor:NetSalesIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">520000000000</jpifrs_cor:NetSalesIFRS>
            <jpcrp_cor:ConsolidatedStatementOfIncomeIFRSTextBlock
                contextRef="CurrentYearDuration">\(tableHtml)</jpcrp_cor:ConsolidatedStatementOfIncomeIFRSTextBlock>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "ifrs_textblock")
            XCTAssertEqual(result.accountingStandard, "IFRS")
            XCTAssertEqual(result.grossProfit, 200_000 * Financial.millionYen)
            XCTAssertEqual(result.grossProfitPrior, 180_000 * Financial.millionYen)
        }
    }

    func testPriorOnly() {
        // 前期値のみ存在する場合も direct で返す
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:GrossProfit contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">100000000000</jppfs_cor:GrossProfit>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            XCTAssertEqual(result.method, "direct")
            XCTAssertNil(result.grossProfit)
            XCTAssertEqual(result.grossProfitPrior, 100_000_000_000)
        }
    }
}
