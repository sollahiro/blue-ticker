// US-GAAP 借入金等明細（巨大注記 HTML）の表形状テスト。
// 実データ回帰は StatementNotesOracleFormatTests（富士フイルム S100W3XJ / キヤノン S100XTLJ）。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct BorrowingsScheduleUSGAAPTests {

    @Test
    func fujifilmShapedTablesSkipCurrentPortionAndAggregateBonds() throws {
        let html = """
        <p><span>９　短期の社債及び借入金・長期の社債及び借入金</span></p>
        <table>
          <tr><td></td><td>前連結会計年度末 (百万円)</td><td></td><td>当連結会計年度末 (百万円)</td></tr>
          <tr><td>短期借入金</td><td>235,030</td><td></td><td>97,926</td></tr>
          <tr><td>コマーシャル・ペーパー</td><td>－</td><td></td><td>50,000</td></tr>
          <tr><td>１年以内返済の社債及び長期借入金</td><td>82,073</td><td></td><td>67,177</td></tr>
          <tr><td>合計</td><td>317,103</td><td></td><td>215,103</td></tr>
        </table>
        <table>
          <tr><td></td><td>前連結会計年度末 (百万円)</td><td></td><td>当連結会計年度末 (百万円)</td></tr>
          <tr><td>銀行及び保険会社等からの無担保借入金</td><td></td><td></td><td></td></tr>
          <tr><td>前連結会計年度：返済期限 2025年度～2026年度 年利率0.300％～4.000％</td>
              <td>25,439</td><td></td><td>175,342</td></tr>
          <tr><td>無担保社債(円建)</td><td></td><td></td><td></td></tr>
          <tr><td>返済期限 2024年度 年利率0.080%</td><td>30,000</td><td></td><td>－</td></tr>
          <tr><td>返済期限 2025年度 年利率0.100%</td><td>40,000</td><td></td><td>40,000</td></tr>
          <tr><td>その他</td><td>7,350</td><td></td><td>7,640</td></tr>
          <tr><td></td><td>267,789</td><td></td><td>537,982</td></tr>
          <tr><td>控除：１年以内に返済期限が到来する金額</td><td>△82,073</td><td></td><td>△67,177</td></tr>
          <tr><td>差引計</td><td>185,716</td><td></td><td>470,805</td></tr>
        </table>
        <p><span>１０　退職給付制度</span></p>
        """
        let parsed = try #require(BorrowingsSchedule.parseUSGAAPNotesHtml(html))
        #expect(parsed.rows.map(\.label) == [
            "短期借入金", "コマーシャル・ペーパー",
            "銀行及び保険会社等からの無担保借入金", "無担保社債(円建)", "その他",
        ])
        #expect(parsed.rows[1].prior == nil)
        #expect(parsed.rows[1].current == 50_000 * Financial.millionYen)
        #expect(parsed.rows[3].prior == 70_000 * Financial.millionYen)
        #expect(parsed.rows[3].current == 40_000 * Financial.millionYen)
        #expect(parsed.rows[3].averageInterestRatePercent == nil)
        #expect(parsed.totalCurrent == 370_908 * Financial.millionYen)
        #expect(parsed.totalPrior == 337_819 * Financial.millionYen)
    }

    @Test
    func canonShapedProseAndColspanTableExtractsShortTermAndBankBorrowings() throws {
        let html = """
        <p>注９　短期借入金及び長期債務</p>
        <p>金融サービスに係る短期借入金は、当社が保有するリース子会社において、顧客に対する融資をファイナンスするための銀行借入であります。2024年及び2025年12月31日現在における銀行借入による金融サービスに係る短期借入金は、それぞれ40,400百万円、38,100百万円であり、その他の銀行借入による短期借入金は276,106百万円、371,112百万円であります。</p>
        <p>2024年及び2025年12月31日現在における長期債務は以下のとおりであります。</p>
        <table>
          <tr>
            <td></td><td></td>
            <td>第124期 2024年12月31日</td><td></td>
            <td>第125期 2025年12月31日</td>
          </tr>
          <tr>
            <td colspan="2">銀行借入; 銀行利率1.04％（2025年12月31日時点）*1</td>
            <td>201,909</td><td></td><td>401,699</td>
          </tr>
          <tr>
            <td>その他の債務*2</td><td></td>
            <td>4,990</td><td></td><td>5,199</td>
          </tr>
          <tr>
            <td></td><td></td>
            <td>206,899</td><td></td><td>406,898</td>
          </tr>
          <tr>
            <td>１年以内に返済する長期債務</td><td></td>
            <td>△1,824</td><td></td><td>△101,928</td>
          </tr>
          <tr>
            <td>合計</td><td></td>
            <td>205,075</td><td></td><td>304,970</td>
          </tr>
        </table>
        <p>注10　買入債務</p>
        """
        let parsed = try #require(BorrowingsSchedule.parseUSGAAPNotesHtml(html))
        #expect(parsed.rows.map(\.label) == [
            "金融サービスに係る短期借入金",
            "その他の銀行借入による短期借入金",
            "銀行借入",
            "その他の債務",
        ])
        #expect(parsed.rows[2].averageInterestRatePercent == 1.04)
        #expect(parsed.totalPrior == 523_405 * Financial.millionYen)
        #expect(parsed.totalCurrent == 816_110 * Financial.millionYen)
    }
}
