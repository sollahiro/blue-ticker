// 支払利息の抽出を検証する（J-GAAP / IFRS / IFRS注記テキスト / US-GAAP HTML）。
// （XMLParsedAsHTMLWarning 抑止テストは bs4 固有のため対象外）

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct InterestExpenseExtractorTests {

    private func extract(in dir: URL) -> InterestExpenseResult {
        let (fs, std) = XBRLTestSupport.durationFieldSet(in: dir)
        return InterestExpenseExtractor.extract(fieldSet: fs, accountingStandard: std, xbrlDir: dir)
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

    @Test func testDirectJgaap() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:InterestExpensesNOE contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">8752000000</jppfs_cor:InterestExpensesNOE>
            <jppfs_cor:InterestExpensesNOE contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">9000000000</jppfs_cor:InterestExpensesNOE>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "direct")
            #expect(result.accountingStandard == "J-GAAP")
            #expect(result.current == 8_752_000_000)
            #expect(result.prior == 9_000_000_000)
        }
    }

    @Test func testConsolidatedOverNonconsolidated() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:InterestExpensesNOE contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">8752000000</jppfs_cor:InterestExpensesNOE>
            <jppfs_cor:InterestExpensesNOE contextRef="CurrentYearDuration_NonConsolidatedMember"
                unitRef="JPY" decimals="-6">1000000000</jppfs_cor:InterestExpensesNOE>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.current == 8_752_000_000)
        }
    }

    @Test func testNonconsolidatedFallback() {
        // 連結値がなければ個別値にフォールバックする
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jppfs_cor:InterestExpensesNOE contextRef="CurrentYearDuration_NonConsolidatedMember"
                unitRef="JPY" decimals="-6">1000000000</jppfs_cor:InterestExpensesNOE>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "direct")
            #expect(result.current == 1_000_000_000)
        }
    }

    // MARK: - IFRS

    @Test func testInterestExpensesIfrs() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jpifrs_cor:BorrowingsCLIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">100000000000</jpifrs_cor:BorrowingsCLIFRS>
            <jpifrs_cor:InterestExpensesIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">5000000000</jpifrs_cor:InterestExpensesIFRS>
            <jpifrs_cor:InterestExpensesIFRS contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">4800000000</jpifrs_cor:InterestExpensesIFRS>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "direct")
            #expect(result.accountingStandard == "IFRS")
            #expect(result.current == 5_000_000_000)
            #expect(result.prior == 4_800_000_000)
        }
    }

    @Test func testFinanceCostsIfrsFallback() {
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jpifrs_cor:BorrowingsCLIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">100000000000</jpifrs_cor:BorrowingsCLIFRS>
            <jpifrs_cor:FinanceCostsIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">6000000000</jpifrs_cor:FinanceCostsIFRS>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "direct")
            #expect(result.accountingStandard == "IFRS")
            #expect(result.current == 6_000_000_000)
        }
    }

    @Test func testInterestExpenseNoteTextblockFallback() {
        // IFRS: numeric タグがない場合、支払利息注記のテキストから取得する（トヨタ型）
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jpifrs_cor:BorrowingsCLIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">100000000000</jpifrs_cor:BorrowingsCLIFRS>
        """)
        let html = """
            <html><body>
            <h4>（５）支払利息</h4>
            <p>2024年３月31日および2025年３月31日に終了した各１年間における支払利息は、
            それぞれ<span>1,213,021百万円</span>および<span>1,654,702百万円</span>です。</p>
            </body></html>
        """
        XBRLTestSupport.withXbrlDir(xml, extraFiles: ["note_ixbrl.htm": html]) { dir in
            let result = extract(in: dir)
            #expect(result.method == "ifrs_textblock")
            #expect(result.accountingStandard == "IFRS")
            #expect(result.prior == 1_213_021_000_000)
            #expect(result.current == 1_654_702_000_000)
        }
    }

    @Test func testInterestExpenseXbrlTextblock() {
        // XBRLファイル内のテキストブロックからも取得できる
        let xml = XBRLTestSupport.makeXbrlDuration("""
            <jpifrs_cor:BorrowingsCLIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">100000000000</jpifrs_cor:BorrowingsCLIFRS>
            <jpcrp_cor:NotesFinancialInstrumentsIFRSTextBlock contextRef="CurrentYearDuration">
                2024年３月31日および2025年３月31日に終了した各１年間における支払利息は、
                それぞれ1,213,021百万円および1,654,702百万円です。
            </jpcrp_cor:NotesFinancialInstrumentsIFRSTextBlock>
        """)
        XBRLTestSupport.withXbrlDir(nil, extraFiles: ["instance.xbrl": xml]) { dir in
            let result = extract(in: dir)
            #expect(result.method == "ifrs_textblock")
            #expect(result.prior == 1_213_021_000_000)
            #expect(result.current == 1_654_702_000_000)
        }
    }

    // MARK: - US-GAAP HTML

    @Test func testExtractsPositiveValues() {
        let html = makeUsgaapHtml("""
            <tr><td>支払利息</td><td>9,000</td><td>8,752</td></tr>
        """)
        XBRLTestSupport.withXbrlDir(usgaapMarkerXml, extraFiles: ["0105010_test_ixbrl.htm": html]) { dir in
            let result = extract(in: dir)
            #expect(result.method == "usgaap_html")
            #expect(result.accountingStandard == "US-GAAP")
            #expect(result.current == 8_752_000_000)
            #expect(result.prior == 9_000_000_000)
        }
    }

    @Test func testExtractsDeltaNotation() {
        // △記法（負数）の支払利息も絶対値で返す
        let html = makeUsgaapHtml("""
            <tr><td>支払利息</td><td>△9,000</td><td>△8,752</td></tr>
        """)
        XBRLTestSupport.withXbrlDir(usgaapMarkerXml, extraFiles: ["0105010_test_ixbrl.htm": html]) { dir in
            let result = extract(in: dir)
            #expect(result.method == "usgaap_html")
            #expect(result.current == 8_752_000_000)
            #expect(result.prior == 9_000_000_000)
        }
    }

    @Test func testNoHtmlFileReturnsNotFound() {
        XBRLTestSupport.withXbrlDir(usgaapMarkerXml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "not_found")
            #expect(result.accountingStandard == "US-GAAP")
            #expect(result.current == nil)
        }
    }

    // MARK: - not_found

    @Test func testNoTagsReturnsNotFound() {
        let xml = XBRLTestSupport.makeXbrlDuration("")
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "not_found")
            #expect(result.current == nil)
            #expect(result.prior == nil)
        }
    }

    @Test func testEmptyDirectory() {
        XBRLTestSupport.withXbrlDir(nil) { dir in
            let result = extract(in: dir)
            #expect(result.method == "not_found")
            #expect(result.current == nil)
        }
    }
}
