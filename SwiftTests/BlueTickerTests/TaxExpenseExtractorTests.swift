// 税引前利益・法人税等の抽出と実効税率計算を検証する（J-GAAP / IFRS / US-GAAP HTML）。
// 前期側の値（prior_*）は Swift の TaxExpenseResult に未実装のため検証対象外。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct TaxExpenseExtractorTests {

    private func extract(in dir: URL) -> TaxExpenseResult {
        let (fs, std) = XBRLTestSupport.durationFieldSet(in: dir)
        return TaxExpenseExtractor.extract(fieldSet: fs, accountingStandard: std)
    }

    private func makeUsgaapHtml(_ rows: String) -> String {
        """
        <!DOCTYPE html>
        <html><body>
        <table>
          <tr><th>科目</th><th>前連結会計年度</th><th>当連結会計年度</th></tr>
          \(rows)
        </table>
        </body></html>
        """
    }

    private let usgaapMarkerXml = XBRLTestSupport.makeXbrlDuration("""
        <jpcrp_cor:TotalAssetsUSGAAPSummaryOfBusinessResults
            contextRef="CurrentYearDuration"
            unitRef="JPY" decimals="-6">5000000000000</jpcrp_cor:TotalAssetsUSGAAPSummaryOfBusinessResults>
    """)

    // MARK: - J-GAAP

    @Test func testJgaapComputesEffectiveTaxRateFromPretaxAndTax() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:IncomeBeforeIncomeTaxes contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">100000000000</jppfs_cor:IncomeBeforeIncomeTaxes>
            <jppfs_cor:IncomeBeforeIncomeTaxes contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">90000000000</jppfs_cor:IncomeBeforeIncomeTaxes>
            <jppfs_cor:IncomeTaxes contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">25000000000</jppfs_cor:IncomeTaxes>
            <jppfs_cor:IncomeTaxes contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">22500000000</jppfs_cor:IncomeTaxes>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "computed")
            #expect(result.accountingStandard == "J-GAAP")
            #expect(result.pretaxIncome == 100_000_000_000)
            #expect(result.incomeTax == 25_000_000_000)
            #expect(abs((result.effectiveTaxRate!) - (0.25)) <= (1e-9))
        }
    }

    @Test func testConsolidatedOverNonconsolidated() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:IncomeBeforeIncomeTaxes contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">100000000000</jppfs_cor:IncomeBeforeIncomeTaxes>
            <jppfs_cor:IncomeBeforeIncomeTaxes contextRef="CurrentYearDuration_NonConsolidatedMember"
                unitRef="JPY" decimals="-6">50000000000</jppfs_cor:IncomeBeforeIncomeTaxes>
            <jppfs_cor:IncomeTaxes contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">25000000000</jppfs_cor:IncomeTaxes>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.pretaxIncome == 100_000_000_000)
        }
    }

    @Test func testEffectiveTaxRateZeroPretax() {
        // 税引前利益がゼロの場合、実効税率は nil を返す（ゼロ除算回避）
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:IncomeBeforeIncomeTaxes contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">0</jppfs_cor:IncomeBeforeIncomeTaxes>
            <jppfs_cor:IncomeTaxes contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">1000000000</jppfs_cor:IncomeTaxes>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.effectiveTaxRate == nil)
        }
    }

    // MARK: - IFRS

    @Test func testIfrsComputesEffectiveTaxRateFromPretaxAndTax() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jpifrs_cor:BorrowingsCLIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">200000000000</jpifrs_cor:BorrowingsCLIFRS>
            <jpifrs_cor:ProfitLossBeforeTaxIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">80000000000</jpifrs_cor:ProfitLossBeforeTaxIFRS>
            <jpifrs_cor:ProfitLossBeforeTaxIFRS contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">70000000000</jpifrs_cor:ProfitLossBeforeTaxIFRS>
            <jpifrs_cor:IncomeTaxExpenseIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">20000000000</jpifrs_cor:IncomeTaxExpenseIFRS>
            <jpifrs_cor:IncomeTaxExpenseIFRS contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">17500000000</jpifrs_cor:IncomeTaxExpenseIFRS>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "computed")
            #expect(result.accountingStandard == "IFRS")
            #expect(result.pretaxIncome == 80_000_000_000)
            #expect(result.incomeTax == 20_000_000_000)
            #expect(abs((result.effectiveTaxRate!) - (0.25)) <= (1e-9))
        }
    }

    // MARK: - US-GAAP HTML

    @Test func testAggregateTaxRow() {
        let html = makeUsgaapHtml("""
            <tr><td>税引前当期純利益</td><td>36,000</td><td>38,440</td></tr>
            <tr><td>法人税等合計</td><td>9,000</td><td>8,757</td></tr>
        """)
        XBRLTestSupport.withXbrlDir(usgaapMarkerXml, extraFiles: ["0105010_test_ixbrl.htm": html]) { dir in
            let result = extract(in: dir)
            #expect(result.method == "usgaap_html")
            #expect(result.accountingStandard == "US-GAAP")
            #expect(result.pretaxIncome == 38_440_000_000)
            #expect(result.incomeTax == 8_757_000_000)
            #expect(abs((result.effectiveTaxRate!) - (8757.0 / 38440.0)) <= (1e-4))
        }
    }

    @Test func testSumCurrentDeferredTax() {
        // 法人税等合計がなければ当期税 + 繰延税金を合算する
        let html = makeUsgaapHtml("""
            <tr><td>税引前当期純利益</td><td>36,000</td><td>38,440</td></tr>
            <tr><td>法人税、住民税及び事業税</td><td>8,000</td><td>7,000</td></tr>
            <tr><td>法人税等調整額</td><td>1,000</td><td>1,757</td></tr>
        """)
        XBRLTestSupport.withXbrlDir(usgaapMarkerXml, extraFiles: ["0105010_test_ixbrl.htm": html]) { dir in
            let result = extract(in: dir)
            #expect(result.method == "usgaap_html")
            #expect(result.incomeTax == 8_757_000_000)  // 7000 + 1757
        }
    }

    @Test func testDeltaNotation() {
        // △記法の繰延税金も正しく処理する
        let html = makeUsgaapHtml("""
            <tr><td>税引前当期純利益</td><td>36,000</td><td>38,440</td></tr>
            <tr><td>法人税、住民税及び事業税</td><td>9,000</td><td>9,500</td></tr>
            <tr><td>法人税等調整額</td><td>△500</td><td>△743</td></tr>
        """)
        XBRLTestSupport.withXbrlDir(usgaapMarkerXml, extraFiles: ["0105010_test_ixbrl.htm": html]) { dir in
            let result = extract(in: dir)
            #expect(result.method == "usgaap_html")
            #expect(result.incomeTax == 8_757_000_000)  // 9500 + (-743)
        }
    }

    @Test func testPartialAggregateUsesAggregateCurrent() {
        // 合計行に当期しかない場合も当期値は合計行から取得する
        // （Python は前期を個別成分から補完するが、Swift の TaxExpenseResult は前期未保持）
        let html = makeUsgaapHtml("""
            <tr><td>税引前当期純利益</td><td>36,000</td><td>38,440</td></tr>
            <tr><td>法人税等合計</td><td></td><td>8,757</td></tr>
            <tr><td>法人税、住民税及び事業税</td><td>7,000</td><td>7,500</td></tr>
            <tr><td>法人税等調整額</td><td>1,000</td><td>1,257</td></tr>
        """)
        XBRLTestSupport.withXbrlDir(usgaapMarkerXml, extraFiles: ["0105010_test_ixbrl.htm": html]) { dir in
            let result = extract(in: dir)
            #expect(result.method == "usgaap_html")
            #expect(result.incomeTax == 8_757_000_000)
        }
    }

    @Test func testNoHtmlReturnsNotFound() {
        XBRLTestSupport.withXbrlDir(usgaapMarkerXml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "not_found")
            #expect(result.accountingStandard == "US-GAAP")
            #expect(result.pretaxIncome == nil)
        }
    }

    // MARK: - not_found

    @Test func testNoTagsReturnsNotFound() {
        let xml = XBRLTestSupport.makeXbrlDuration("")
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "not_found")
            #expect(result.pretaxIncome == nil)
            #expect(result.incomeTax == nil)
        }
    }

    @Test func testEmptyDirectory() {
        XBRLTestSupport.withXbrlDir(nil) { dir in
            let result = extract(in: dir)
            #expect(result.method == "not_found")
            #expect(result.pretaxIncome == nil)
        }
    }
}
