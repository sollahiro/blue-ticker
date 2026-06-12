// Python tests/test_xbrl_interest_bearing_debt.py 相当
// IBDExtractor / IFRSLease.extractLeaseLiabilities の動作を検証する。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct IBDExtractorTests {

    private func extract(in dir: URL) -> IBDResult {
        let (fs, std) = XBRLTestSupport.instantFieldSet(in: dir)
        return IBDExtractor.extract(fieldSet: fs, accountingStandard: std, xbrlDir: dir)
    }

    /// リース注記 TextBlock を含む XBRL を生成する。
    private func makeXbrlWithLeaseTextblock(_ baseElementsXml: String, leaseHtmlRows: String) -> String {
        let leaseHtml = "&lt;table&gt;\(leaseHtmlRows)&lt;/table&gt;"
        return XBRLTestSupport.makeXbrlInstant(baseElementsXml + """

            <jpcrp_cor:NotesLeasesConsolidatedFinancialStatementsIFRSTextBlock
                contextRef="CurrentYearInstant">\(leaseHtml)</jpcrp_cor:NotesLeasesConsolidatedFinancialStatementsIFRSTextBlock>
        """)
    }

    private let ifrsBorrowingsXml = """
        <jppfs_cor:BorrowingsCLIFRS contextRef="CurrentYearInstant"
            unitRef="JPY">5923000000</jppfs_cor:BorrowingsCLIFRS>
        <jppfs_cor:BondsPayableNCLIFRS contextRef="CurrentYearInstant"
            unitRef="JPY">204412000000</jppfs_cor:BondsPayableNCLIFRS>
        <jppfs_cor:BorrowingsNCLIFRS contextRef="CurrentYearInstant"
            unitRef="JPY">211795000000</jppfs_cor:BorrowingsNCLIFRS>
    """

    // MARK: - 直接タグ

    @Test func testDirectTag() {
        let xml = XBRLTestSupport.makeXbrlInstant("""
            <jppfs_cor:InterestBearingDebt contextRef="CurrentYearInstant"
                unitRef="JPY">500000000000</jppfs_cor:InterestBearingDebt>
            <jppfs_cor:InterestBearingDebt contextRef="Prior1YearInstant"
                unitRef="JPY">450000000000</jppfs_cor:InterestBearingDebt>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "field_parser")
            #expect(result.accountingStandard == "J-GAAP")
            #expect(result.total == 500_000_000_000)
            #expect(result.priorTotal == 450_000_000_000)
        }
    }

    // MARK: - J-GAAP コンポーネント積み上げ

    @Test func testAllComponents() {
        let xml = XBRLTestSupport.makeXbrlInstant("""
            <jppfs_cor:ShortTermLoansPayable contextRef="CurrentYearInstant"
                unitRef="JPY">10000000000</jppfs_cor:ShortTermLoansPayable>
            <jppfs_cor:CommercialPapersLiabilities contextRef="CurrentYearInstant"
                unitRef="JPY">5000000000</jppfs_cor:CommercialPapersLiabilities>
            <jppfs_cor:CurrentPortionOfBonds contextRef="CurrentYearInstant"
                unitRef="JPY">3000000000</jppfs_cor:CurrentPortionOfBonds>
            <jppfs_cor:CurrentPortionOfLongTermLoansPayable contextRef="CurrentYearInstant"
                unitRef="JPY">8000000000</jppfs_cor:CurrentPortionOfLongTermLoansPayable>
            <jppfs_cor:BondsPayable contextRef="CurrentYearInstant"
                unitRef="JPY">50000000000</jppfs_cor:BondsPayable>
            <jppfs_cor:LongTermLoansPayable contextRef="CurrentYearInstant"
                unitRef="JPY">30000000000</jppfs_cor:LongTermLoansPayable>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "field_parser")
            #expect(result.accountingStandard == "J-GAAP")
            // 合計: 10+5+3+8+50+30 = 106 十億円
            #expect(result.total == 106_000_000_000)
            let labels = result.components.map(\.label)
            #expect(labels.contains("短期借入金"))
            #expect(labels.contains("コマーシャル・ペーパー"))
            #expect(labels.contains("1年内償還予定の社債"))
            #expect(labels.contains("1年内返済予定の長期借入金"))
            #expect(labels.contains("社債"))
            #expect(labels.contains("長期借入金"))
        }
    }

    // MARK: - IFRS コンポーネント

    @Test func testIfrsTags() {
        let xml = XBRLTestSupport.makeXbrlInstant("""
            <jppfs_cor:BorrowingsCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">5923000000</jppfs_cor:BorrowingsCLIFRS>
            <jppfs_cor:CommercialPapersCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">10000000000</jppfs_cor:CommercialPapersCLIFRS>
            <jppfs_cor:CurrentPortionOfBondsCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">24989000000</jppfs_cor:CurrentPortionOfBondsCLIFRS>
            <jppfs_cor:CurrentPortionOfLongTermBorrowingsCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">8234000000</jppfs_cor:CurrentPortionOfLongTermBorrowingsCLIFRS>
            <jppfs_cor:BondsPayableNCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">204412000000</jppfs_cor:BondsPayableNCLIFRS>
            <jppfs_cor:BorrowingsNCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">211795000000</jppfs_cor:BorrowingsNCLIFRS>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "field_parser")
            #expect(result.accountingStandard == "IFRS")
            // 合計: 5923+10000+24989+8234+204412+211795 = 465353 百万円
            #expect(result.total == 465_353_000_000)
        }
    }

    @Test func testIfrsBondsBorrowingsAndLeaseLiabilitiesTags() {
        // 三菱電機形式: 社債、借入金及びリース負債の流動/非流動集約タグを使う
        let xml = XBRLTestSupport.makeXbrlInstant("""
            <jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesCLIFRS contextRef="Prior1YearInstant"
                unitRef="JPY">151698000000</jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesCLIFRS>
            <jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">120889000000</jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesCLIFRS>
            <jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesNCLIFRS contextRef="Prior1YearInstant"
                unitRef="JPY">242938000000</jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesNCLIFRS>
            <jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesNCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">239772000000</jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesNCLIFRS>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "field_parser")
            #expect(result.accountingStandard == "IFRS")
            #expect(result.total == 360_661_000_000)
            #expect(result.priorTotal == 394_636_000_000)
        }
    }

    // MARK: - 連結優先

    @Test func testConsolidatedOverNonconsolidated() {
        let xml = XBRLTestSupport.makeXbrlInstant("""
            <jppfs_cor:ShortTermLoansPayable contextRef="CurrentYearInstant"
                unitRef="JPY">999000000000</jppfs_cor:ShortTermLoansPayable>
            <jppfs_cor:ShortTermLoansPayable contextRef="CurrentYearInstant_NonConsolidatedMember"
                unitRef="JPY">100000000000</jppfs_cor:ShortTermLoansPayable>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            let comp = result.components.first { $0.label == "短期借入金" }
            #expect(comp?.current == 999_000_000_000)
        }
    }

    @Test func testIfrsTagPreferredOverJgaapNonconsolidated() {
        // IFRS連結タグが J-GAAP 個別タグより優先される。
        // NetAssets を連結・個別両コンテキストに置いて非連結フォールバックを抑止する。
        let xml = XBRLTestSupport.makeXbrlInstant("""
            <jppfs_cor:BorrowingsCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">5923000000</jppfs_cor:BorrowingsCLIFRS>
            <jppfs_cor:ShortTermLoansPayable contextRef="CurrentYearInstant_NonConsolidatedMember"
                unitRef="JPY">116294000000</jppfs_cor:ShortTermLoansPayable>
            <jppfs_cor:NetAssets contextRef="CurrentYearInstant"
                unitRef="JPY">1000000000000</jppfs_cor:NetAssets>
            <jppfs_cor:NetAssets contextRef="CurrentYearInstant_NonConsolidatedMember"
                unitRef="JPY">800000000000</jppfs_cor:NetAssets>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            let comp = result.components.first { $0.label == "短期借入金" }
            #expect(comp?.current == 5_923_000_000)
        }
    }

    // MARK: - not_found

    @Test func testNoDebtTags() {
        let xml = XBRLTestSupport.makeXbrlInstant("""
            <jpcrp_cor:BusinessRisksTextBlock contextRef="CurrentYearInstant">
                テキストのみ
            </jpcrp_cor:BusinessRisksTextBlock>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.method == "not_found")
            #expect(result.total == nil)
        }
    }

    // MARK: - IFRSLease.extractLeaseLiabilities

    @Test func testLeasePatternAClAndNcl() {
        // パターンA: 流動（1年以内）と非流動（1年超）の両方がある場合
        let rows = "&lt;tr&gt;&lt;td&gt;支払期日が1年以内&lt;/td&gt;&lt;td&gt;4,500&lt;/td&gt;&lt;td&gt;5,000&lt;/td&gt;&lt;/tr&gt;"
            + "&lt;tr&gt;&lt;td&gt;支払期日が1年超&lt;/td&gt;&lt;td&gt;28,000&lt;/td&gt;&lt;td&gt;32,000&lt;/td&gt;&lt;/tr&gt;"
        let xml = makeXbrlWithLeaseTextblock(ifrsBorrowingsXml, leaseHtmlRows: rows)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let (fs, _) = XBRLTestSupport.instantFieldSet(in: dir)
            let lease = IFRSLease.extractLeaseLiabilities(fieldSet: fs, xbrlDir: dir)
            #expect(lease.current == 37_000 * Financial.millionYen)
            #expect(lease.prior == 32_500 * Financial.millionYen)
            let labels = lease.components.map(\.label)
            #expect(labels.contains("リース負債（流動）"))
            #expect(labels.contains("リース負債（非流動）"))
        }
    }

    @Test func testLeasePatternBBookValue() {
        // パターンB: 「帳簿価額」行のみある場合
        let rows = "&lt;tr&gt;&lt;td&gt;帳簿価額&lt;/td&gt;&lt;td&gt;28,500&lt;/td&gt;&lt;td&gt;32,539&lt;/td&gt;&lt;/tr&gt;"
        let xml = makeXbrlWithLeaseTextblock(ifrsBorrowingsXml, leaseHtmlRows: rows)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let (fs, _) = XBRLTestSupport.instantFieldSet(in: dir)
            let lease = IFRSLease.extractLeaseLiabilities(fieldSet: fs, xbrlDir: dir)
            #expect(lease.current == 32_539 * Financial.millionYen)
            #expect(lease.prior == 28_500 * Financial.millionYen)
            #expect(lease.components.count == 1)
            #expect(lease.components.first?.label == "リース負債")
        }
    }

    @Test func testLeaseNoMatchingRowsReturnsNil() {
        let rows = "&lt;tr&gt;&lt;td&gt;減価償却費&lt;/td&gt;&lt;td&gt;1,000&lt;/td&gt;&lt;td&gt;1,200&lt;/td&gt;&lt;/tr&gt;"
        let xml = makeXbrlWithLeaseTextblock(ifrsBorrowingsXml, leaseHtmlRows: rows)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let (fs, _) = XBRLTestSupport.instantFieldSet(in: dir)
            let lease = IFRSLease.extractLeaseLiabilities(fieldSet: fs, xbrlDir: dir)
            #expect(lease.current == nil)
            #expect(lease.prior == nil)
            #expect(lease.components.isEmpty)
        }
    }

    @Test func testLeaseNoTextblockReturnsNil() {
        let xml = XBRLTestSupport.makeXbrlInstant(ifrsBorrowingsXml)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let (fs, _) = XBRLTestSupport.instantFieldSet(in: dir)
            let lease = IFRSLease.extractLeaseLiabilities(fieldSet: fs, xbrlDir: dir)
            #expect(lease.current == nil)
            #expect(lease.prior == nil)
            #expect(lease.components.isEmpty)
        }
    }

    // MARK: - リース負債の IBD 加算

    @Test func testLeaseAddedToIfrsIbd() {
        // IFRSで借入金タグ + リース注記が両方ある場合、リース負債が加算される
        let rows = "&lt;tr&gt;&lt;td&gt;支払期日が1年以内&lt;/td&gt;&lt;td&gt;4,000&lt;/td&gt;&lt;td&gt;5,000&lt;/td&gt;&lt;/tr&gt;"
            + "&lt;tr&gt;&lt;td&gt;支払期日が1年超&lt;/td&gt;&lt;td&gt;28,000&lt;/td&gt;&lt;td&gt;32,000&lt;/td&gt;&lt;/tr&gt;"
        let xml = makeXbrlWithLeaseTextblock(ifrsBorrowingsXml, leaseHtmlRows: rows)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            // 借入金合計: 5923+204412+211795 = 422130 百万円、リース負債: 5000+32000 = 37000 百万円
            #expect(result.method.contains("lease_textblock"))
            #expect(result.total == (422_130 + 37_000) * Financial.millionYen)
            let labels = result.components.map(\.label)
            #expect(labels.contains("リース負債（流動）"))
            #expect(labels.contains("リース負債（非流動）"))
        }
    }

    @Test func testJgaapLeaseNotAdded() {
        // J-GAAPではリース注記があってもリース負債は加算されない
        let rows = "&lt;tr&gt;&lt;td&gt;支払期日が1年以内&lt;/td&gt;&lt;td&gt;4,000&lt;/td&gt;&lt;td&gt;5,000&lt;/td&gt;&lt;/tr&gt;"
        let jgaapXml = """
            <jppfs_cor:ShortTermLoansPayable contextRef="CurrentYearInstant"
                unitRef="JPY">10000000000</jppfs_cor:ShortTermLoansPayable>
            <jppfs_cor:LongTermLoansPayable contextRef="CurrentYearInstant"
                unitRef="JPY">50000000000</jppfs_cor:LongTermLoansPayable>
        """
        let xml = makeXbrlWithLeaseTextblock(jgaapXml, leaseHtmlRows: rows)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(!(result.method.contains("lease_textblock")))
            #expect(result.total == 60_000_000_000)
        }
    }
}
