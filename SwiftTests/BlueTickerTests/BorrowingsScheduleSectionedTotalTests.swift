// 流動／非流動の区分見出しごとに「合計」を置く有利子負債注記の表合計（BorrowingsSchedule.parseComparisonTable）。
// 実データ回帰は RealXbrlInterestBearingDebtBreakdownTests（東静 S100XMC1）。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct BorrowingsScheduleSectionedTotalTests {
    private func table(_ body: String) -> String {
        """
        <table>
          <tr><td></td><td>前連結会計年度 (百万円)</td><td>当連結会計年度 (百万円)</td><td>平均利率(％)</td></tr>
          \(body)
        </table>
        """
    }

    private let m = Financial.millionYen

    /// 東静型: 流動 → 小計、非流動 → 小計。表の合計は区分小計の和。
    @Test func perSectionSubtotalsSumToTableTotal() throws {
        let parsed = try #require(BorrowingsSchedule.parseComparisonTableHtml(table("""
          <tr><td>流動負債</td><td></td><td></td><td></td></tr>
          <tr><td>短期借入金</td><td>10</td><td>11</td><td>1.0</td></tr>
          <tr><td>リース負債</td><td>2</td><td>3</td><td>1.0</td></tr>
          <tr><td>合計</td><td>12</td><td>14</td><td></td></tr>
          <tr><td>非流動負債</td><td></td><td></td><td></td></tr>
          <tr><td>長期借入金</td><td>100</td><td>110</td><td>1.0</td></tr>
          <tr><td>リース負債</td><td>20</td><td>30</td><td>1.0</td></tr>
          <tr><td>合計</td><td>120</td><td>140</td><td></td></tr>
        """)))
        #expect(parsed.rows.count == 4)
        #expect(parsed.totalCurrent == 154 * m)
        #expect(parsed.totalPrior == 132 * m)
        #expect(parsed.rows.map(\.label) == ["短期借入金", "リース負債（流動）", "長期借入金", "リース負債（非流動）"])
    }

    /// 累計型: 流動 → 小計(A+B)、非流動 → 合計(A+B+C+D)（非流動の小計は無い）。区分小計の和
    /// (A+B)+(A+B+C+D) は流動分を二重に数えるので使わず、内訳と一致する最後の「合計」を使う。
    @Test func cumulativeLastTotalIsNotAddedToCurrentSubtotal() throws {
        let parsed = try #require(BorrowingsSchedule.parseComparisonTableHtml(table("""
          <tr><td>流動負債</td><td></td><td></td><td></td></tr>
          <tr><td>短期借入金</td><td>10</td><td>11</td><td>1.0</td></tr>
          <tr><td>リース負債</td><td>2</td><td>3</td><td>1.0</td></tr>
          <tr><td>合計</td><td>12</td><td>14</td><td></td></tr>
          <tr><td>非流動負債</td><td></td><td></td><td></td></tr>
          <tr><td>長期借入金</td><td>100</td><td>110</td><td>1.0</td></tr>
          <tr><td>リース負債</td><td>20</td><td>30</td><td>1.0</td></tr>
          <tr><td>合計</td><td>132</td><td>154</td><td></td></tr>
        """)))
        #expect(parsed.rows.count == 4)
        #expect(parsed.totalCurrent == 154 * m)
        #expect(parsed.totalPrior == 132 * m)
    }

    /// 区分小計の後に真の合計行がある表は、内訳と一致すればそれを使う。
    @Test func trailingTrueTotalAfterSectionsIsUsed() throws {
        let parsed = try #require(BorrowingsSchedule.parseComparisonTableHtml(table("""
          <tr><td>流動負債</td><td></td><td></td><td></td></tr>
          <tr><td>短期借入金</td><td>10</td><td>11</td><td>1.0</td></tr>
          <tr><td>合計</td><td>10</td><td>11</td><td></td></tr>
          <tr><td>非流動負債</td><td></td><td></td><td></td></tr>
          <tr><td>長期借入金</td><td>100</td><td>110</td><td>1.0</td></tr>
          <tr><td>合計</td><td>100</td><td>110</td><td></td></tr>
          <tr><td>合計</td><td>110</td><td>121</td><td></td></tr>
        """)))
        #expect(parsed.rows.count == 2)
        #expect(parsed.totalCurrent == 121 * m)
        #expect(parsed.totalPrior == 110 * m)
    }

    /// どの候補も内訳と一致しなければ内訳の和。
    @Test func unreconciledCandidatesFallBackToComponentSum() {
        let total = BorrowingsSchedule.reconciledSectionedTotal(
            subtotals: [14, 999], trailing: nil, components: [11, 3, 110, 30], scale: 1)
        #expect(total == 154)
        // 端数（表示単位の丸め）は許容
        let rounded = BorrowingsSchedule.reconciledSectionedTotal(
            subtotals: [14, 141], trailing: nil, components: [11, 3, 110, 30], scale: 1)
        #expect(rounded == 155)
        // 内訳に値が無ければ区分小計の和
        #expect(BorrowingsSchedule.reconciledSectionedTotal(
            subtotals: [14, 140], trailing: nil, components: [nil], scale: 1) == 154)
    }
}
