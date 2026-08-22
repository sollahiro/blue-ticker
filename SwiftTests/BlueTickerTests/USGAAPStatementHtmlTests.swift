// US-GAAP Statement HTML 抽出の最小フィクスチャテスト。
// 実データ回帰は RealXbrlStatementTests（富士フイルム / キヤノン）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct USGAAPStatementHtmlTests {

    @Test
    func displayLabelStripsOutlineNumbersButKeepsYearsAndPerShare() {
        #expect(USGAAPStatementHtml.displayLabel("１ 資本金") == "資本金")
        #expect(USGAAPStatementHtml.displayLabel("１　当期純利益") == "当期純利益")
        #expect(USGAAPStatementHtml.displayLabel("(1）減価償却費") == "減価償却費")
        #expect(USGAAPStatementHtml.displayLabel("(4)信用損失引当金") == "信用損失引当金")
        #expect(USGAAPStatementHtml.displayLabel("(3) 関連会社等に対する債務") == "関連会社等に対する債務")
        #expect(USGAAPStatementHtml.displayLabel("①　受取手形及び売掛金の増加") == "受取手形及び売掛金の増加")
        #expect(USGAAPStatementHtml.displayLabel("Ⅰ 売上高") == "売上高")
        #expect(USGAAPStatementHtml.displayLabel("ⅩⅧ 資本剰余金から") == "資本剰余金から")
        #expect(USGAAPStatementHtml.displayLabel("①営業債権") == "営業債権")
        #expect(USGAAPStatementHtml.displayLabel("１０その他") == "その他")
        #expect(USGAAPStatementHtml.displayLabel("１.当期純利益") == "当期純利益")
        #expect(
            USGAAPStatementHtml.displayLabel("１株当たり当社株主帰属当期純利益")
                == "１株当たり当社株主帰属当期純利益")
        #expect(USGAAPStatementHtml.displayLabel("2024年３月31日現在残高") == "2024年３月31日現在残高")
        #expect(USGAAPStatementHtml.displayLabel("３ヶ月以内") == "３ヶ月以内")
    }

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
        #expect(extracted.balanceSheet.contains { $0.label == "資本金" && $0.section == .netAssets })
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

        #expect(extracted.balanceSheet.contains { $0.label == "信用損失引当金" && $0.value == -15_841_000_000 })
        #expect(extracted.balanceSheet.contains { $0.label == "関連会社等に対する債務" && $0.value == 1_672_000_000 })
        #expect(extracted.incomeStatement.contains { $0.label == "研究開発費" && $0.value == 163_399_000_000 })
        #expect(extracted.cashFlow.contains { $0.label == "その他" && $0.value == -21_377_000_000 })
        #expect(extracted.cashFlow.contains { $0.label == "関連会社投融資" && $0.value == -42_000_000 })
        #expect(extracted.cashFlow.contains { $0.label == "事業の売却" && $0.value == 0 })
        #expect(extracted.changesInEquity.contains { $0.label == "振替" && $0.value == 0 })
    }

    @Test
    func emptyArabParentIsOmittedChildrenKeepLineAmounts() throws {
        // 富士フイルム: 「２ 受取債権」は金額なし。小計は末子の右セルだが、足し算親は行にしない。
        let html = """
        <html><body>
        <table>
          <tr><td>区分</td><td>注記</td><td></td><td>金額</td><td></td><td>金額</td></tr>
          <tr><td>資産の部</td><td></td><td></td><td></td><td></td><td></td></tr>
          <tr><td>２ 受取債権</td><td></td><td></td><td></td><td></td><td></td></tr>
          <tr><td>(1)営業債権</td><td>注20</td><td>674,112</td><td></td><td>680,635</td><td></td></tr>
          <tr><td>(2)リース債権</td><td>注４</td><td>39,248</td><td></td><td>32,821</td><td></td></tr>
          <tr><td>(3)関連会社等に対する債権</td><td></td><td>2,397</td><td></td><td>2,371</td><td></td></tr>
          <tr><td>(4)信用損失引当金</td><td>注４</td><td>△19,172</td><td>696,585</td><td>△15,841</td><td>699,986</td></tr>
          <tr><td>３ 棚卸資産</td><td>注６</td><td></td><td>547,803</td><td></td><td>543,976</td></tr>
          <tr><td>資産合計</td><td></td><td></td><td>100</td><td></td><td>200</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td></td><td>金額</td><td></td><td>金額</td></tr>
          <tr><td>負債の部</td><td></td><td></td><td></td><td></td><td></td></tr>
          <tr><td>純資産の部</td><td></td><td></td><td></td><td></td><td></td></tr>
          <tr><td>純資産合計</td><td></td><td></td><td>50</td><td></td><td>80</td></tr>
          <tr><td>負債・純資産合計</td><td></td><td></td><td>100</td><td></td><td>200</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td></td><td>金額</td><td></td><td>金額</td></tr>
          <tr><td>Ⅰ 売上高</td><td></td><td></td><td>1,000</td><td></td><td>1,200</td></tr>
          <tr><td>営業利益</td><td></td><td></td><td>100</td><td></td><td>150</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td></td><td>金額</td><td></td><td>金額</td></tr>
          <tr><td>営業活動によるキャッシュ・フロー</td><td></td><td></td><td>10</td><td></td><td>20</td></tr>
          <tr><td>投資活動によるキャッシュ・フロー</td><td></td><td></td><td>-5</td><td></td><td>-4</td></tr>
          <tr><td>財務活動によるキャッシュ・フロー</td><td></td><td></td><td>-1</td><td></td><td>-2</td></tr>
        </table>
        </body></html>
        """

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-parent-\(UUID().uuidString)", isDirectory: true)
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

        #expect(!extracted.balanceSheet.contains { $0.label == "受取債権" })
        #expect(extracted.balanceSheet.allSatisfy { $0.components == nil })
        #expect(extracted.balanceSheet.contains { $0.label == "営業債権" && $0.value == 680_635_000_000 })
        #expect(extracted.balanceSheet.contains { $0.label == "信用損失引当金" && $0.value == -15_841_000_000 })
        #expect(extracted.balanceSheet.contains { $0.label == "棚卸資産" && $0.value == 543_976_000_000 })
    }

    @Test
    func canonStyleFollowingDetailsBecomeComponents() throws {
        // 合計行の直後に内訳が続き、合計一致 → components。次の番号付き行で打ち切り。
        let html = """
        <html><body>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額</td><td>金額</td></tr>
          <tr><td>資産の部</td><td></td><td></td><td></td></tr>
          <tr><td>資産合計</td><td></td><td>100</td><td>200</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額</td><td>金額</td></tr>
          <tr><td>負債の部</td><td></td><td></td><td></td></tr>
          <tr><td>１ 短期借入金及び１年以内に返済する長期債務合計</td><td></td><td>300</td><td>511</td></tr>
          <tr><td>金融サービスに係る短期借入金</td><td></td><td>40</td><td>38</td></tr>
          <tr><td>その他の短期借入金及び１年以内に返済する長期債務</td><td></td><td>260</td><td>473</td></tr>
          <tr><td>２ 買入債務</td><td></td><td>100</td><td>120</td></tr>
          <tr><td>流動負債合計</td><td></td><td>400</td><td>631</td></tr>
          <tr><td>純資産の部</td><td></td><td></td><td></td></tr>
          <tr><td>純資産合計</td><td></td><td>50</td><td>80</td></tr>
          <tr><td>負債・純資産合計</td><td></td><td>100</td><td>200</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額</td><td>金額</td></tr>
          <tr><td>Ⅰ 売上高</td><td></td><td>1,000</td><td>1,200</td></tr>
          <tr><td>営業利益</td><td></td><td>100</td><td>150</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td>資本金</td><td>純資産 合計</td></tr>
          <tr><td>2025年３月31日現在残高</td><td></td><td>400</td><td>540</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額</td><td>金額</td></tr>
          <tr><td>営業活動によるキャッシュ・フロー</td><td></td><td>120</td><td>130</td></tr>
          <tr><td>投資活動によるキャッシュ・フロー</td><td></td><td>-50</td><td>-40</td></tr>
          <tr><td>財務活動によるキャッシュ・フロー</td><td></td><td>-10</td><td>-20</td></tr>
        </table>
        </body></html>
        """

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-canon-comp-\(UUID().uuidString)", isDirectory: true)
        let pub = dir.appendingPathComponent("XBRL/PublicDoc", isDirectory: true)
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try html.write(
            to: pub.appendingPathComponent("0105010_test_ixbrl.htm"), atomically: true, encoding: .utf8)

        let extracted = try #require(
            USGAAPStatementHtml.extractLineItems(
                in: dir, statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))

        let st = try #require(
            extracted.balanceSheet.first {
                ($0.label ?? "").contains("短期借入金及び１年以内に返済する長期債務合計")
            })
        #expect(st.isTotal)
        #expect(st.value == 511_000_000)
        let comps = try #require(st.components)
        #expect(comps.map(\.weight) == [1, 1])
        #expect(Set(comps.map(\.tag)) == ["USGAAP_HTML_BS_2", "USGAAP_HTML_BS_3"])

        // 内訳が前に来る流動負債合計はキヤノン型ではない → components なし
        let cl = try #require(extracted.balanceSheet.first { $0.label == "流動負債合計" })
        #expect(cl.isTotal)
        #expect(cl.components == nil)
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

        #expect(extracted.incomeStatement.contains { $0.label == "のれんの減損損失" && $0.value == 0 })
        #expect(extracted.cashFlow.contains { $0.label == "のれんの減損損失" && $0.value == 0 })
        #expect(extracted.changesInEquity.contains { $0.label == "利益準備金への振替" && $0.value == 0 })
    }

    @Test
    func perShareRowsUseYenPerShareUnitAndAreNotTotals() throws {
        // 実データ確認（キヤノン）: 「１株当たり...」見出し行自体には金額が無く、直後の
        // 「基本的」「希薄化後」行だけが値を持つ。見出しでフラグを立てて円建てのまま
        // （百万円換算しない）扱う。isTotal は「当期純利益」を部分文字列に含んでも false。
        let html = """
        <html><body>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額</td><td>金額</td></tr>
          <tr><td>Ⅰ 売上高</td><td></td><td>1,000</td><td>1,200</td></tr>
          <tr><td>営業利益</td><td></td><td>100</td><td>150</td></tr>
          <tr><td>当社株主帰属当期純利益</td><td></td><td>80</td><td>90</td></tr>
          <tr><td>１株当たり当社株主帰属当期純利益</td><td>注17</td><td></td><td></td><td></td><td></td></tr>
          <tr><td>基本的</td><td></td><td>165.53円</td><td></td><td>216.67円</td><td></td></tr>
          <tr><td>希薄化後</td><td></td><td>165.44円</td><td></td><td>216.46円</td><td></td></tr>
        </table>
        </body></html>
        """

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-eps-\(UUID().uuidString)", isDirectory: true)
        let pub = dir.appendingPathComponent("XBRL/PublicDoc", isDirectory: true)
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try html.write(
            to: pub.appendingPathComponent("0105010_test_ixbrl.htm"), atomically: true, encoding: .utf8)

        let extracted = try #require(
            USGAAPStatementHtml.extractLineItems(in: dir, statementTypes: [.incomeStatement]))

        #expect(
            extracted.incomeStatement.contains {
                $0.label == "基本的" && $0.unit == "JPYPerShares" && $0.value == 216.67
                    && $0.isTotal == false
            })
        #expect(
            extracted.incomeStatement.contains {
                $0.label == "希薄化後" && $0.unit == "JPYPerShares" && $0.value == 216.46
                    && $0.isTotal == false
            })
        // 通常の金額行は従来どおり JPY・百万円換算のまま。
        #expect(
            extracted.incomeStatement.contains {
                $0.label == "当社株主帰属当期純利益" && $0.unit == "JPY" && $0.value == 90_000_000
                    && $0.isTotal == true
            })
    }

    @Test
    func perShareFlagDoesNotTriggerOnDividendDescriptionMidLabel() throws {
        // 実データ確認（キヤノン）: 「当社株主への配当金 （１株当たり160.00円）」のような
        // 説明文中の「１株当たり」に反応すると、以降の行が誤って円建て・非合計スケールに
        // なってしまう。見出しラベルの先頭が「１株当たり」のときだけ発火させる。
        let html = """
        <html><body>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額</td><td>金額</td></tr>
          <tr><td>Ⅰ 売上高</td><td></td><td>1,000</td><td>1,200</td></tr>
          <tr><td>営業利益</td><td></td><td>100</td><td>150</td></tr>
          <tr><td>当社株主への配当金 （１株当たり160.00円）</td><td></td><td>50</td><td>60</td></tr>
          <tr><td>当社株主帰属当期純利益</td><td></td><td>80</td><td>90</td></tr>
        </table>
        </body></html>
        """

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-eps-nofalsepos-\(UUID().uuidString)", isDirectory: true)
        let pub = dir.appendingPathComponent("XBRL/PublicDoc", isDirectory: true)
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try html.write(
            to: pub.appendingPathComponent("0105010_test_ixbrl.htm"), atomically: true, encoding: .utf8)

        let extracted = try #require(
            USGAAPStatementHtml.extractLineItems(in: dir, statementTypes: [.incomeStatement]))

        #expect(
            extracted.incomeStatement.contains {
                ($0.label ?? "").contains("配当金") && $0.unit == "JPY" && $0.value == 60_000_000
            })
        #expect(
            extracted.incomeStatement.contains {
                $0.label == "当社株主帰属当期純利益" && $0.unit == "JPY" && $0.value == 90_000_000
            })
    }

    @Test
    func cashFlowTailRowsAfterFinancingHaveNoSection() throws {
        // 実データ確認（富士フイルム・キヤノン）: 為替影響・純増減・期首/期末残高は
        // いずれも「現金及び現金同等物」を含み、営業/投資/財務のどの区分にも属さない
        // （J-GAAP の XBRL fact 経路と同じ扱い）。財務区分を引きずらない。
        let html = """
        <html><body>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額</td><td>金額</td></tr>
          <tr><td>Ⅰ 営業活動によるキャッシュ・フロー</td><td></td><td></td><td></td></tr>
          <tr><td>営業活動によるキャッシュ・フロー</td><td></td><td>120</td><td>130</td></tr>
          <tr><td>Ⅱ 投資活動によるキャッシュ・フロー</td><td></td><td></td><td></td></tr>
          <tr><td>８　事業の買収 (買収資産に含まれる現金及び現金同等物控除後)</td><td></td><td>-5</td><td>-8</td></tr>
          <tr><td>投資活動によるキャッシュ・フロー</td><td></td><td>-50</td><td>-40</td></tr>
          <tr><td>Ⅲ 財務活動によるキャッシュ・フロー</td><td></td><td></td><td></td></tr>
          <tr><td>財務活動によるキャッシュ・フロー</td><td></td><td>-10</td><td>-20</td></tr>
          <tr><td>Ⅳ 為替変動による現金及び現金同等物への影響</td><td></td><td>1</td><td>2</td></tr>
          <tr><td>Ⅴ 現金及び現金同等物の純増減額</td><td></td><td>50</td><td>72</td></tr>
          <tr><td>Ⅵ 現金及び現金同等物の期首残高</td><td></td><td>100</td><td>150</td></tr>
          <tr><td>Ⅶ 現金及び現金同等物の期末残高</td><td></td><td>150</td><td>222</td></tr>
        </table>
        </body></html>
        """

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-cf-tail-\(UUID().uuidString)", isDirectory: true)
        let pub = dir.appendingPathComponent("XBRL/PublicDoc", isDirectory: true)
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try html.write(
            to: pub.appendingPathComponent("0105010_test_ixbrl.htm"), atomically: true, encoding: .utf8)

        let extracted = try #require(
            USGAAPStatementHtml.extractLineItems(in: dir, statementTypes: [.cashFlow]))

        #expect(
            extracted.cashFlow.contains {
                $0.label == "財務活動によるキャッシュ・フロー" && $0.section == .financing
            })
        // 「現金及び現金同等物」を含むが投資区分の明細行（実データ: 富士フイルム
        // 「事業の買収」）は section == .investing のまま維持されなければならない
        // （期首/期末残高等の tail 行と誤って同一視しない）。
        #expect(
            extracted.cashFlow.contains {
                ($0.label ?? "").contains("事業の買収") && $0.section == .investing
            })
        for keyword in ["為替変動", "純増減額", "期首残高", "期末残高"] {
            #expect(
                extracted.cashFlow.contains { ($0.label ?? "").contains(keyword) && $0.section == nil },
                "\(keyword) 行は section == nil のはず")
        }
    }

    @Test
    func changesInEquitySingleTableWithTwoYearsKeepsOnlyLatestYear() throws {
        // 実データ確認（富士フイルム）: 前期・当期が同一表に連続する場合、「現在残高」行が
        // 3回以上現れる（前期首→前期末=当期首→当期末）。最後から2番目（＝当期首）より
        // 前の前期分は切り捨てて当期のみを返す。
        let html = """
        <html><body>
        <table>
          <tr><td>区分</td><td>注記</td><td>資本金</td><td>純資産 合計</td></tr>
          <tr><td>Ⅰ 2023年４月１日現在残高</td><td></td><td>400</td><td>450</td></tr>
          <tr><td>前期純利益</td><td></td><td></td><td>50</td></tr>
          <tr><td>ⅩⅠ 2024年３月31日現在残高</td><td></td><td>400</td><td>500</td></tr>
          <tr><td>当期純利益</td><td></td><td></td><td>40</td></tr>
          <tr><td>ⅩⅩ 2025年３月31日現在残高</td><td></td><td>400</td><td>540</td></tr>
        </table>
        </body></html>
        """

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-ss-2yr-\(UUID().uuidString)", isDirectory: true)
        let pub = dir.appendingPathComponent("XBRL/PublicDoc", isDirectory: true)
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try html.write(
            to: pub.appendingPathComponent("0105010_test_ixbrl.htm"), atomically: true, encoding: .utf8)

        let extracted = try #require(
            USGAAPStatementHtml.extractLineItems(in: dir, statementTypes: [.changesInEquity]))

        #expect(!extracted.changesInEquity.contains { ($0.label ?? "").contains("2023年４月１日") })
        #expect(!extracted.changesInEquity.contains { ($0.label ?? "").contains("前期純利益") })
        #expect(extracted.changesInEquity.count == 3)
        #expect(extracted.changesInEquity.first?.order == 0)
        #expect(extracted.changesInEquity.first?.label?.contains("2024年３月31日") == true)
        #expect(
            extracted.changesInEquity.contains {
                ($0.label ?? "").contains("2025年３月31日") && $0.value == 540_000_000
            })
    }

    @Test
    func zeroTotalDoesNotAttachSpuriousZeroComponents() throws {
        // 「－」（未開示）多用行が偶然0=0で一致しても components を付けない。
        let html = """
        <html><body>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額</td><td>金額</td></tr>
          <tr><td>資産の部</td><td></td><td></td><td></td></tr>
          <tr><td>資産合計</td><td></td><td>50</td><td>80</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額</td><td>金額</td></tr>
          <tr><td>負債の部</td><td></td><td></td><td></td></tr>
          <tr><td>負債合計</td><td></td><td>0</td><td>-</td></tr>
          <tr><td>未払金</td><td></td><td>0</td><td>-</td></tr>
          <tr><td>その他</td><td></td><td>0</td><td>-</td></tr>
          <tr><td>純資産の部</td><td></td><td></td><td></td></tr>
          <tr><td>純資産合計</td><td></td><td>50</td><td>80</td></tr>
        </table>
        </body></html>
        """

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-zero-comp-\(UUID().uuidString)", isDirectory: true)
        let pub = dir.appendingPathComponent("XBRL/PublicDoc", isDirectory: true)
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try html.write(
            to: pub.appendingPathComponent("0105010_test_ixbrl.htm"), atomically: true, encoding: .utf8)

        let extracted = try #require(
            USGAAPStatementHtml.extractLineItems(in: dir, statementTypes: [.balanceSheet]))

        let liabilitiesTotal = try #require(extracted.balanceSheet.first { $0.label == "負債合計" })
        #expect(liabilitiesTotal.value == 0)
        #expect(liabilitiesTotal.components == nil)
    }

    @Test
    func leadingSpacerPlusNoteCellBothStripToRecoverCurrentValue() throws {
        // 実データ確認（富士フイルム「５ 短期オペレーティング・リース負債」）: ラベル直後に
        // 空スペーサ列＋「注５」列が連続する行がある。空セル1個だけ剥がすと5スロット
        // （奇数）になり行ごと落ちてしまうため、「注」を含むセルはもう1個追加で剥がす。
        let html = """
        <html><body>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額</td><td>金額</td></tr>
          <tr><td>負債の部</td><td></td><td></td><td></td></tr>
          <tr><td>５ 短期オペレーティング・リース負債</td><td></td><td>注５</td><td></td><td>32,589</td><td></td><td>31,582</td></tr>
          <tr><td>負債合計</td><td></td><td>100</td><td>200</td></tr>
        </table>
        </body></html>
        """

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-note-plus-spacer-\(UUID().uuidString)", isDirectory: true)
        let pub = dir.appendingPathComponent("XBRL/PublicDoc", isDirectory: true)
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try html.write(
            to: pub.appendingPathComponent("0105010_test_ixbrl.htm"), atomically: true, encoding: .utf8)

        let extracted = try #require(
            USGAAPStatementHtml.extractLineItems(in: dir, statementTypes: [.balanceSheet]))

        #expect(
            extracted.balanceSheet.contains {
                ($0.label ?? "").contains("短期オペレーティング・リース負債") && $0.value == 31_582_000_000
            })
    }

    @Test
    func fourSlotRowWithEmptyLeftCellsKeepsCurrentRightAmount() throws {
        // 実データ確認（オムロン CF「１　当期純利益」）: 前期/当期それぞれ左空・右金額の
        // 4スロット。先頭の空をスペーサとして剥がすと奇数になり行ごと落ちるため残す。
        // 明細行（減価償却費）は左に金額・右が空でも従来どおり当期左を取る。
        let html = """
        <html><body>
        <table>
          <tr><td>区分</td><td></td><td>金額</td><td></td><td>金額</td></tr>
          <tr><td>Ⅰ　営業活動によるキャッシュ・フロー</td><td></td><td></td><td></td><td></td></tr>
          <tr><td>１　当期純利益</td><td></td><td>14,873</td><td></td><td>31,277</td></tr>
          <tr><td>２　営業活動によるキャッシュ・フローと当期純利益の調整</td><td></td><td></td><td></td><td></td></tr>
          <tr><td>(1）減価償却費</td><td>33,450</td><td></td><td>33,778</td><td></td></tr>
          <tr><td>営業活動によるキャッシュ・フロー</td><td></td><td>55,784</td><td></td><td>60,919</td></tr>
        </table>
        </body></html>
        """
        let cf = try extractFromHTML(html, types: [.cashFlow]).cashFlow

        #expect(cf.first?.label == "当期純利益")
        #expect(
            cf.contains {
                $0.label == "当期純利益" && $0.value == 31_277_000_000 && $0.section == .operating
            })
        #expect(cf.contains { $0.label == "減価償却費" && $0.value == 33_778_000_000 })
        #expect(
            cf.contains {
                $0.label == "営業活動によるキャッシュ・フロー" && $0.value == 60_919_000_000
            })
        #expect(!cf.contains { ($0.label ?? "").contains("調整") })
    }

    @Test
    func rowWithUnbalancedSlotCountIsDroppedRatherThanGuessed() throws {
        // 前期/当期のスロット数が偶数に揃わない（想定外の列構成）行は、誤った期の値を
        // 静かに返すより行ごと落とす（他の行の抽出は継続する）。先頭スペーサ無しの
        // 3スロットで、偶数ガード自体を検証する。
        let html = """
        <html><body>
        <table>
          <tr><td>区分</td><td>注記</td><td>金額</td><td>金額</td></tr>
          <tr><td>資産の部</td><td></td><td></td><td></td></tr>
          <tr><td>現金及び預金</td><td></td><td>10</td><td>20</td></tr>
          <tr><td>資産合計</td><td>100</td><td>abc</td><td>200</td></tr>
        </table>
        </body></html>
        """

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-unbalanced-\(UUID().uuidString)", isDirectory: true)
        let pub = dir.appendingPathComponent("XBRL/PublicDoc", isDirectory: true)
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try html.write(
            to: pub.appendingPathComponent("0105010_test_ixbrl.htm"), atomically: true, encoding: .utf8)

        let extracted = try #require(
            USGAAPStatementHtml.extractLineItems(in: dir, statementTypes: [.balanceSheet]))

        #expect(extracted.balanceSheet.contains { $0.label == "現金及び預金" && $0.value == 20_000_000 })
        #expect(!extracted.balanceSheet.contains { $0.label == "資産合計" })
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

    @Test
    func statementResolverTakesAbsOfInterestAndTreasuryPurchase() throws {
        // 富士フイルム型: PL 支払利息・SS/CF 自己株式取得が △。financials は絶対値。
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
          <tr><td>２ 支払利息</td><td></td><td>△9,000</td><td>△8,752</td></tr>
          <tr><td>当社株主帰属当期純利益</td><td></td><td>80</td><td>90</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>注記番号</td><td>資本金</td><td>純資産 合計</td></tr>
          <tr><td>2024年３月31日現在残高</td><td></td><td>400</td><td>450</td></tr>
          <tr><td>自己株式取得</td><td></td><td></td><td>△16</td></tr>
          <tr><td>自己株式売却</td><td></td><td></td><td>2</td></tr>
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
          <tr><td>６ 自己株式の取得及び売却</td><td></td><td>△31</td><td>△16</td></tr>
          <tr><td>財務活動によるキャッシュ・フロー</td><td></td><td>-10</td><td>-20</td></tr>
        </table>
        </body></html>
        """

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-ie-ts-\(UUID().uuidString)", isDirectory: true)
        let pub = dir.appendingPathComponent("XBRL/PublicDoc", isDirectory: true)
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try html.write(
            to: pub.appendingPathComponent("0105010_test_ixbrl.htm"), atomically: true, encoding: .utf8)
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

        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(values.interestExpense == 8_752_000_000)
        #expect(values.cfTreasuryStock == 16_000_000)
        #expect(values.buyback == 16_000_000)
    }

    @Test
    func brokerDealerHeadingsAndSplitCashFlowExtract() throws {
        // 野村: （資産）/（負債および資本）/資本：、売上高なしの収益合計、営業CFと投資/財務CFが別表。
        let html = """
        <html><body>
        <table>
          <tr><td>区分</td><td>前期</td><td>当期</td></tr>
          <tr><td>（資産）</td><td></td><td></td></tr>
          <tr><td>現金および現金同等物</td><td>100</td><td>200</td></tr>
          <tr><td>定期預金</td><td>50</td><td>80</td></tr>
          <tr><td>計</td><td>150</td><td>280</td></tr>
          <tr><td>資産合計</td><td>500</td><td>800</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>前期</td><td>当期</td></tr>
          <tr><td>（負債および資本）</td><td></td><td></td></tr>
          <tr><td>短期借入</td><td>50</td><td>60</td></tr>
          <tr><td>負債合計</td><td>50</td><td>60</td></tr>
          <tr><td>資本：</td><td></td><td></td></tr>
          <tr><td>資本金</td><td>400</td><td>700</td></tr>
          <tr><td>資本合計</td><td>450</td><td>740</td></tr>
          <tr><td>負債および資本合計</td><td>500</td><td>800</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>前期</td><td>当期</td></tr>
          <tr><td>委託・投信募集手数料</td><td>10</td><td>20</td></tr>
          <tr><td>収益合計</td><td>100</td><td>150</td></tr>
          <tr><td>人件費</td><td>30</td><td>40</td></tr>
          <tr><td>金融費用以外の費用計</td><td>60</td><td>80</td></tr>
          <tr><td>税引前当期純利益</td><td>40</td><td>50</td></tr>
          <tr><td>当社株主に帰属する当期純利益</td><td>30</td><td>40</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>前期</td><td>当期</td></tr>
          <tr><td>営業活動によるキャッシュ・フロー：</td><td></td><td></td></tr>
          <tr><td>当期純利益</td><td>30</td><td>40</td></tr>
          <tr><td>営業活動に使用された現金（純額）</td><td>-10</td><td>-20</td></tr>
        </table>
        <table>
          <tr><td>区分</td><td>前期</td><td>当期</td></tr>
          <tr><td>投資活動によるキャッシュ・フロー：</td><td></td><td></td></tr>
          <tr><td>設備の購入</td><td>-5</td><td>-8</td></tr>
          <tr><td>投資活動に使用された現金（純額）</td><td>-5</td><td>-8</td></tr>
          <tr><td>財務活動によるキャッシュ・フロー：</td><td></td><td></td></tr>
          <tr><td>長期借入の実行による収入</td><td>15</td><td>25</td></tr>
          <tr><td>財務活動から得た現金（純額）</td><td>15</td><td>25</td></tr>
          <tr><td>現金、現金同等物、制限付き現金および制限付き現金同等物の期首残高</td><td>90</td><td>100</td></tr>
          <tr><td>現金、現金同等物、制限付き現金および制限付き現金同等物の期末残高</td><td>100</td><td>97</td></tr>
        </table>
        </body></html>
        """
        let extracted = try extractFromHTML(
            html,
            types: [.balanceSheet, .incomeStatement, .cashFlow, .changesInEquity])

        #expect(
            extracted.balanceSheet.contains {
                $0.label == "計" && $0.value == 280_000_000 && $0.isTotal && $0.section == .assets
                    && $0.components == nil
            })
        #expect(extracted.balanceSheet.contains { $0.label == "資産合計" && $0.value == 800_000_000 && $0.section == .assets })
        #expect(extracted.balanceSheet.contains { $0.label == "資本金" && $0.section == .netAssets })
        #expect(extracted.balanceSheet.contains { $0.label == "資本合計" && $0.value == 740_000_000 && $0.section == .netAssets })
        #expect(
            extracted.balanceSheet.contains {
                $0.label == "負債および資本合計" && $0.value == 800_000_000 && $0.isTotal
                    && $0.section == nil
            })
        #expect(extracted.incomeStatement.contains { $0.label == "収益合計" && $0.value == 150_000_000 })
        #expect(
            extracted.incomeStatement.contains {
                $0.label == "金融費用以外の費用計" && $0.value == 80_000_000 && $0.isTotal
            })
        #expect(extracted.incomeStatement.contains { $0.label == "当社株主に帰属する当期純利益" && $0.value == 40_000_000 })
        #expect(
            extracted.cashFlow.contains {
                $0.label == "営業活動に使用された現金（純額）" && $0.value == -20_000_000
                    && $0.section == .operating && $0.isTotal
            })
        #expect(
            extracted.cashFlow.contains {
                $0.label == "投資活動に使用された現金（純額）" && $0.value == -8_000_000
                    && $0.section == .investing && $0.isTotal
            })
        #expect(
            extracted.cashFlow.contains {
                $0.label == "財務活動から得た現金（純額）" && $0.value == 25_000_000
                    && $0.section == .financing && $0.isTotal
            })
        let open = extracted.cashFlow.first { ($0.label ?? "").contains("期首残高") }
        let close = extracted.cashFlow.first { ($0.label ?? "").contains("期末残高") }
        #expect(open?.section == nil && close?.section == nil)
        #expect(open?.order != nil && close?.order != nil && open!.order! < close!.order!)
    }

    @Test
    func incomeStatementWithoutOperatingProfitStillExtracts() throws {
        // オムロン: 売上高はあるが営業利益行が無く、税引前の長いラベルへ飛ぶ。
        let html = """
        <html><body>
        <table>
          <tr><td>区分</td><td>注記</td><td></td><td>金額</td><td>％</td><td></td><td>金額</td><td>％</td></tr>
          <tr><td>売上高</td><td>（注記Ⅰ）</td><td></td><td>715,379</td><td>100.0</td><td></td><td>767,351</td><td>100.0</td></tr>
          <tr><td>売上原価</td><td></td><td></td><td>385,092</td><td></td><td></td><td>416,350</td><td></td></tr>
          <tr><td>販売費及び一般管理費</td><td></td><td></td><td>236,881</td><td></td><td></td><td>245,398</td><td></td></tr>
          <tr><td>当社株主に帰属する当期純利益</td><td></td><td></td><td>16,271</td><td>2.3</td><td></td><td>28,487</td><td>3.7</td></tr>
        </table>
        </body></html>
        """
        let extracted = try extractFromHTML(html, types: [.incomeStatement])
        #expect(extracted.incomeStatement.contains { $0.label == "売上高" && $0.value == 767_351_000_000 })
        #expect(
            extracted.incomeStatement.contains {
                $0.label == "当社株主に帰属する当期純利益" && $0.value == 28_487_000_000
            })
    }

    @Test
    func equityStatementAcceptsPeriodEndAndDateBalanceLabels() throws {
        // オムロン「第N期末現在」、オリックス「YYYY年M月DD日残高」、小松「期首残高/期末残高」。
        let omron = """
        <html><body>
        <table>
          <tr><td>項目</td><td>資本金</td><td>純資産 合計</td></tr>
          <tr><td>第87期末現在</td><td>64,100</td><td>950,993</td></tr>
          <tr><td>当期純利益</td><td></td><td>16,271</td></tr>
          <tr><td>第88期末現在</td><td>64,100</td><td>934,432</td></tr>
          <tr><td>当期純利益</td><td></td><td>28,487</td></tr>
          <tr><td>第89期末現在</td><td>64,100</td><td>1,000,562</td></tr>
        </table>
        </body></html>
        """
        let omronSS = try extractFromHTML(omron, types: [.changesInEquity]).changesInEquity
        #expect(!omronSS.contains { ($0.label ?? "").contains("第87期") })
        #expect(omronSS.contains { ($0.label ?? "").contains("第88期末現在") && $0.value == 934_432_000_000 })
        #expect(omronSS.contains { ($0.label ?? "").contains("第89期末現在") && $0.value == 1_000_562_000_000 })
        #expect(omronSS.allSatisfy { $0.section == nil })

        let orix = """
        <html><body>
        <table>
          <tr><td></td><td>資本金</td><td>資本合計</td></tr>
          <tr><td>2024年３月31日残高</td><td>221,111</td><td>4,021,965</td></tr>
          <tr><td>当期純利益</td><td></td><td>351,630</td></tr>
          <tr><td>2025年３月31日残高</td><td>221,111</td><td>4,171,783</td></tr>
          <tr><td>当期純利益</td><td></td><td>447,265</td></tr>
          <tr><td>2026年３月31日残高</td><td>221,111</td><td>4,573,068</td></tr>
        </table>
        </body></html>
        """
        let orixSS = try extractFromHTML(orix, types: [.changesInEquity]).changesInEquity
        #expect(!orixSS.contains { ($0.label ?? "").contains("2024年") })
        #expect(orixSS.contains { ($0.label ?? "").contains("2025年３月31日") && $0.value == 4_171_783_000_000 })
        #expect(orixSS.contains { ($0.label ?? "").contains("2026年３月31日") && $0.value == 4_573_068_000_000 })
        #expect(orixSS.allSatisfy { $0.section == nil })

        let komatsu = """
        <html><body>
        <table>
          <tr><td></td><td>資本金</td><td>純資産 合計</td></tr>
          <tr><td>期首残高</td><td>70,336</td><td>3,344,853</td></tr>
          <tr><td>当期純利益</td><td></td><td>401,688</td></tr>
          <tr><td>期末残高</td><td>70,336</td><td>3,708,427</td></tr>
        </table>
        </body></html>
        """
        let komatsuSS = try extractFromHTML(komatsu, types: [.changesInEquity]).changesInEquity
        #expect(komatsuSS.contains { $0.label == "期首残高" && $0.value == 3_344_853_000_000 })
        #expect(komatsuSS.contains { $0.label == "期末残高" && $0.value == 3_708_427_000_000 })
        #expect(komatsuSS.allSatisfy { $0.section == nil })

        // 小松実データ: 科目横の前期表＋当期表。年次列が無いので最後の表だけ残す。
        let komatsuYears = """
        <html><body>
        <table>
          <tr><td></td><td>資本金</td><td>純資産 合計</td></tr>
          <tr><td>期首残高</td><td>70,336</td><td>3,198,452</td></tr>
          <tr><td>当期純利益</td><td></td><td>468,732</td></tr>
          <tr><td>期末残高</td><td>70,336</td><td>3,344,853</td></tr>
        </table>
        <table>
          <tr><td></td><td>資本金</td><td>純資産 合計</td></tr>
          <tr><td>期首残高</td><td>70,336</td><td>3,344,853</td></tr>
          <tr><td>当期純利益</td><td></td><td>401,688</td></tr>
          <tr><td>期末残高</td><td>70,336</td><td>3,708,427</td></tr>
        </table>
        </body></html>
        """
        let komatsuLatest = try extractFromHTML(komatsuYears, types: [.changesInEquity]).changesInEquity
        #expect(!komatsuLatest.contains { $0.label == "期末残高" && $0.value == 3_344_853_000_000 })
        #expect(komatsuLatest.contains { $0.label == "期首残高" && $0.value == 3_344_853_000_000 })
        #expect(komatsuLatest.contains { $0.label == "期末残高" && $0.value == 3_708_427_000_000 })
        #expect(komatsuLatest.allSatisfy { $0.section == nil })
    }

    @Test
    func componentMajorEquityStatementKeepsGroupsAndContinuationTable() throws {
        // 野村 連結資本勘定変動表: 科目縦・年次は列。株主資本と非支配持分が改ページで別表。
        // 期首/期末の繰り返しは年次切り出しに使わない。label は開示どおり。区分見出しは section。
        let html = """
        <html><body>
        <table>
          <tr><td></td><td>2025年３月期</td><td>2026年３月期</td></tr>
          <tr><td>区分</td><td>金額（百万円）</td><td>金額（百万円）</td></tr>
          <tr><td><p>資本金</p></td><td></td><td></td></tr>
          <tr><td><p>　期首残高</p></td><td>594,493</td><td>594,493</td></tr>
          <tr><td><p>　期末残高</p></td><td>594,493</td><td>594,493</td></tr>
          <tr><td><p>累積的その他の包括利益</p></td><td></td><td></td></tr>
          <tr><td><p>　為替換算調整額</p></td><td></td><td></td></tr>
          <tr><td><p>　　期首残高</p></td><td>407,977</td><td>407,977</td></tr>
          <tr><td><p>　　当期純変動額</p></td><td>△36,094</td><td>142,524</td></tr>
          <tr><td><p>　　期末残高</p></td><td>407,977</td><td>550,501</td></tr>
          <tr><td><p>　自己クレジット調整額</p></td><td></td><td></td></tr>
          <tr><td><p>　　期首残高</p></td><td>48,083</td><td>48,083</td></tr>
          <tr><td><p>　　自己クレジット調整額</p></td><td>12,658</td><td>△46,879</td></tr>
          <tr><td><p>　　期末残高</p></td><td>48,083</td><td>1,204</td></tr>
          <tr><td><p>　期末残高</p></td><td>447,808</td><td>548,221</td></tr>
          <tr><td><p>当社株主資本合計</p></td><td></td><td></td></tr>
          <tr><td><p>　期末残高</p></td><td>3,470,879</td><td>3,707,868</td></tr>
        </table>
        <table>
          <tr><td></td><td>2025年３月期</td><td>2026年３月期</td></tr>
          <tr><td>区分</td><td>金額（百万円）</td><td>金額（百万円）</td></tr>
          <tr><td><p>非支配持分</p></td><td></td><td></td></tr>
          <tr><td><p>　期首残高</p></td><td>110,120</td><td>110,120</td></tr>
          <tr><td><p>　非支配持分に帰属する累積的その他の包括利益</p></td><td></td><td></td></tr>
          <tr><td><p>　　為替換算調整額</p></td><td>1,243</td><td>5,214</td></tr>
          <tr><td><p>　期末残高</p></td><td>110,120</td><td>147,047</td></tr>
          <tr><td><p>資本合計</p></td><td></td><td></td></tr>
          <tr><td><p>　期末残高</p></td><td>3,580,999</td><td>3,854,915</td></tr>
        </table>
        </body></html>
        """
        let ss = try extractFromHTML(html, types: [.changesInEquity]).changesInEquity

        #expect(ss.contains { $0.label == "期末残高" && $0.value == 594_493_000_000 && $0.isTotal && $0.section == .group("資本金") })
        #expect(ss.contains { $0.label == "期末残高" && $0.value == 550_501_000_000 && $0.isTotal && $0.section == .group("為替換算調整額") })
        #expect(ss.contains { $0.label == "期末残高" && $0.value == 548_221_000_000 && $0.isTotal && $0.section == .group("累積的その他の包括利益") })
        #expect(ss.contains { $0.label == "自己クレジット調整額" && $0.value == -46_879_000_000 && $0.section == .group("自己クレジット調整額") })
        #expect(ss.contains { $0.label == "期末残高" && $0.value == 3_707_868_000_000 && $0.isTotal && $0.section == .group("当社株主資本合計") })
        #expect(ss.contains { $0.label == "期末残高" && $0.value == 147_047_000_000 && $0.isTotal && $0.section == .group("非支配持分") })
        #expect(ss.contains { $0.label == "期末残高" && $0.value == 3_854_915_000_000 && $0.isTotal && $0.section == .group("資本合計") })
        let capitalOpen = ss.first { $0.label == "期首残高" }
        let equityClose = ss.last { $0.label == "期末残高" }
        #expect(capitalOpen?.value == 594_493_000_000)
        #expect(capitalOpen?.section == .group("資本金"))
        #expect(equityClose?.value == 3_854_915_000_000)
        #expect(equityClose?.section == .group("資本合計"))
        #expect(capitalOpen?.order != nil && equityClose?.order != nil)
        #expect(capitalOpen!.order! < equityClose!.order!)
    }

    private func extractFromHTML(
        _ html: String, types: Set<StatementSectionType>
    ) throws -> (
        balanceSheet: [StatementLineItem], incomeStatement: [StatementLineItem],
        cashFlow: [StatementLineItem], changesInEquity: [StatementLineItem]
    ) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usgaap-\(UUID().uuidString)", isDirectory: true)
        let pub = dir.appendingPathComponent("XBRL/PublicDoc", isDirectory: true)
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try html.write(
            to: pub.appendingPathComponent("0105010_test_ixbrl.htm"), atomically: true, encoding: .utf8)
        return try #require(USGAAPStatementHtml.extractLineItems(in: dir, statementTypes: types))
    }
}
