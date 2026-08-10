// US-GAAP Statement HTML 抽出の最小フィクスチャテスト。
// 実データ回帰は RealXbrlStatementTests（富士フイルム / キヤノン）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct USGAAPStatementHtmlTests {

    @Test
    func extractsBalanceSheetIncomeAndCashFlowFromMinimalHtml() throws {
        let html = """
        <html><body>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額(百万円)</td><td>金額(百万円)</td></tr>
          <tr><td>資産の部</td><td></td><td></td><td></td></tr>
          <tr><td>１ 現金及び現金同等物</td><td></td><td>100</td><td>200</td></tr>
          <tr><td>流動資産合計</td><td></td><td>100</td><td>200</td></tr>
          <tr><td>資産合計</td><td></td><td>500</td><td>800</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額(百万円)</td><td>金額(百万円)</td></tr>
          <tr><td>負債の部</td><td></td><td></td><td></td></tr>
          <tr><td>流動負債合計</td><td></td><td>50</td><td>60</td></tr>
          <tr><td>負債合計</td><td></td><td>50</td><td>60</td></tr>
          <tr><td>純資産の部</td><td></td><td></td><td></td></tr>
          <tr><td>Ⅰ 株主資本</td><td></td><td></td><td></td></tr>
          <tr><td>１ 資本金</td><td></td><td>400</td><td>700</td></tr>
          <tr><td>純資産合計</td><td></td><td>450</td><td>740</td></tr>
          <tr><td>負債・純資産合計</td><td></td><td>500</td><td>800</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額(百万円)</td><td>金額(百万円)</td></tr>
          <tr><td>Ⅰ 売上高</td><td></td><td>1,000</td><td>1,200</td></tr>
          <tr><td>Ⅱ 売上原価</td><td></td><td>600</td><td>700</td></tr>
          <tr><td>売上総利益</td><td></td><td>400</td><td>500</td></tr>
          <tr><td>営業利益</td><td></td><td>100</td><td>150</td></tr>
          <tr><td>当社株主帰属当期純利益</td><td></td><td>80</td><td>90</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記番号</td><td>資本金</td><td>純資産 合計</td></tr>
          <tr><td>2024年３月31日現在残高</td><td></td><td>400</td><td>450</td></tr>
          <tr><td>当期純利益</td><td></td><td></td><td>90</td></tr>
          <tr><td>2025年３月31日現在残高</td><td></td><td>400</td><td>540</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額(百万円)</td><td>金額(百万円)</td></tr>
          <tr><td>Ⅰ 営業活動によるキャッシュ・フロー</td><td></td><td></td><td></td></tr>
          <tr><td>１ 当期純利益</td><td></td><td>80</td><td>90</td></tr>
          <tr><td>営業活動によるキャッシュ・フロー</td><td></td><td>120</td><td>130</td></tr>
          <tr><td>Ⅱ 投資活動によるキャッシュ・フロー</td><td></td><td></td><td></td></tr>
          <tr><td>投資活動によるキャッシュ・フロー</td><td></td><td>-50</td><td>-40</td></tr>
          <tr><td>Ⅲ 財務活動によるキャッシュ・フロー</td><td></td><td></td><td></td></tr>
          <tr><td>財務活動によるキャッシュ・フロー</td><td></td><td>-10</td><td>-20</td></tr>
        </table>
        </body></html>
        """

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-stmt-\(UUID().uuidString)", isDirectory: true)
        let pub = dir.appendingPathComponent("XBRL/PublicDoc", isDirectory: true)
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let htmlURL = pub.appendingPathComponent("0105010_test_ixbrl.htm")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)

        // US-GAAP 判定用のダミー .xbrl（タグ名に USGAAP を含む数値要素）
        let xbrl = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrl xmlns="http://www.xbrl.org/2003/instance"
              xmlns:jppfs="http://disclosure.edinet-fsa.go.jp/taxonomy/jppfs/2024-11-01/jppfs_cor">
          <context id="CurrentYearDuration"><period><startDate>2024-04-01</startDate><endDate>2025-03-31</endDate></period></context>
          <jppfs:NetSalesUSGAAPSummaryOfBusinessResults contextRef="CurrentYearDuration" unitRef="JPY" decimals="-6">1000000</jppfs:NetSalesUSGAAPSummaryOfBusinessResults>
        </xbrl>
        """
        try xbrl.write(
            to: pub.appendingPathComponent("test.xbrl"), atomically: true, encoding: .utf8)

        let extracted = try #require(
            USGAAPStatementHtml.extractLineItems(
                in: dir,
                statementTypes: [
                    .balanceSheet, .incomeStatement, .cashFlow, .changesInEquity,
                ]))

        #expect(extracted.balanceSheet.contains { $0.label == "資産合計" && $0.value == 800_000_000 })
        #expect(extracted.balanceSheet.contains { $0.label == "純資産合計" && $0.section == .netAssets })
        #expect(extracted.balanceSheet.contains { $0.label == "１ 資本金" && $0.section == .netAssets })
        #expect(extracted.incomeStatement.contains { $0.label?.contains("売上高") == true && $0.value == 1_200_000_000 })
        #expect(extracted.incomeStatement.contains { $0.label == "営業利益" && $0.value == 150_000_000 })
        #expect(
            extracted.cashFlow.contains {
                $0.label == "営業活動によるキャッシュ・フロー" && $0.value == 130_000_000
                    && $0.section == .operating
            })
        #expect(!extracted.changesInEquity.isEmpty)
        #expect(
            extracted.changesInEquity.contains {
                ($0.label ?? "").contains("2025年３月31日現在残高") && $0.value == 540_000_000
            })

        // order: 0 始まり・密・単調（presentation DFS 通し番号と同型）
        for items in [
            extracted.balanceSheet, extracted.incomeStatement, extracted.cashFlow,
            extracted.changesInEquity,
        ] {
            #expect(items.allSatisfy { $0.order != nil })
            let orders = items.compactMap(\.order)
            #expect(orders.first == 0)
            #expect(zip(orders, orders.dropFirst()).allSatisfy { $0 < $1 })
            #expect(orders == Array(0..<items.count))
        }
    }

    @Test
    func nestedDetailPrefersLineAmountOverParentSubtotal() throws {
        // 富士フイルム形式: 当期左=当該科目、当期右=親小計
        let html = """
        <html><body>
        <table>
          <tr><td>区分</td><td>注記</td><td></td><td>金額</td><td></td><td>金額</td></tr>
          <tr><td>資産の部</td><td></td><td></td><td></td><td></td><td></td></tr>
          <tr><td>(4)信用損失引当金</td><td>注４</td><td>△19,172</td><td>696,585</td><td>△15,841</td><td>699,986</td></tr>
          <tr><td>資産合計</td><td></td><td></td><td>100</td><td></td><td>200</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td></td><td>金額</td><td></td><td>金額</td></tr>
          <tr><td>負債の部</td><td></td><td></td><td></td><td></td><td></td></tr>
          <tr><td>(3) 関連会社等に対する債務</td><td></td><td>1,305</td><td>346,478</td><td>1,672</td><td>390,577</td></tr>
          <tr><td>純資産の部</td><td></td><td></td><td></td><td></td><td></td></tr>
          <tr><td>純資産合計</td><td></td><td></td><td>50</td><td></td><td>80</td></tr>
          <tr><td>負債・純資産合計</td><td></td><td></td><td>100</td><td></td><td>200</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td></td><td>金額</td><td></td><td>金額</td></tr>
          <tr><td>Ⅰ 売上高</td><td></td><td></td><td>1,000</td><td></td><td>1,200</td></tr>
          <tr><td>２ 研究開発費</td><td>注２</td><td>157,108</td><td>909,535</td><td>163,399</td><td>969,924</td></tr>
          <tr><td>営業利益</td><td></td><td></td><td>100</td><td></td><td>150</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td>資本金</td><td>純資産 合計</td></tr>
          <tr><td>振替</td><td></td><td>73</td><td>－</td></tr>
          <tr><td>2025年３月31日現在残高</td><td></td><td>400</td><td>540</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td></td><td>金額</td><td></td><td>金額</td></tr>
          <tr><td>Ⅰ 営業活動によるキャッシュ・フロー</td><td></td><td></td><td></td><td></td><td></td></tr>
          <tr><td>(6) その他</td><td></td><td>△10,620</td><td>164,644</td><td>△21,377</td><td>166,483</td></tr>
          <tr><td>７ 関連会社投融資</td><td></td><td></td><td>△343</td><td></td><td>△42</td></tr>
          <tr><td>９ 事業の売却</td><td></td><td></td><td>12,416</td><td></td><td>－</td></tr>
          <tr><td>投資活動によるキャッシュ・フロー</td><td></td><td></td><td>-50</td><td></td><td>-40</td></tr>
          <tr><td>財務活動によるキャッシュ・フロー</td><td></td><td></td><td>-10</td><td></td><td>-20</td></tr>
        </table>
        </body></html>
        """

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-nested-\(UUID().uuidString)", isDirectory: true)
        let pub = dir.appendingPathComponent("XBRL/PublicDoc", isDirectory: true)
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try html.write(
            to: pub.appendingPathComponent("0105010_test_ixbrl.htm"), atomically: true, encoding: .utf8)

        let extracted = try #require(
            USGAAPStatementHtml.extractLineItems(
                in: dir,
                statementTypes: [
                    .balanceSheet, .incomeStatement, .cashFlow, .changesInEquity,
                ]))

        #expect(extracted.balanceSheet.contains { $0.label == "(4)信用損失引当金" && $0.value == -15_841_000_000 })
        #expect(extracted.balanceSheet.contains { $0.label == "(3) 関連会社等に対する債務" && $0.value == 1_672_000_000 })
        #expect(extracted.incomeStatement.contains { $0.label == "２ 研究開発費" && $0.value == 163_399_000_000 })
        #expect(extracted.cashFlow.contains { $0.label == "(6) その他" && $0.value == -21_377_000_000 })
        #expect(extracted.cashFlow.contains { $0.label == "７ 関連会社投融資" && $0.value == -42_000_000 })
        #expect(extracted.cashFlow.contains { $0.label == "９ 事業の売却" && $0.value == 0 })
        #expect(extracted.changesInEquity.contains { $0.label == "振替" && $0.value == 0 })
    }

    @Test
    func canonStyleCurrentDashIsZeroNotPriorAmount() throws {
        // キヤノン形式: 当期が「-」のとき前期金額を採用しない（PL 構成比列付き / CF 単純2列 / SS 合計列）。
        let html = """
        <html><body>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額（百万円）</td><td>百分比（％）</td><td>金額（百万円）</td><td>百分比（％）</td></tr>
          <tr><td>資産の部</td><td></td><td></td><td></td><td></td><td></td></tr>
          <tr><td>資産合計</td><td></td><td>100</td><td></td><td>200</td><td></td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額（百万円）</td><td></td><td>金額（百万円）</td><td></td></tr>
          <tr><td>負債の部</td><td></td><td></td><td></td><td></td><td></td></tr>
          <tr><td>純資産の部</td><td></td><td></td><td></td><td></td><td></td></tr>
          <tr><td>純資産合計</td><td></td><td>50</td><td></td><td>80</td><td></td></tr>
          <tr><td>負債・純資産合計</td><td></td><td>100</td><td></td><td>200</td><td></td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額（百万円）</td><td>百分比（％）</td><td>金額（百万円）</td><td>百分比（％）</td></tr>
          <tr><td>１ 製品売上高</td><td></td><td>1,000</td><td>100.0</td><td>1,200</td><td>100.0</td></tr>
          <tr><td>３ のれんの減損損失</td><td></td><td>165,100</td><td>3.7</td><td>-</td><td>-</td></tr>
          <tr><td>営業利益</td><td></td><td>100</td><td>10.0</td><td>150</td><td>12.5</td></tr>
        </table>
        <table>
          <tr><td></td><td>注記番号</td><td>資本金</td><td>資本剰余金</td><td>利益剰余金</td><td>自己株式</td><td>株主資本</td><td>非支配持分</td><td>純資産合計</td></tr>
          <tr><td>区分</td><td></td><td></td><td></td><td>利益準備金</td><td>その他の利益剰余金</td><td>利益剰余金合計</td><td></td><td></td></tr>
          <tr><td>2024年12月31日現在残高</td><td></td><td>100</td><td>200</td><td>10</td><td>90</td><td>100</td><td>-5</td><td>395</td><td>5</td><td>400</td></tr>
          <tr><td>利益準備金への振替</td><td></td><td></td><td></td><td>494</td><td>△494</td><td>-</td><td></td><td>-</td><td></td><td>-</td></tr>
          <tr><td>2025年12月31日現在残高</td><td></td><td>100</td><td>200</td><td>504</td><td>-404</td><td>100</td><td>-5</td><td>395</td><td>5</td><td>400</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額（百万円）</td><td>金額（百万円）</td></tr>
          <tr><td>Ⅰ 営業活動によるキャッシュ・フロー</td><td></td><td></td><td></td></tr>
          <tr><td>のれんの減損損失</td><td></td><td>165,100</td><td>-</td></tr>
          <tr><td>営業活動によるキャッシュ・フロー</td><td></td><td>120</td><td>130</td></tr>
          <tr><td>投資活動によるキャッシュ・フロー</td><td></td><td>-50</td><td>-40</td></tr>
          <tr><td>財務活動によるキャッシュ・フロー</td><td></td><td>-10</td><td>-20</td></tr>
        </table>
        </body></html>
        """

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-canon-dash-\(UUID().uuidString)", isDirectory: true)
        let pub = dir.appendingPathComponent("XBRL/PublicDoc", isDirectory: true)
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try html.write(
            to: pub.appendingPathComponent("0105010_test_ixbrl.htm"), atomically: true, encoding: .utf8)

        let extracted = try #require(
            USGAAPStatementHtml.extractLineItems(
                in: dir,
                statementTypes: [
                    .balanceSheet, .incomeStatement, .cashFlow, .changesInEquity,
                ]))

        #expect(extracted.incomeStatement.contains { $0.label == "３ のれんの減損損失" && $0.value == 0 })
        #expect(extracted.cashFlow.contains { $0.label == "のれんの減損損失" && $0.value == 0 })
        #expect(extracted.changesInEquity.contains { $0.label == "利益準備金への振替" && $0.value == 0 })
    }

    @Test
    func returnsNilWhenStatementHtmlMissing() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-stmt-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(
            USGAAPStatementHtml.extractLineItems(in: dir, statementTypes: [.balanceSheet]) == nil)
    }
}
