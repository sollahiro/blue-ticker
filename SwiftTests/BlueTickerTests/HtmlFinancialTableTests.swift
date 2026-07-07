import Testing
import Foundation
@testable import BlueTickerCore

// US-GAAP / IFRS の iXBRL HTML テーブル抽出で共有する HtmlFinancialTable
// （Analysis/USGAAPHtmlFields.swift）のヒューリスティクス仕様。
// 前期/当期の列ヘッダー検出（colspan・「第N期」フォールバック含む）、数値セル抽出、
// 最近傍列マッチングは列ズレに弱い箇所なので、ここで挙動を固定する。
// あわせて USGAAPHtml.extractGrossProfit / extractInterestExpense のファイル探索〜
// 列解決〜単位換算（百万円→円）の end-to-end を合成フィクスチャで検証する。

@Suite struct HtmlFinancialTableTests {

    // MARK: - detectColumnIndexes

    @Test func detectsPriorAndCurrentConsolidatedHeaders() throws {
        let rows = try XBRLTestSupport.parseTableRows("""
            <table><tr>
              <td>科目</td><td>前連結会計年度</td><td>当連結会計年度</td>
            </tr></table>
            """)
        let (prior, current) = HtmlFinancialTable.detectColumnIndexes(rows: rows)
        #expect(prior == 1)
        #expect(current == 2)
    }

    @Test func detectColumnIndexesAccountsForColspan() throws {
        // ラベルセルが colspan=2 のとき、後続列のオフセットが 2 から始まる
        let rows = try XBRLTestSupport.parseTableRows("""
            <table><tr>
              <td colspan="2">科目</td><td>前期</td><td>当期</td>
            </tr></table>
            """)
        let (prior, current) = HtmlFinancialTable.detectColumnIndexes(rows: rows)
        #expect(prior == 2)
        #expect(current == 3)
    }

    @Test func fiscalTermHeadersFallBackToOrderedAssignment() throws {
        // 「第N期」形式は最初の出現を前期、次を当期とする
        let rows = try XBRLTestSupport.parseTableRows("""
            <table><tr>
              <td>回次</td><td>第85期</td><td>第86期</td>
            </tr></table>
            """)
        let (prior, current) = HtmlFinancialTable.detectColumnIndexes(rows: rows)
        #expect(prior == 1)
        #expect(current == 2)
    }

    @Test func detectColumnIndexesReturnsNilWithoutHeaderRow() throws {
        let rows = try XBRLTestSupport.parseTableRows("""
            <table><tr><td>売上高</td><td>1,000</td><td>1,200</td></tr></table>
            """)
        let (prior, current) = HtmlFinancialTable.detectColumnIndexes(rows: rows)
        #expect(prior == nil)
        #expect(current == nil)
    }

    @Test func interimHeadersAreDetected() throws {
        let rows = try XBRLTestSupport.parseTableRows("""
            <table><tr>
              <td>科目</td><td>前中間会計期間</td><td>当中間会計期間</td>
            </tr></table>
            """)
        let (prior, current) = HtmlFinancialTable.detectColumnIndexes(rows: rows)
        #expect(prior == 1)
        #expect(current == 2)
    }

    // MARK: - numericCells

    @Test func numericCellsParsesCommaAndTriangleNotation() throws {
        // カンマ区切り・△（負値）・ダッシュ（欠測）・非数値を仕分ける
        let cells = try XBRLTestSupport.parseFirstRowCells("""
            <table><tr>
              <td>売上総利益</td><td>1,234</td><td>―</td><td>△56</td><td>備考</td>
            </tr></table>
            """)
        let numerics = HtmlFinancialTable.numericCells(cells)
        #expect(numerics.map { $0.idx } == [1, 3])
        #expect(numerics.map { $0.value } == [1234, -56])
    }

    @Test func numericCellsSkipsLeadingLabelCellEvenIfNumeric() throws {
        let cells = try XBRLTestSupport.parseFirstRowCells("""
            <table><tr><td>2024</td><td>100</td></tr></table>
            """)
        let numerics = HtmlFinancialTable.numericCells(cells)
        #expect(numerics.map { $0.idx } == [1])
        #expect(numerics.map { $0.value } == [100])
    }

    // MARK: - nearestValue

    @Test func nearestValueReturnsExactColumnMatch() {
        let numerics = [(idx: 1, value: 10.0), (idx: 3, value: 30.0)]
        #expect(HtmlFinancialTable.nearestValue(to: 3, in: numerics) == 30)
        #expect(HtmlFinancialTable.nearestValue(to: 1, in: numerics) == 10)
    }

    @Test func nearestValuePrefersRightSideOnTie() {
        let numerics = [(idx: 1, value: 10.0), (idx: 3, value: 30.0)]
        #expect(HtmlFinancialTable.nearestValue(to: 2, in: numerics) == 30)
    }

    @Test func nearestValueReturnsNilBeyondDistanceTwo() {
        let numerics = [(idx: 6, value: 60.0)]
        #expect(HtmlFinancialTable.nearestValue(to: 3, in: numerics) == nil)
        #expect(HtmlFinancialTable.nearestValue(to: 4, in: numerics) == 60)
    }

    @Test func nearestValueReturnsNilForEmptyInput() {
        #expect(HtmlFinancialTable.nearestValue(to: 1, in: []) == nil)
    }
}

// MARK: - USGAAPHtml end-to-end（合成 0105010 HTML フィクスチャ）

@Suite struct USGAAPHtmlExtractionTests {

    private func makeXbrlDir(statementHtml: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-html-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try statementHtml.write(
            to: dir.appendingPathComponent("0105010_honbun_test.htm"),
            atomically: true, encoding: .utf8)
        return dir
    }

    @Test func extractGrossProfitResolvesColumnsAndConvertsToYen() throws {
        let dir = try makeXbrlDir(statementHtml: """
            <html><body><table>
              <tr><td>科目</td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>売上高</td><td>10,000</td><td>12,000</td></tr>
              <tr><td>売上総利益</td><td>1,000</td><td>1,200</td></tr>
            </table></body></html>
            """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fv = USGAAPHtml.extractGrossProfit(in: dir)
        #expect(fv?.prior == 1_000 * Financial.millionYen)
        #expect(fv?.current == 1_200 * Financial.millionYen)
    }

    @Test func extractGrossProfitReturnsNilWhenLabelAbsent() throws {
        let dir = try makeXbrlDir(statementHtml: """
            <html><body><table>
              <tr><td>売上高</td><td>10,000</td><td>12,000</td></tr>
            </table></body></html>
            """)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(USGAAPHtml.extractGrossProfit(in: dir) == nil)
    }

    @Test func extractInterestExpenseTakesAbsoluteValue() throws {
        // 支払利息は費用側の符号表現（△）に関わらず絶対値（円）で返す
        let dir = try makeXbrlDir(statementHtml: """
            <html><body><table>
              <tr><td>科目</td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>支払利息</td><td>△40</td><td>△50</td></tr>
            </table></body></html>
            """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fv = USGAAPHtml.extractInterestExpense(in: dir)
        #expect(fv?.prior == 40 * Financial.millionYen)
        #expect(fv?.current == 50 * Financial.millionYen)
    }

    @Test func extractInterestExpenseIgnoresReceivedAndAccruedRows() throws {
        // 「受取」を含むラベル（受取利息及び支払利息 等）は支払利息として拾わない
        let dir = try makeXbrlDir(statementHtml: """
            <html><body><table>
              <tr><td>科目</td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>受取利息及び支払利息</td><td>10</td><td>20</td></tr>
            </table></body></html>
            """)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(USGAAPHtml.extractInterestExpense(in: dir) == nil)
    }
}
