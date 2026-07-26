// BreakdownExtractor のユニットテスト
// Python tests/test_segment_extractor.py 相当＋TextBlock/dimension fact 統合テスト

// 注意: このファイルで SwiftSoup を import しないこと。
// SwiftSoup.Comment が #expect マクロ展開の生成する Comment と曖昧衝突し、
// CI のツールチェーンでコンパイルエラーになる。HTML パースは XBRLTestSupport 経由で行う。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct BreakdownExtractorTests {

    // MARK: - gridToMarkdown

    @Test func gridToMarkdownSimple2x2() {
        let md = BreakdownExtractor.gridToMarkdown([["A", "B"], ["1", "2"]])
        #expect(md.contains("| A | B |"))
        #expect(md.contains("| 1 | 2 |"))
        #expect(md.contains("---"))
    }

    @Test func gridToMarkdownEmptyGridReturnsEmpty() {
        #expect(BreakdownExtractor.gridToMarkdown([]) == "")
    }

    @Test func gridToMarkdownHeaderSeparatorAfterFirstRow() {
        let md = BreakdownExtractor.gridToMarkdown([["Header"], ["Value"]])
        #expect(md.split(separator: "\n").count == 3)  // header / separator / value
    }

    @Test func gridToMarkdownColumnsArePaddedToMaxWidth() {
        let md = BreakdownExtractor.gridToMarkdown([["Short", "A very long column header"]])
        #expect(md.contains("A very long column header"))
    }

    @Test func gridToMarkdownSingleRow() {
        let md = BreakdownExtractor.gridToMarkdown([["Only", "Row"]])
        #expect(md.contains("Only"))
        #expect(md.contains("Row"))
    }

    // MARK: - detectPeriodFromGrid

    @Test func detectPeriodCurrentPeriod() {
        #expect(BreakdownExtractor.detectPeriodFromGrid([["当連結会計年度", "数値"], ["売上高", "1000"]]) == "当期")
    }

    @Test func detectPeriodPriorPeriod() {
        #expect(BreakdownExtractor.detectPeriodFromGrid([["前連結会計年度", "数値"], ["売上高", "900"]]) == "前期")
    }

    @Test func detectPeriodComparisonWhenBothPresent() {
        #expect(BreakdownExtractor.detectPeriodFromGrid([["前連結会計年度", "当連結会計年度"], ["900", "1000"]]) == "比較")
    }

    @Test func detectPeriodShortFormCurrent() {
        #expect(BreakdownExtractor.detectPeriodFromGrid([["当期", "数値"]]) == "当期")
    }

    @Test func detectPeriodShortFormPrior() {
        #expect(BreakdownExtractor.detectPeriodFromGrid([["前期", "数値"]]) == "前期")
    }

    @Test func detectPeriodNoKeywordReturnsNil() {
        #expect(BreakdownExtractor.detectPeriodFromGrid([["セグメント", "売上高"], ["事業A", "500"]]) == nil)
    }

    @Test func detectPeriodOnlyChecksFirst3Rows() {
        let grid = [
            ["セグメント名", "値"],
            ["事業A", "100"],
            ["事業B", "200"],
            ["当連結会計年度の合計", "300"],
        ]
        #expect(BreakdownExtractor.detectPeriodFromGrid(grid) == nil)
    }

    @Test func detectPeriodEmptyGridReturnsNil() {
        #expect(BreakdownExtractor.detectPeriodFromGrid([]) == nil)
    }

    // MARK: - applyPeriodOrdering

    @Test func periodOrderingUnlabeledGetsAlternatingLabels() {
        var tables = ["A", "B", "C", "D"].map {
            BreakdownTable(heading: "セグメント情報", markdown: "| \($0) |", period: nil)
        }
        BreakdownExtractor.applyPeriodOrdering(&tables)
        #expect(tables.map(\.period) == ["前期", "当期", "前期", "当期"])
    }

    @Test func periodOrderingAlreadyLabeledIsNotChanged() {
        var tables = [
            BreakdownTable(heading: "X", markdown: "| 1 |", period: "当期"),
            BreakdownTable(heading: "X", markdown: "| 2 |", period: nil),
        ]
        BreakdownExtractor.applyPeriodOrdering(&tables)
        #expect(tables[0].period == "当期")
        #expect(tables[1].period == "前期")
    }

    @Test func periodOrderingAllLabeledUnchanged() {
        var tables = [BreakdownTable(heading: "X", markdown: "| 1 |", period: "比較")]
        BreakdownExtractor.applyPeriodOrdering(&tables)
        #expect(tables[0].period == "比較")
    }

    @Test func periodOrderingEmptyListDoesNothing() {
        var tables: [BreakdownTable] = []
        BreakdownExtractor.applyPeriodOrdering(&tables)
        #expect(tables.isEmpty)
    }

    // MARK: - expandTable

    @Test func expandTableSimple() throws {
        let table = try XBRLTestSupport.parseFirstTable("<table><tr><td>A</td><td>B</td></tr><tr><td>1</td><td>2</td></tr></table>")
        #expect(BreakdownExtractor.expandTable(table) == [["A", "B"], ["1", "2"]])
    }

    @Test func expandTableColspanExpandsCell() throws {
        let table = try XBRLTestSupport.parseFirstTable("<table><tr><td colspan='2'>合計</td></tr><tr><td>事業A</td><td>100</td></tr></table>")
        let grid = BreakdownExtractor.expandTable(table)
        #expect(grid[0] == ["合計", "合計"])
        #expect(grid[1] == ["事業A", "100"])
    }

    @Test func expandTableRowspanRepeatsCellDownward() throws {
        let table = try XBRLTestSupport.parseFirstTable("<table><tr><td rowspan='2'>期間</td><td>Q1</td></tr><tr><td>Q2</td></tr></table>")
        let grid = BreakdownExtractor.expandTable(table)
        #expect(grid[0][0] == "期間")
        #expect(grid[1][0] == "期間")
        #expect(grid[0][1] == "Q1")
        #expect(grid[1][1] == "Q2")
    }

    @Test func expandTableEmptyTableReturnsEmpty() throws {
        let table = try XBRLTestSupport.parseFirstTable("<table></table>")
        #expect(BreakdownExtractor.expandTable(table).isEmpty)
    }

    @Test func expandTableStripsWhitespaceFromCells() throws {
        let table = try XBRLTestSupport.parseFirstTable("<table><tr><td>  事業A  </td><td>  100  </td></tr></table>")
        #expect(BreakdownExtractor.expandTable(table)[0] == ["事業A", "100"])
    }

    // MARK: - TextBlock 統合（J-GAAP / IFRS）

    /// エスケープ済み HTML テーブルを含む TextBlock 要素の XBRL インスタンスを作る。
    private func textBlockXml(tag: String, escapedHtml: String) -> String {
        XBRLTestSupport.makeXbrlDuration(
            """
            <jpcrp_cor:\(tag) contextRef="CurrentYearDuration">\(escapedHtml)</jpcrp_cor:\(tag)>
            """
        )
    }

    // div 区切りで前期/当期のテーブルを持つ典型的な TextBlock HTML（エスケープ済み）
    private static let escapedSegmentTable =
        "&lt;div&gt;&lt;p&gt;前連結会計年度&lt;/p&gt;" +
        "&lt;table&gt;&lt;tr&gt;&lt;td&gt;事業A&lt;/td&gt;&lt;td&gt;100&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;&lt;/div&gt;" +
        "&lt;div&gt;&lt;p&gt;当連結会計年度&lt;/p&gt;" +
        "&lt;table&gt;&lt;tr&gt;&lt;td&gt;事業A&lt;/td&gt;&lt;td&gt;120&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;&lt;/div&gt;"

    @Test func segmentInfoFromJGAAPTextBlock() throws {
        let xml = textBlockXml(tag: "SegmentInformationTextBlock", escapedHtml: Self.escapedSegmentTable)
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 2)
            #expect(result.tables[0].heading == "セグメント情報")
            #expect(result.tables[0].markdown.contains("| 事業A | 100 |"))
            #expect(result.tables[0].period == "前期")
            #expect(result.tables[1].markdown.contains("| 事業A | 120 |"))
            #expect(result.tables[1].period == "当期")
            #expect(result.facts.isEmpty)
        }
    }

    @Test func segmentInfoFromIFRSTextBlock() {
        let xml = textBlockXml(tag: "SegmentInformationIFRSTextBlock", escapedHtml: Self.escapedSegmentTable)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 2)
            #expect(result.tables.map(\.period) == ["前期", "当期"])
        }
    }

    @Test func geographyMixedBlockFiltersByKeyword() {
        // RelatedInformationTextBlock（混在）は見出しキーワードに続く table のみ抽出する
        let escaped =
            "&lt;p&gt;製品ごとの情報&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;製品X&lt;/td&gt;&lt;td&gt;1&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;" +
            "&lt;p&gt;地域ごとの情報&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;日本&lt;/td&gt;&lt;td&gt;500&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        let xml = textBlockXml(tag: "RelatedInformationTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractGeographyInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].heading == "地域ごとの情報")
            #expect(result.tables[0].markdown.contains("| 日本 | 500 |"))
            #expect(!result.tables[0].markdown.contains("製品X"))
        }
    }

    @Test func detectPeriodFromPrecedingUsesClosestHeadingNotFirst() {
        // オークマ型の回帰: 同じ親の下に複数テーブルが並ぶとき、
        // 先頭の見出し「前期」に固定されず、各テーブル直前の見出しを個別に拾う。
        let escaped =
            "&lt;p&gt;前連結会計年度&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;日本&lt;/td&gt;&lt;td&gt;100&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;" +
            "&lt;p&gt;当連結会計年度&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;日本&lt;/td&gt;&lt;td&gt;120&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        let xml = textBlockXml(tag: "InformationAboutGeographicalAreasTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractGeographyInfo(xbrlDir: dir)
            #expect(result.tables.map(\.period) == ["前期", "当期"])
        }
    }

    @Test func segmentInfoFromUSGAAPNoteMixedBlock() {
        // キヤノン型の回帰: 事業別セグメントがUS-GAAP巨大注記(NotesToConsolidatedFinancialStatementsUSGAAPTextBlock)
        // に内包されている場合でも見出しキーワードで発見できる。
        let escaped =
            "&lt;p&gt;収益認識&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;一時点で認識する収益&lt;/td&gt;&lt;td&gt;999&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;" +
            "&lt;p&gt;報告セグメント&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;事業A&lt;/td&gt;&lt;td&gt;500&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("事業A"))
            #expect(!result.tables[0].markdown.contains("一時点で認識する収益"))
        }
    }

    @Test func geographyMixedBlockExcludesRevenueTimingTable() {
        // キヤノン型の回帰: 見出しキーワード一致直後に事業別収益認識タイミング表が
        // 挟まっていても、地域別テーブルとして誤って混入させない。
        let escaped =
            "&lt;p&gt;地域別&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;一時点で認識する収益&lt;/td&gt;&lt;td&gt;999&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;" +
            "&lt;p&gt;地域別&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;日本&lt;/td&gt;&lt;td&gt;500&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractGeographyInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("日本"))
        }
    }

    @Test func segmentInfoExcludesStockOptionAssumptionTable() {
        // キヤノン型の回帰: 見出しキーワード一致直後にストックオプションの評価前提表が
        // 挟まっていても、事業別セグメントとして誤って混入させない。
        let escaped =
            "&lt;p&gt;報告セグメント&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;予想残存期間&lt;/td&gt;&lt;td&gt;4.0年&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;" +
            "&lt;p&gt;セグメント情報&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;事業A&lt;/td&gt;&lt;td&gt;500&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("事業A"))
        }
    }

    @Test func segmentInfoSkipsToNextTableWhenSameHeadingsImmediateTableIsExcluded() {
        // 見出しが1つしかなく、その直後にノイズ表→本表の順で並ぶ場合でも、
        // ノイズ表を除外した後に本表を拾えることを確認する（別見出しがない構成の回帰）。
        let escaped =
            "&lt;p&gt;報告セグメント&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;予想残存期間&lt;/td&gt;&lt;td&gt;4.0年&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;事業A&lt;/td&gt;&lt;td&gt;500&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("事業A"))
        }
    }

    @Test func segmentInfoExcludesInvestmentFairValueTable() {
        // 富士フイルム型の回帰: 見出しキーワード一致直後に投資有価証券の公正価値内訳表が
        // 挟まっていても、事業別セグメントとして誤って混入させない。
        let escaped =
            "&lt;p&gt;セグメント情報&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;総未実現利益&lt;/td&gt;&lt;td&gt;999&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;" +
            "&lt;p&gt;事業の種類別&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;事業A&lt;/td&gt;&lt;td&gt;500&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("事業A"))
        }
    }

    @Test func segmentInfoExcludesFixedAssetBreakdownTable() {
        // 富士フイルム型の回帰: 見出しキーワード一致直後に無形固定資産の
        // 取得原価/償却累計額/帳簿価額の内訳表が挟まっていても、事業別セグメントとして混入させない。
        let escaped =
            "&lt;p&gt;セグメント情報&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;償却累計額&lt;/td&gt;&lt;td&gt;999&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;" +
            "&lt;p&gt;事業の種類別&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;事業A&lt;/td&gt;&lt;td&gt;500&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("事業A"))
        }
    }

    @Test func segmentInfoExcludesGeographyHeadedTableFromBusinessSegment() {
        // キヤノン型の回帰: 「地域別セグメント情報」という見出しは部分文字列として
        // 「セグメント情報」を含むため、事業別セグメントの検索に誤って混入させない。
        let escaped =
            "&lt;p&gt;地域別セグメント情報&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;日本&lt;/td&gt;&lt;td&gt;500&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;" +
            "&lt;p&gt;報告セグメント&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;事業A&lt;/td&gt;&lt;td&gt;500&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("事業A"))
            #expect(!result.tables[0].markdown.contains("日本"))
        }
    }

    @Test func geographyChainsSecondTableWhenDivWrappedWithShortLabelBetween() {
        // キヤノン型の回帰: 1つの見出し文が前期・当期の両方を紹介し（「第124期及び第125期に
        // おける地域別セグメント情報は...」）、表がそれぞれ個別の <div> でラップされた上で
        // 短いラベル（「第125期」）だけを挟んで連続する。table 自身の nextElementSibling では
        // 2枚目に辿り着けないため、findImmediatelyChainedTable が親（ラッパー div）の兄弟まで
        // 遡って探索し、見出し行が完全一致する場合のみ「同じ開示の続き」として拾う。
        let escaped =
            "&lt;p&gt;第124期及び第125期における地域別セグメント情報は以下のとおりであります。&lt;/p&gt;" +
            "&lt;div&gt;&lt;p&gt;第124期&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;日本&lt;/td&gt;&lt;td&gt;米州&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;100&lt;/td&gt;&lt;td&gt;200&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;&lt;/div&gt;" +
            "&lt;p&gt;第125期&lt;/p&gt;" +
            "&lt;div&gt;&lt;table&gt;&lt;tr&gt;&lt;td&gt;日本&lt;/td&gt;&lt;td&gt;米州&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;110&lt;/td&gt;&lt;td&gt;210&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;&lt;/div&gt;"
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractGeographyInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 2)
            #expect(result.tables[0].markdown.contains("| 100 | 200 |"))
            #expect(result.tables[1].markdown.contains("| 110 | 210 |"))
            #expect(result.tables.map(\.period) == ["前期", "当期"])
        }
    }

    @Test func geographyDoesNotChainWhenFollowingTableHasDifferentShape() {
        // 直後に続く表があっても見出し行（列構成）が異なれば「別の開示」とみなし、
        // 連結ロジック追加前と同じく1枚目だけを採用する（過検出防止の回帰）。
        let escaped =
            "&lt;p&gt;地域別セグメント情報&lt;/p&gt;" +
            "&lt;div&gt;&lt;table&gt;&lt;tr&gt;&lt;td&gt;日本&lt;/td&gt;&lt;td&gt;米州&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;100&lt;/td&gt;&lt;td&gt;200&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;&lt;/div&gt;" +
            "&lt;p&gt;短い注記&lt;/p&gt;" +
            "&lt;div&gt;&lt;table&gt;&lt;tr&gt;&lt;td&gt;資産&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;999&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;&lt;/div&gt;"
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractGeographyInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("| 100 | 200 |"))
        }
    }

    @Test func segmentInfoChainsSecondTableWhenHeaderRowDiffersOnlyByFiscalYearLabel() {
        // 小松製作所型の回帰（issue調査 2026-07-21）: US-GAAP のセグメント注記で前期・当期の表が
        // 直後に連続するが、見出し行（表の1行目）自体に西暦年度ラベル（「2024年度」「2025年度」）が
        // 埋め込まれており完全一致しないため、当期表を取りこぼしていた。年度ラベルのみの違いは
        // 「同じ開示の続き」とみなして拾う必要がある。
        let escaped =
            "&lt;p&gt;セグメント情報&lt;/p&gt;" +
            "&lt;div&gt;&lt;table&gt;" +
            "&lt;tr&gt;&lt;td&gt;2024年度&lt;/td&gt;&lt;td&gt;&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;建設機械・車両&lt;/td&gt;&lt;td&gt;リテールファイナンス&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;100&lt;/td&gt;&lt;td&gt;200&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;/table&gt;&lt;/div&gt;" +
            "&lt;div&gt;&lt;table&gt;" +
            "&lt;tr&gt;&lt;td&gt;2025年度&lt;/td&gt;&lt;td&gt;&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;建設機械・車両&lt;/td&gt;&lt;td&gt;リテールファイナンス&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;110&lt;/td&gt;&lt;td&gt;210&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;/table&gt;&lt;/div&gt;"
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 2)
            #expect(result.tables[0].markdown.contains("100") && result.tables[0].markdown.contains("200"))
            #expect(result.tables[1].markdown.contains("110") && result.tables[1].markdown.contains("210"))
        }
    }

    @Test func segmentInfoDoesNotChainWhenHeaderDiffersBeyondFiscalYearLabel() {
        // 年度ラベル以外にも差異がある場合は「別の開示」とみなし1枚目だけを採用する
        // （過検出防止の回帰。年度ラベル正規化を入れても厳密さを失っていないことを確認）。
        let escaped =
            "&lt;p&gt;セグメント情報&lt;/p&gt;" +
            "&lt;div&gt;&lt;table&gt;" +
            "&lt;tr&gt;&lt;td&gt;2024年度&lt;/td&gt;&lt;td&gt;&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;建設機械・車両&lt;/td&gt;&lt;td&gt;リテールファイナンス&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;100&lt;/td&gt;&lt;td&gt;200&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;/table&gt;&lt;/div&gt;" +
            "&lt;div&gt;&lt;table&gt;" +
            "&lt;tr&gt;&lt;td&gt;資産&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;999&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;/table&gt;&lt;/div&gt;"
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("100") && result.tables[0].markdown.contains("200"))
        }
    }

    @Test func segmentInfoDoesNotChainWhenSameShapeButNonYearHeaderTextDiffers() {
        // Grok 4.5 レビュー指摘の回帰テスト: 列数は同じで年度以外の文言が異なる場合
        // （「2024年度｜売上」対「2025年度｜資産」）は、年度ラベル除去後も不一致のままであるべき
        // （年度ラベル正規化が過検出を広げていないことを、列構成が違う既存の負例より厳密に確認する）。
        let escaped =
            "&lt;p&gt;セグメント情報&lt;/p&gt;" +
            "&lt;div&gt;&lt;table&gt;" +
            "&lt;tr&gt;&lt;td&gt;2024年度&lt;/td&gt;&lt;td&gt;売上&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;建設機械・車両&lt;/td&gt;&lt;td&gt;リテールファイナンス&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;100&lt;/td&gt;&lt;td&gt;200&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;/table&gt;&lt;/div&gt;" +
            "&lt;div&gt;&lt;table&gt;" +
            "&lt;tr&gt;&lt;td&gt;2025年度&lt;/td&gt;&lt;td&gt;資産&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;建設機械・車両&lt;/td&gt;&lt;td&gt;リテールファイナンス&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;110&lt;/td&gt;&lt;td&gt;210&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;/table&gt;&lt;/div&gt;"
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("100") && result.tables[0].markdown.contains("200"))
        }
    }

    // オリックス型フィクスチャ共通のテーブル片。行ラベル（収益・利益・費用）を3件共有させ、
    // Jaccard 一致に必要な最低一致件数（`Xbrl.noteRowLabelMinOverlapCount` = 3）を満たす。
    private func orixStyleSegmentTable(period: String, colA: String, colB: String, values: [String]) -> String {
        "&lt;div&gt;&lt;table&gt;" +
            "&lt;tr&gt;&lt;td&gt;\(period)&lt;/td&gt;&lt;td&gt;\(colA)&lt;/td&gt;&lt;td&gt;\(colB)&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;収益&lt;/td&gt;&lt;td&gt;\(values[0])&lt;/td&gt;&lt;td&gt;\(values[1])&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;利益&lt;/td&gt;&lt;td&gt;\(values[2])&lt;/td&gt;&lt;td&gt;\(values[3])&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;費用&lt;/td&gt;&lt;td&gt;\(values[4])&lt;/td&gt;&lt;td&gt;\(values[5])&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;/table&gt;&lt;/div&gt;"
    }

    @Test func segmentInfoChainsAcrossDifferentColumnViewsWhenRowLabelsMatch() {
        // オリックス型の回帰（issue #103、実データ検証: S100YG5L）: US-GAAP の巨大注記内で
        // 「事業別収益（前期）」→「地域別収益（前期）」→「事業別収益（当期）」→「地域別収益（当期）」
        // の4表が連続する。列見出し（事業名／地域名）は表ごとに異なるため headerRowsMatch は
        // 不一致になるが、各表の行ラベル（収益・利益・費用）は共通しており「同じ開示の別 view」と
        // みなせる。この行ラベル一致が無ければ最初の1表（前期・事業別）で打ち切られ、
        // 当期表（table3）に到達できなかった（実データでも当期表が一切見つからない不具合として
        // 顕在化していた）。
        let escaped =
            "&lt;p&gt;セグメント情報&lt;/p&gt;" +
            orixStyleSegmentTable(period: "前連結会計年度", colA: "事業A", colB: "事業B", values: ["100", "50", "10", "5", "20", "15"]) +
            orixStyleSegmentTable(period: "前連結会計年度", colA: "米州", colB: "欧州", values: ["80", "70", "8", "7", "18", "16"]) +
            orixStyleSegmentTable(period: "当連結会計年度", colA: "事業A", colB: "事業B", values: ["120", "60", "12", "6", "22", "17"]) +
            orixStyleSegmentTable(period: "当連結会計年度", colA: "米州", colB: "欧州", values: ["90", "75", "9", "7", "19", "17"])
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 4)
            #expect(result.tables.map(\.period) == ["前期", "前期", "当期", "当期"])
            #expect(result.tables[2].markdown.contains("120") && result.tables[2].markdown.contains("60"))
            #expect(result.tables[3].markdown.contains("90") && result.tables[3].markdown.contains("75"))
        }
    }

    @Test func segmentInfoDoesNotChainWhenRowLabelOverlapBelowMinimumCount() {
        // Grok 4.5 監査指摘の回帰（2026-07-25）: 行ラベルが2件しか一致しない場合は
        // `Xbrl.noteRowLabelMinOverlapCount`（3）未満のため Jaccard 経路も発火せず、
        // 見出し不一致の表として打ち切られるべき（「収益」「利益」等の一般的な財務語だけが
        // 偶然一致する誤チェーンを防ぐ安全弁）。
        let escaped =
            "&lt;p&gt;セグメント情報&lt;/p&gt;" +
            "&lt;div&gt;&lt;table&gt;" +
            "&lt;tr&gt;&lt;td&gt;前連結会計年度&lt;/td&gt;&lt;td&gt;事業A&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;収益&lt;/td&gt;&lt;td&gt;100&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;利益&lt;/td&gt;&lt;td&gt;10&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;/table&gt;&lt;/div&gt;" +
            "&lt;div&gt;&lt;table&gt;" +
            "&lt;tr&gt;&lt;td&gt;無関係な注記&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;収益&lt;/td&gt;&lt;td&gt;999&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;利益&lt;/td&gt;&lt;td&gt;888&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;資産&lt;/td&gt;&lt;td&gt;777&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;/table&gt;&lt;/div&gt;"
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("100"))
        }
    }

    @Test func segmentInfoDoesNotChainWhenJaccardBelowThresholdDespiteThreeSharedLabels() {
        // Grok 4.5 監査指摘の回帰（2026-07-25）: 一致件数が最低件数（3）を満たしていても、
        // 和集合が大きく Jaccard が閾値（0.6）未満なら「同じ開示の続き」とはみなさない。
        let escaped =
            "&lt;p&gt;セグメント情報&lt;/p&gt;" +
            "&lt;div&gt;&lt;table&gt;" +
            "&lt;tr&gt;&lt;td&gt;前連結会計年度&lt;/td&gt;&lt;td&gt;事業A&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;収益&lt;/td&gt;&lt;td&gt;100&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;利益&lt;/td&gt;&lt;td&gt;10&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;費用&lt;/td&gt;&lt;td&gt;5&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;/table&gt;&lt;/div&gt;" +
            "&lt;div&gt;&lt;table&gt;" +
            "&lt;tr&gt;&lt;td&gt;無関係な注記&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;収益&lt;/td&gt;&lt;td&gt;999&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;利益&lt;/td&gt;&lt;td&gt;888&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;費用&lt;/td&gt;&lt;td&gt;777&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;資産&lt;/td&gt;&lt;td&gt;666&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;負債&lt;/td&gt;&lt;td&gt;555&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;純資産&lt;/td&gt;&lt;td&gt;444&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;/table&gt;&lt;/div&gt;"
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            // 交差3件（収益・利益・費用）/ 和集合6件（+資産・負債・純資産）= Jaccard 0.5 (<0.6) → 不一致
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("100"))
        }
    }

    @Test func geographyDoesNotChainAcrossDifferentMetricsSharingSameRegionRowLabels() {
        // 富士フイルム型の回帰（CI parityWithPythonGolden 差分、2026-07-25、S100W3XJ）:
        // 「売上高の地域別内訳」表と「有形固定資産の地域別内訳」表が隣接し、どちらも行ラベルが
        // 地域名（日本・米州・欧州）で一致するため、地域名を行ラベルとして扱うと
        // Jaccard 0.6（交差3件「日本/米州/欧州」÷ 和集合5件「+売上高合計/有形固定資産合計」、
        // 閾値ちょうど）で誤って連結されてしまう（golden は2表のみを期待）。地域名は複数の
        // 異なる指標の開示で使い回されるため、行ラベルの一致シグナルから除外する必要がある。
        let escaped =
            "&lt;p&gt;地域別&lt;/p&gt;" +
            "&lt;div&gt;&lt;table&gt;" +
            "&lt;tr&gt;&lt;td&gt;前連結会計年度&lt;/td&gt;&lt;td&gt;当連結会計年度&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;日本&lt;/td&gt;&lt;td&gt;1049550&lt;/td&gt;&lt;td&gt;1099302&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;米州&lt;/td&gt;&lt;td&gt;641784&lt;/td&gt;&lt;td&gt;646904&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;欧州&lt;/td&gt;&lt;td&gt;470573&lt;/td&gt;&lt;td&gt;544628&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;売上高合計&lt;/td&gt;&lt;td&gt;2960916&lt;/td&gt;&lt;td&gt;3195828&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;/table&gt;&lt;/div&gt;" +
            "&lt;div&gt;&lt;table&gt;" +
            "&lt;tr&gt;&lt;td&gt;前連結会計年度末&lt;/td&gt;&lt;td&gt;当連結会計年度末&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;日本&lt;/td&gt;&lt;td&gt;385506&lt;/td&gt;&lt;td&gt;408084&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;米州&lt;/td&gt;&lt;td&gt;447731&lt;/td&gt;&lt;td&gt;643690&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;欧州&lt;/td&gt;&lt;td&gt;488537&lt;/td&gt;&lt;td&gt;664752&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;tr&gt;&lt;td&gt;有形固定資産合計&lt;/td&gt;&lt;td&gt;1395735&lt;/td&gt;&lt;td&gt;1786475&lt;/td&gt;&lt;/tr&gt;" +
            "&lt;/table&gt;&lt;/div&gt;"
        let xml = textBlockXml(tag: "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractGeographyInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("売上高合計"))
            #expect(!result.tables[0].markdown.contains("有形固定資産"))
        }
    }

    @Test func segmentInfoPrefersDimensionFactsOverTableWhenBothPresent() throws {
        // 実データ検証の回帰（東京海上・キッコーマン・第一三共、issue調査 2026-07-21）:
        // 専用 TextBlock タグ（`NotesSegmentInformationConsolidatedFinancialStatementsIFRSTextBlock`
        // 等）由来の表と、`OperatingSegmentsAxis` 付き dimension fact の両方が存在する場合、
        // method は決定的な facts を優先する（html_table への表スクレイピングより信頼性が高いため）。
        // ただし tables は破棄せず保持する（Grok 4.5 レビュー指摘: facts の正規化が失敗した場合に
        // LLM の表フォールバックへ回せるようにするため）。
        let escapedTable =
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;ダミー&lt;/td&gt;&lt;td&gt;999&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrli:xbrl
            xmlns:xbrli="\(XBRLTestSupport.nsXbrli)"
            xmlns:xbrldi="http://xbrl.org/2006/xbrldi"
            xmlns:jppfs_cor="\(XBRLTestSupport.nsJppfs)"
            xmlns:jpigp_cor="http://disclosure.edinet-fsa.go.jp/taxonomy/jpigp/2022-11-01/jpigp_cor">
          <xbrli:context id="CurrentYearDuration_SegmentAMember">
            <xbrli:entity>
              <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
            </xbrli:entity>
            <xbrli:period>
              <xbrli:startDate>2023-04-01</xbrli:startDate>
              <xbrli:endDate>2024-03-31</xbrli:endDate>
            </xbrli:period>
            <xbrli:scenario>
              <xbrldi:explicitMember dimension="jppfs_cor:OperatingSegmentsAxis">jppfs_cor:SegmentAMember</xbrldi:explicitMember>
            </xbrli:scenario>
          </xbrli:context>
          <xbrli:unit id="JPY"><xbrli:measure>iso4217:JPY</xbrli:measure></xbrli:unit>
          <jppfs_cor:SalesToExternalCustomersIFRS contextRef="CurrentYearDuration_SegmentAMember" unitRef="JPY" decimals="-6">1000000</jppfs_cor:SalesToExternalCustomersIFRS>
          <jpigp_cor:NotesSegmentInformationConsolidatedFinancialStatementsIFRSTextBlock contextRef="CurrentYearDuration_SegmentAMember">\(escapedTable)</jpigp_cor:NotesSegmentInformationConsolidatedFinancialStatementsIFRSTextBlock>
        </xbrli:xbrl>
        """
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "xbrl_facts")
            #expect(!result.tables.isEmpty)
            let fact = try #require(result.facts.first)
            #expect(fact.tag == "SalesToExternalCustomersIFRS")
        }
    }

    @Test func segmentInfoPrefersTableWhenDimensionFactsHaveNoRecognizedAmountTag() throws {
        // 実データ回帰（キヤノン・富士フイルム、CI parityWithPythonGolden 差分調査 2026-07-22）:
        // OperatingSegmentsAxis 付き fact が存在しても、それが従業員数・設備投資額等の非売上系
        // タグしかない場合は method を html_table のままにする（facts 優先化により誤って
        // xbrl_facts へ倒れ、golden との method 不一致を起こした回帰の再発防止）。
        let escapedTable =
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;ダミー&lt;/td&gt;&lt;td&gt;999&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrli:xbrl
            xmlns:xbrli="\(XBRLTestSupport.nsXbrli)"
            xmlns:xbrldi="http://xbrl.org/2006/xbrldi"
            xmlns:jppfs_cor="\(XBRLTestSupport.nsJppfs)"
            xmlns:jpigp_cor="http://disclosure.edinet-fsa.go.jp/taxonomy/jpigp/2022-11-01/jpigp_cor">
          <xbrli:context id="CurrentYearDuration_SegmentAMember">
            <xbrli:entity>
              <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
            </xbrli:entity>
            <xbrli:period>
              <xbrli:startDate>2023-04-01</xbrli:startDate>
              <xbrli:endDate>2024-03-31</xbrli:endDate>
            </xbrli:period>
            <xbrli:scenario>
              <xbrldi:explicitMember dimension="jppfs_cor:OperatingSegmentsAxis">jppfs_cor:SegmentAMember</xbrldi:explicitMember>
            </xbrli:scenario>
          </xbrli:context>
          <xbrli:unit id="JPY"><xbrli:measure>iso4217:JPY</xbrli:measure></xbrli:unit>
          <jppfs_cor:NumberOfEmployees contextRef="CurrentYearDuration_SegmentAMember" unitRef="JPY" decimals="-6">1000</jppfs_cor:NumberOfEmployees>
          <jpigp_cor:NotesSegmentInformationConsolidatedFinancialStatementsIFRSTextBlock contextRef="CurrentYearDuration_SegmentAMember">\(escapedTable)</jpigp_cor:NotesSegmentInformationConsolidatedFinancialStatementsIFRSTextBlock>
        </xbrli:xbrl>
        """
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(!result.tables.isEmpty)
        }
    }

    @Test func segmentInfoFallsBackToDimensionFacts() throws {
        // TextBlock がない場合は dimension 付き fact にフォールバックする
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrli:xbrl
            xmlns:xbrli="\(XBRLTestSupport.nsXbrli)"
            xmlns:xbrldi="http://xbrl.org/2006/xbrldi"
            xmlns:jppfs_cor="\(XBRLTestSupport.nsJppfs)">
          <xbrli:context id="CurrentYearDuration_SegmentAMember">
            <xbrli:entity>
              <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
            </xbrli:entity>
            <xbrli:period>
              <xbrli:startDate>2023-04-01</xbrli:startDate>
              <xbrli:endDate>2024-03-31</xbrli:endDate>
            </xbrli:period>
            <xbrli:scenario>
              <xbrldi:explicitMember dimension="jppfs_cor:OperatingSegmentsAxis">jppfs_cor:SegmentAMember</xbrldi:explicitMember>
            </xbrli:scenario>
          </xbrli:context>
          <xbrli:unit id="JPY"><xbrli:measure>iso4217:JPY</xbrli:measure></xbrli:unit>
          <jppfs_cor:NetSales contextRef="CurrentYearDuration_SegmentAMember" unitRef="JPY" decimals="-6">1000000</jppfs_cor:NetSales>
        </xbrli:xbrl>
        """
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "xbrl_facts")
            #expect(result.tables.isEmpty)
            let fact = try #require(result.facts.first)
            #expect(fact.tag == "NetSales")
            #expect(fact.contextRef == "CurrentYearDuration_SegmentAMember")
            #expect(fact.dimensions == ["OperatingSegmentsAxis": "SegmentAMember"])
            #expect(fact.value == 1_000_000)
            #expect(fact.unitRef == "JPY")
            #expect(fact.decimals == "-6")

            // 地域別 dimension ではないため geography は not_found
            let geo = BreakdownExtractor.extractGeographyInfo(xbrlDir: dir)
            #expect(geo.method == "not_found")
        }
    }

    // MARK: - 収益認識関係（オークマ型: docs/breakdown-normalization-concept.md 今後の検討事項3）

    @Test func revenueRecognitionInfoFromTextBlock() {
        let xml = textBlockXml(
            tag: "NotesRevenueRecognitionConsolidatedFinancialStatementsTextBlock",
            escapedHtml: "&lt;table&gt;&lt;tr&gt;&lt;td&gt;ＮＣ旋盤&lt;/td&gt;&lt;td&gt;34304&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        )
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractRevenueRecognitionInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("ＮＣ旋盤"))
        }
    }

    /// ブリヂストン・デンソー型: J-GAAP 収益認識関係が stub でも、IFRS「売上収益」注記の表を拾う。
    @Test func revenueRecognitionInfoFromIFRSRevenueTextBlock() {
        let xml = textBlockXml(
            tag: "NotesRevenueConsolidatedFinancialStatementsIFRSTextBlock",
            escapedHtml: "&lt;table&gt;&lt;tr&gt;&lt;td&gt;タイヤ&lt;/td&gt;&lt;td&gt;4137233&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;その他&lt;/td&gt;&lt;td&gt;292863&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        )
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractRevenueRecognitionInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables[0].heading == BreakdownExtractor.revenueRecognitionHeading)
            #expect(result.tables[0].markdown.contains("タイヤ"))
        }
    }

    /// 三菱商事型: NotesRevenue2 の事業グループ別「顧客との契約から認識した収益」。
    @Test func revenueRecognitionInfoFromIFRSRevenue2TextBlock() {
        let xml = textBlockXml(
            tag: "NotesRevenue2ConsolidatedFinancialStatementsIFRSTextBlock",
            escapedHtml: "&lt;table&gt;&lt;tr&gt;&lt;td&gt;&lt;/td&gt;&lt;td&gt;地球環境エネルギー&lt;/td&gt;&lt;td&gt;マテリアルソリューション&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;顧客との契約から認識した収益&lt;/td&gt;&lt;td&gt;1748741&lt;/td&gt;&lt;td&gt;3978475&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        )
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractRevenueRecognitionInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables[0].markdown.contains("地球環境エネルギー"))
            #expect(result.tables[0].markdown.contains("顧客との契約から認識した収益"))
        }
    }

    /// 三菱商事型: セグメント表が売上総利益のみ → Revenue2 の売上相当へ swap。
    @Test func segmentInfoSwapsToRevenue2WhenSegmentTablesLackSalesEquivalent() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrli:xbrl
            xmlns:xbrli="\(XBRLTestSupport.nsXbrli)"
            xmlns:jpcrp_cor="\(XBRLTestSupport.nsJpcrp)"
            xmlns:jpigp_cor="\(XBRLTestSupport.nsJpcrp)">
          <xbrli:context id="CurrentYearDuration">
            <xbrli:entity><xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier></xbrli:entity>
            <xbrli:period><xbrli:startDate>2025-04-01</xbrli:startDate><xbrli:endDate>2026-03-31</xbrli:endDate></xbrli:period>
          </xbrli:context>
          <jpcrp_cor:NotesSegmentInformationConsolidatedFinancialStatementsIFRSTextBlock contextRef="CurrentYearDuration">&lt;table&gt;&lt;tr&gt;&lt;td&gt;地球環境&lt;/td&gt;&lt;td&gt;金属資源&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;売上総利益&lt;/td&gt;&lt;td&gt;100&lt;/td&gt;&lt;td&gt;200&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;</jpcrp_cor:NotesSegmentInformationConsolidatedFinancialStatementsIFRSTextBlock>
          <jpigp_cor:NotesRevenue2ConsolidatedFinancialStatementsIFRSTextBlock contextRef="CurrentYearDuration">&lt;table&gt;&lt;tr&gt;&lt;td&gt;&lt;/td&gt;&lt;td&gt;地球環境エネルギー&lt;/td&gt;&lt;td&gt;金属資源&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;顧客との契約から認識した収益&lt;/td&gt;&lt;td&gt;1748741&lt;/td&gt;&lt;td&gt;1219000&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;</jpigp_cor:NotesRevenue2ConsolidatedFinancialStatementsIFRSTextBlock>
        </xbrli:xbrl>
        """
        // jpigp namespace: use same as jpcrp for test support if needed
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)
            let joined = result.tables.map(\.markdown).joined(separator: "\n")
            #expect(joined.contains("顧客との契約から認識した収益"))
            #expect(joined.contains("地球環境エネルギー"))
        }
    }

    /// あおぞら銀行型: サービス毎の経常収益表をセグメント候補の先頭に結合。
    @Test func segmentInfoPrependsProductOrServiceTables() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrli:xbrl
            xmlns:xbrli="\(XBRLTestSupport.nsXbrli)"
            xmlns:jpcrp_cor="\(XBRLTestSupport.nsJpcrp)">
          <xbrli:context id="CurrentYearDuration">
            <xbrli:entity><xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier></xbrli:entity>
            <xbrli:period><xbrli:startDate>2025-04-01</xbrli:startDate><xbrli:endDate>2026-03-31</xbrli:endDate></xbrli:period>
          </xbrli:context>
          <jpcrp_cor:NotesSegmentInformationEtcConsolidatedFinancialStatementsTextBlock contextRef="CurrentYearDuration">&lt;table&gt;&lt;tr&gt;&lt;td&gt;投資銀行&lt;/td&gt;&lt;td&gt;市場国際&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;連結粗利益&lt;/td&gt;&lt;td&gt;100&lt;/td&gt;&lt;td&gt;200&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;</jpcrp_cor:NotesSegmentInformationEtcConsolidatedFinancialStatementsTextBlock>
          <jpcrp_cor:InformationForEachProductOrServiceTextBlock contextRef="CurrentYearDuration">&lt;table&gt;&lt;tr&gt;&lt;td&gt;貸出業務&lt;/td&gt;&lt;td&gt;有価証券投資業務&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;外部顧客に対する経常収益&lt;/td&gt;&lt;td&gt;140937&lt;/td&gt;&lt;td&gt;45600&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;</jpcrp_cor:InformationForEachProductOrServiceTextBlock>
        </xbrli:xbrl>
        """
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.first?.heading == BreakdownExtractor.productOrServiceHeading)
            #expect(result.tables.first?.markdown.contains("貸出業務") == true)
            #expect(result.tables.first?.markdown.contains("外部顧客に対する経常収益") == true)
            #expect(BreakdownExtractor.tablesContainSalesEquivalent(result.tables))
        }
    }

    /// エーザイ型: IFRS「主要な製品に関する情報」専用タグを製品・サービス別として先頭結合。
    @Test func segmentInfoPrependsIFRSProductsAndServicesTables() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrli:xbrl
            xmlns:xbrli="\(XBRLTestSupport.nsXbrli)"
            xmlns:jpigp_cor="\(XBRLTestSupport.nsJpcrp)">
          <xbrli:context id="CurrentYearDuration">
            <xbrli:entity><xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier></xbrli:entity>
            <xbrli:period><xbrli:startDate>2025-04-01</xbrli:startDate><xbrli:endDate>2026-03-31</xbrli:endDate></xbrli:period>
          </xbrli:context>
          <jpigp_cor:NotesSegmentInformationConsolidatedFinancialStatementsIFRSTextBlock contextRef="CurrentYearDuration">&lt;table&gt;&lt;tr&gt;&lt;td&gt;日本&lt;/td&gt;&lt;td&gt;アメリカス&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;外部顧客への売上収益&lt;/td&gt;&lt;td&gt;229238&lt;/td&gt;&lt;td&gt;300440&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;</jpigp_cor:NotesSegmentInformationConsolidatedFinancialStatementsIFRSTextBlock>
          <jpigp_cor:InformationAboutProductsAndServicesIFRSTextBlock contextRef="CurrentYearDuration">&lt;table&gt;&lt;tr&gt;&lt;td&gt;ニューロロジー領域製品&lt;/td&gt;&lt;td&gt;オンコロジー領域製品&lt;/td&gt;&lt;td&gt;その他&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;外部顧客への売上収益&lt;/td&gt;&lt;td&gt;260568&lt;/td&gt;&lt;td&gt;362668&lt;/td&gt;&lt;td&gt;202142&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;</jpigp_cor:InformationAboutProductsAndServicesIFRSTextBlock>
        </xbrli:xbrl>
        """
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.tables.first?.heading == BreakdownExtractor.productOrServiceHeading)
            let joined = result.tables.map(\.markdown).joined(separator: "\n")
            #expect(joined.contains("ニューロロジー領域製品"))
            #expect(joined.contains("オンコロジー領域製品"))
            #expect(BreakdownExtractor.tablesContainSalesEquivalent(result.tables))
        }
    }

    @Test func tablesContainSalesEquivalentDetectsBankAndContractRevenue() {
        #expect(BreakdownExtractor.tablesContainSalesEquivalent([
            BreakdownTable(heading: "x", markdown: "| 実質業務粗利益 | 100 |", period: nil)
        ]))
        #expect(BreakdownExtractor.tablesContainSalesEquivalent([
            BreakdownTable(heading: "x", markdown: "| 顧客との契約から認識した収益 | 100 |", period: nil)
        ]))
        #expect(!BreakdownExtractor.tablesContainSalesEquivalent([
            BreakdownTable(heading: "x", markdown: "| 売上総利益 | 100 |\n| 純利益 | 50 |", period: nil)
        ]))
    }

    /// 表の外の脚注段落（化工品・多角化等）を収益認識候補の末尾に残す。
    @Test func revenueRecognitionInfoIncludesFootnoteParagraphs() {
        let escaped = """
        &lt;table&gt;&lt;tr&gt;&lt;td&gt;タイヤ(注１)&lt;/td&gt;&lt;td&gt;4137233&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;その他(注２)&lt;/td&gt;&lt;td&gt;292863&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;
        &lt;p&gt;(注１) 「タイヤ」には、当社グループが行っているタイヤ事業及びソリューション事業が含まれております。&lt;/p&gt;
        &lt;p&gt;(注２) 「その他」には、当社グループが行っている化工品・多角化事業等が含まれております。&lt;/p&gt;
        """
        let xml = textBlockXml(
            tag: "NotesRevenueConsolidatedFinancialStatementsIFRSTextBlock",
            escapedHtml: escaped.replacingOccurrences(of: "\n", with: "")
        )
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractRevenueRecognitionInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count >= 2)
            let joined = result.tables.map(\.markdown).joined(separator: "\n")
            #expect(joined.contains("ソリューション"))
            #expect(joined.contains("化工品"))
            #expect(joined.contains("多角化"))
        }
    }

    @Test func revenueTypeOnlyDecompositionDetectsSumitomoLikeTables() {
        let revenueTypeOnly = [
            BreakdownTable(
                heading: "収益認識関係",
                markdown: """
                | 報告セグメント | 日本 | 北米 | 合計 |
                |---|---|---|---|
                | 製商品の販売 | 98011 | 223338 | 368284 |
                | 知的財産権収入 | 308 | 2064 | 2372 |
                """,
                period: "当期"
            ),
        ]
        #expect(BreakdownExtractor.isRevenueTypeOnlyDecomposition(revenueTypeOnly))

        // エーザイ型: 列見出しが医薬品販売/ライセンス供与（脚注の「ライセンス収入」無しでも種類分解）
        let eisaiTypeOnly = [
            BreakdownTable(
                heading: "収益認識関係",
                markdown: """
                | | 医薬品販売による収益 | ライセンス供与による収益 | 合計 |
                |---|---|---|---|
                | 日本 | 226140 | 1725 | 229238 |
                """,
                period: "当期"
            ),
        ]
        #expect(BreakdownExtractor.isRevenueTypeOnlyDecomposition(eisaiTypeOnly))

        let businessRows = [
            BreakdownTable(
                heading: "収益認識関係",
                markdown: """
                | 区分 | 連結計 |
                |---|---|
                | タイヤ | 4137233 |
                | その他 | 292863 |
                """,
                period: "当期"
            ),
        ]
        #expect(!BreakdownExtractor.isRevenueTypeOnlyDecomposition(businessRows))
    }

    @Test func notFoundWhenNoRevenueRecognitionTextBlock() {
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jppfs_cor:NetSales contextRef="CurrentYearDuration" unitRef="JPY" decimals="-6">1000000</jppfs_cor:NetSales>
            """
        )
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractRevenueRecognitionInfo(xbrlDir: dir)
            #expect(result.method == "not_found")
        }
    }

    /// オークマ型（報告セグメントの member が全て地域名）+ 収益認識関係注記ありの合成 XBRL。
    /// `includeRevenueRecognitionBlock: false` で「見つからない」ケースを作れる。
    private func okumaLikeXml(includeRevenueRecognitionBlock: Bool) -> String {
        let revenueBlock = includeRevenueRecognitionBlock
            ? """
              <jpcrp_cor:NotesRevenueRecognitionConsolidatedFinancialStatementsTextBlock contextRef="CurrentYearDuration">&lt;table&gt;&lt;tr&gt;&lt;td&gt;ＮＣ旋盤&lt;/td&gt;&lt;td&gt;34304&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;</jpcrp_cor:NotesRevenueRecognitionConsolidatedFinancialStatementsTextBlock>
              """
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrli:xbrl
            xmlns:xbrli="\(XBRLTestSupport.nsXbrli)"
            xmlns:xbrldi="http://xbrl.org/2006/xbrldi"
            xmlns:jppfs_cor="\(XBRLTestSupport.nsJppfs)"
            xmlns:jpcrp_cor="\(XBRLTestSupport.nsJpcrp)">
          <xbrli:context id="CurrentYearDuration_JapanMember">
            <xbrli:entity>
              <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
            </xbrli:entity>
            <xbrli:period>
              <xbrli:startDate>2023-04-01</xbrli:startDate>
              <xbrli:endDate>2024-03-31</xbrli:endDate>
            </xbrli:period>
            <xbrli:scenario>
              <xbrldi:explicitMember dimension="jppfs_cor:OperatingSegmentsAxis">jppfs_cor:JapanReportableSegmentsMember</xbrldi:explicitMember>
            </xbrli:scenario>
          </xbrli:context>
          <xbrli:context id="CurrentYearDuration_AmericasMember">
            <xbrli:entity>
              <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
            </xbrli:entity>
            <xbrli:period>
              <xbrli:startDate>2023-04-01</xbrli:startDate>
              <xbrli:endDate>2024-03-31</xbrli:endDate>
            </xbrli:period>
            <xbrli:scenario>
              <xbrldi:explicitMember dimension="jppfs_cor:OperatingSegmentsAxis">jppfs_cor:AmericasReportableSegmentsMember</xbrldi:explicitMember>
            </xbrli:scenario>
          </xbrli:context>
          <xbrli:context id="CurrentYearDuration">
            <xbrli:entity>
              <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
            </xbrli:entity>
            <xbrli:period>
              <xbrli:startDate>2023-04-01</xbrli:startDate>
              <xbrli:endDate>2024-03-31</xbrli:endDate>
            </xbrli:period>
          </xbrli:context>
          <xbrli:unit id="JPY"><xbrli:measure>iso4217:JPY</xbrli:measure></xbrli:unit>
          <jppfs_cor:RevenuesFromExternalCustomers contextRef="CurrentYearDuration_JapanMember" unitRef="JPY" decimals="-6">600000</jppfs_cor:RevenuesFromExternalCustomers>
          <jppfs_cor:RevenuesFromExternalCustomers contextRef="CurrentYearDuration_AmericasMember" unitRef="JPY" decimals="-6">400000</jppfs_cor:RevenuesFromExternalCustomers>
          \(revenueBlock)
        </xbrli:xbrl>
        """
    }

    @Test func segmentInfoSwapsToRevenueRecognitionWhenAxisIsGeography() throws {
        // オークマ型の回帰: 報告セグメントの member が全て地域名（Japan/Americas）だと、
        // 収益認識関係注記に本当の事業別（製品別）データが見つかればそちらを segments として返す。
        let xml = okumaLikeXml(includeRevenueRecognitionBlock: true)
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.facts.isEmpty)
            let table = try #require(result.tables.first)
            #expect(table.markdown.contains("ＮＣ旋盤"))
        }
    }

    /// ブリヂストン型: geography facts + IFRS 売上収益（タイヤ/その他）→ swap。
    @Test func segmentInfoSwapsToIFRSRevenueWhenAxisIsGeography() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrli:xbrl
            xmlns:xbrli="\(XBRLTestSupport.nsXbrli)"
            xmlns:xbrldi="http://xbrl.org/2006/xbrldi"
            xmlns:jppfs_cor="\(XBRLTestSupport.nsJppfs)"
            xmlns:jpcrp_cor="\(XBRLTestSupport.nsJpcrp)">
          <xbrli:context id="CurrentYearDuration_JapanMember">
            <xbrli:entity><xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier></xbrli:entity>
            <xbrli:period><xbrli:startDate>2024-01-01</xbrli:startDate><xbrli:endDate>2024-12-31</xbrli:endDate></xbrli:period>
            <xbrli:scenario>
              <xbrldi:explicitMember dimension="jppfs_cor:OperatingSegmentsAxis">jppfs_cor:JapanReportableSegmentMember</xbrldi:explicitMember>
            </xbrli:scenario>
          </xbrli:context>
          <xbrli:context id="CurrentYearDuration_AmericasMember">
            <xbrli:entity><xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier></xbrli:entity>
            <xbrli:period><xbrli:startDate>2024-01-01</xbrli:startDate><xbrli:endDate>2024-12-31</xbrli:endDate></xbrli:period>
            <xbrli:scenario>
              <xbrldi:explicitMember dimension="jppfs_cor:OperatingSegmentsAxis">jppfs_cor:TheAmericasReportableSegmentMember</xbrldi:explicitMember>
            </xbrli:scenario>
          </xbrli:context>
          <xbrli:context id="CurrentYearDuration">
            <xbrli:entity><xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier></xbrli:entity>
            <xbrli:period><xbrli:startDate>2024-01-01</xbrli:startDate><xbrli:endDate>2024-12-31</xbrli:endDate></xbrli:period>
          </xbrli:context>
          <xbrli:context id="CurrentYearInstant_OtherOperatingSegmentsAxisMember">
            <xbrli:entity><xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier></xbrli:entity>
            <xbrli:period><xbrli:instant>2024-12-31</xbrli:instant></xbrli:period>
            <xbrli:scenario>
              <xbrldi:explicitMember dimension="jppfs_cor:OperatingSegmentsAxis">jppfs_cor:OtherOperatingSegmentsAxisMember</xbrldi:explicitMember>
            </xbrli:scenario>
          </xbrli:context>
          <xbrli:unit id="JPY"><xbrli:measure>iso4217:JPY</xbrli:measure></xbrli:unit>
          <xbrli:unit id="pure"><xbrli:measure>xbrli:pure</xbrli:measure></xbrli:unit>
          <jppfs_cor:RevenuesFromExternalCustomers contextRef="CurrentYearDuration_JapanMember" unitRef="JPY" decimals="-6">600000</jppfs_cor:RevenuesFromExternalCustomers>
          <jppfs_cor:RevenuesFromExternalCustomers contextRef="CurrentYearDuration_AmericasMember" unitRef="JPY" decimals="-6">400000</jppfs_cor:RevenuesFromExternalCustomers>
          <!-- 非金額ファクトが軸判定を壊さないこと（ブリヂストン実データ） -->
          <jpcrp_cor:NumberOfEmployees contextRef="CurrentYearInstant_OtherOperatingSegmentsAxisMember" unitRef="pure" decimals="0">7630</jpcrp_cor:NumberOfEmployees>
          <jpcrp_cor:NotesRevenueConsolidatedFinancialStatementsIFRSTextBlock contextRef="CurrentYearDuration">&lt;table&gt;&lt;tr&gt;&lt;td&gt;タイヤ&lt;/td&gt;&lt;td&gt;4137233&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;その他&lt;/td&gt;&lt;td&gt;292863&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;</jpcrp_cor:NotesRevenueConsolidatedFinancialStatementsIFRSTextBlock>
        </xbrli:xbrl>
        """
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.first?.markdown.contains("タイヤ") == true)
        }
    }

    /// 住友ファーマ型: IFRS 売上収益が収益種類（製商品/知的財産）だけのときは swap しない。
    @Test func segmentInfoKeepsGeographyWhenIFRSRevenueIsRevenueTypeOnly() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrli:xbrl
            xmlns:xbrli="\(XBRLTestSupport.nsXbrli)"
            xmlns:xbrldi="http://xbrl.org/2006/xbrldi"
            xmlns:jppfs_cor="\(XBRLTestSupport.nsJppfs)"
            xmlns:jpcrp_cor="\(XBRLTestSupport.nsJpcrp)">
          <xbrli:context id="CurrentYearDuration_JapanMember">
            <xbrli:entity><xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier></xbrli:entity>
            <xbrli:period><xbrli:startDate>2024-04-01</xbrli:startDate><xbrli:endDate>2025-03-31</xbrli:endDate></xbrli:period>
            <xbrli:scenario>
              <xbrldi:explicitMember dimension="jppfs_cor:OperatingSegmentsAxis">jppfs_cor:JapanReportableSegmentMember</xbrldi:explicitMember>
            </xbrli:scenario>
          </xbrli:context>
          <xbrli:context id="CurrentYearDuration_AsiaMember">
            <xbrli:entity><xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier></xbrli:entity>
            <xbrli:period><xbrli:startDate>2024-04-01</xbrli:startDate><xbrli:endDate>2025-03-31</xbrli:endDate></xbrli:period>
            <xbrli:scenario>
              <xbrldi:explicitMember dimension="jppfs_cor:OperatingSegmentsAxis">jppfs_cor:AsiaReportableSegmentMember</xbrldi:explicitMember>
            </xbrli:scenario>
          </xbrli:context>
          <xbrli:context id="CurrentYearDuration">
            <xbrli:entity><xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier></xbrli:entity>
            <xbrli:period><xbrli:startDate>2024-04-01</xbrli:startDate><xbrli:endDate>2025-03-31</xbrli:endDate></xbrli:period>
          </xbrli:context>
          <xbrli:unit id="JPY"><xbrli:measure>iso4217:JPY</xbrli:measure></xbrli:unit>
          <jppfs_cor:RevenuesFromExternalCustomers contextRef="CurrentYearDuration_JapanMember" unitRef="JPY" decimals="-6">600000</jppfs_cor:RevenuesFromExternalCustomers>
          <jppfs_cor:RevenuesFromExternalCustomers contextRef="CurrentYearDuration_AsiaMember" unitRef="JPY" decimals="-6">400000</jppfs_cor:RevenuesFromExternalCustomers>
          <jpcrp_cor:NotesRevenueConsolidatedFinancialStatementsIFRSTextBlock contextRef="CurrentYearDuration">&lt;table&gt;&lt;tr&gt;&lt;td&gt;製商品の販売&lt;/td&gt;&lt;td&gt;368284&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;知的財産権収入&lt;/td&gt;&lt;td&gt;2372&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;</jpcrp_cor:NotesRevenueConsolidatedFinancialStatementsIFRSTextBlock>
        </xbrli:xbrl>
        """
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "xbrl_facts")
            #expect(result.facts.count == 2)
        }
    }

    /// メルカリ型: 地域 facts + セグメント内の製品マトリクス。RR が契約負債だけの stub なら swap しない。
    @Test func segmentInfoKeepsMarketplaceMatrixWhenRevenueRecognitionIsContractLiabilityStub() throws {
        let segmentTable = """
        &lt;table&gt;&lt;tr&gt;&lt;td&gt;&lt;/td&gt;&lt;td&gt;Japan Region&lt;/td&gt;&lt;td&gt;US&lt;/td&gt;&lt;td&gt;連結&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;売上収益&lt;/td&gt;&lt;td&gt;&lt;/td&gt;&lt;td&gt;&lt;/td&gt;&lt;td&gt;&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;Marketplace&lt;/td&gt;&lt;td&gt;111200&lt;/td&gt;&lt;td&gt;36418&lt;/td&gt;&lt;td&gt;147618&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;Fintech&lt;/td&gt;&lt;td&gt;38597&lt;/td&gt;&lt;td&gt;-&lt;/td&gt;&lt;td&gt;38597&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;その他&lt;/td&gt;&lt;td&gt;8&lt;/td&gt;&lt;td&gt;-&lt;/td&gt;&lt;td&gt;6416&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;
        """
        let rrStub = """
        &lt;table&gt;&lt;tr&gt;&lt;td&gt;顧客との契約から生じた債権&lt;/td&gt;&lt;td&gt;7933&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;契約負債&lt;/td&gt;&lt;td&gt;2445&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;
        """
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrli:xbrl
            xmlns:xbrli="\(XBRLTestSupport.nsXbrli)"
            xmlns:xbrldi="http://xbrl.org/2006/xbrldi"
            xmlns:jppfs_cor="\(XBRLTestSupport.nsJppfs)"
            xmlns:jpcrp_cor="\(XBRLTestSupport.nsJpcrp)"
            xmlns:jpigp_cor="\(XBRLTestSupport.nsJpcrp)">
          <xbrli:context id="CurrentYearDuration_JapanRegionMember">
            <xbrli:entity><xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier></xbrli:entity>
            <xbrli:period><xbrli:startDate>2024-07-01</xbrli:startDate><xbrli:endDate>2025-06-30</xbrli:endDate></xbrli:period>
            <xbrli:scenario>
              <xbrldi:explicitMember dimension="jppfs_cor:OperatingSegmentsAxis">jppfs_cor:JapanRegionReportableSegmentMember</xbrldi:explicitMember>
            </xbrli:scenario>
          </xbrli:context>
          <xbrli:context id="CurrentYearDuration_USMember">
            <xbrli:entity><xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier></xbrli:entity>
            <xbrli:period><xbrli:startDate>2024-07-01</xbrli:startDate><xbrli:endDate>2025-06-30</xbrli:endDate></xbrli:period>
            <xbrli:scenario>
              <xbrldi:explicitMember dimension="jppfs_cor:OperatingSegmentsAxis">jppfs_cor:USReportableSegmentMember</xbrldi:explicitMember>
            </xbrli:scenario>
          </xbrli:context>
          <xbrli:context id="CurrentYearDuration">
            <xbrli:entity><xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier></xbrli:entity>
            <xbrli:period><xbrli:startDate>2024-07-01</xbrli:startDate><xbrli:endDate>2025-06-30</xbrli:endDate></xbrli:period>
          </xbrli:context>
          <xbrli:unit id="JPY"><xbrli:measure>iso4217:JPY</xbrli:measure></xbrli:unit>
          <jppfs_cor:RevenueFromExternalCustomersIFRS contextRef="CurrentYearDuration_JapanRegionMember" unitRef="JPY" decimals="-6">149807000000</jppfs_cor:RevenueFromExternalCustomersIFRS>
          <jppfs_cor:RevenueFromExternalCustomersIFRS contextRef="CurrentYearDuration_USMember" unitRef="JPY" decimals="-6">36418000000</jppfs_cor:RevenueFromExternalCustomersIFRS>
          <jpigp_cor:NotesSegmentInformationConsolidatedFinancialStatementsIFRSTextBlock contextRef="CurrentYearDuration">\(segmentTable)</jpigp_cor:NotesSegmentInformationConsolidatedFinancialStatementsIFRSTextBlock>
          <jpigp_cor:NotesRevenueConsolidatedFinancialStatementsIFRSTextBlock contextRef="CurrentYearDuration">\(rrStub)</jpigp_cor:NotesRevenueConsolidatedFinancialStatementsIFRSTextBlock>
        </xbrli:xbrl>
        """
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "xbrl_facts")
            let members = Set(result.facts.compactMap { $0.dimensions["OperatingSegmentsAxis"] })
            #expect(members.contains("JapanRegionReportableSegmentMember"))
            #expect(members.contains("USReportableSegmentMember"))
            let joined = result.tables.map(\.markdown).joined(separator: "\n")
            #expect(joined.contains("Marketplace"))
            #expect(joined.contains("Fintech"))
            #expect(result.tables.first?.heading != BreakdownExtractor.revenueRecognitionHeading)
        }
    }

    @Test func segmentInfoKeepsGeographyFactsWhenRevenueRecognitionNotFound() throws {
        // 収益認識関係注記が見つからない場合は、表示が消える(not_found)のではなく
        // 元の地域別 xbrl_facts をそのまま維持する（未検証企業での誤判定時の regression 回避）。
        let xml = okumaLikeXml(includeRevenueRecognitionBlock: false)
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "xbrl_facts")
            #expect(result.facts.count == 2)
            let members = result.facts.compactMap { $0.dimensions["OperatingSegmentsAxis"] }.sorted()
            #expect(members == ["AmericasReportableSegmentsMember", "JapanReportableSegmentsMember"])
        }
    }

    @Test func segmentInfoFallsBackToRevenueRecognitionWhenSegmentsNotFound() throws {
        // 東京エレクトロン型: 単一セグメントで報告セグメント事実が無く not_found だが、
        // 収益認識関係に製品・サービス別（新規装置等）があればそちらを segments として返す。
        let xml = textBlockXml(
            tag: "NotesRevenueRecognitionConsolidatedFinancialStatementsTextBlock",
            escapedHtml: "&lt;table&gt;&lt;tr&gt;&lt;td&gt;新規装置&lt;/td&gt;&lt;td&gt;1817250&lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;フィールドソリューション他&lt;/td&gt;&lt;td&gt;626282&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        )
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            let markdown = try #require(result.tables.first?.markdown)
            #expect(markdown.contains("新規装置"))
            #expect(markdown.contains("フィールドソリューション他"))
        }
    }

    // MARK: - toDictionary（JSON 出力）

    @Test func toDictionarySerializesWithOptionalKeysOmitted() throws {
        let result = ExtractedBreakdown(
            method: "html_table",
            tables: [
                BreakdownTable(heading: "セグメント情報", markdown: "| A |", period: "当期"),
                BreakdownTable(heading: "セグメント情報", markdown: "| B |", period: nil),
            ],
            facts: [
                BreakdownFact(
                    tag: "NetSales", contextRef: "ctx", dimensions: ["Axis": "Member"],
                    value: 100, label: nil, unitRef: nil, decimals: nil
                ),
            ]
        )
        let dict = result.toDictionary()
        #expect(JSONSerialization.isValidJSONObject(dict))

        let tables = try #require(dict["tables"] as? [[String: Any]])
        #expect(tables[0]["period"] as? String == "当期")
        #expect(tables[1]["period"] == nil)  // nil は出力しない（Python NotRequired と同じ）

        let facts = try #require(dict["facts"] as? [[String: Any]])
        #expect(facts[0]["label"] == nil)
        #expect(facts[0]["value"] as? Double == 100)
    }

    @Test func notFoundWhenNoSegmentData() {
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jppfs_cor:NetSales contextRef="CurrentYearDuration" unitRef="JPY" decimals="-6">1000000</jppfs_cor:NetSales>
            """
        )
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "not_found")
            #expect(result.tables.isEmpty)
            #expect(result.facts.isEmpty)
        }
    }

    @Test func detectSingleSegmentDisclosureFindsDedicatedTag() {
        // 千葉銀行型の回帰（issue調査 2026-07-21）: 単一セグメントのため記載省略の旨は
        // EDINET/JPCRP タクソノミの専用タグ（TextBlockではない）で開示される。
        let xml = textBlockXml(
            tag: "DescriptionOfFactThatCompanysBusinessComprisesSingleSegment",
            escapedHtml: "当行グループは、銀行業の単一セグメントであるため、記載を省略しております。"
        )
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let disclosure = BreakdownExtractor.detectSingleSegmentDisclosure(xbrlDir: dir)
            #expect(disclosure == "当行グループは、銀行業の単一セグメントであるため、記載を省略しております。")
        }
    }

    @Test func detectSingleSegmentDisclosureReturnsNilWhenTagAbsent() {
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jppfs_cor:NetSales contextRef="CurrentYearDuration" unitRef="JPY" decimals="-6">1000000</jppfs_cor:NetSales>
            """
        )
        XBRLTestSupport.withXbrlDir(xml) { dir in
            #expect(BreakdownExtractor.detectSingleSegmentDisclosure(xbrlDir: dir) == nil)
        }
    }

    // MARK: - classifyNotApplicableReason（issue #130、E/F判定の検知結果明示化）

    /// E判定: 報告セグメントが地域別のみ（オークマ型 member 構成）の xbrl_facts は geographyOnly。
    @Test func classifyNotApplicableReasonDetectsGeographyOnly() {
        let segments = ExtractedBreakdown(
            method: "xbrl_facts",
            tables: [],
            facts: [
                BreakdownFact(
                    tag: "RevenuesFromExternalCustomers",
                    contextRef: "CurrentYearDuration_JapanReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "JapanReportableSegmentsMember"],
                    value: 61_753_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
                BreakdownFact(
                    tag: "RevenuesFromExternalCustomers",
                    contextRef: "CurrentYearDuration_AmericasReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "AmericasReportableSegmentsMember"],
                    value: 63_016_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
            ]
        )
        XBRLTestSupport.withXbrlDir(nil) { dir in
            let reason = BreakdownExtractor.classifyNotApplicableReason(
                segments: segments, consolidatedSales: 124_769_000_000, xbrlDir: dir)
            #expect(reason == .geographyOnly)
        }
    }

    /// F判定: セグメント注記自体が無く（not_found）、単一セグメント開示省略の専用タグがあれば
    /// singleSegmentDisclosed。
    @Test func classifyNotApplicableReasonDetectsSingleSegmentDisclosed() {
        let segments = ExtractedBreakdown(method: "not_found", tables: [], facts: [])
        let xml = textBlockXml(
            tag: "DescriptionOfFactThatCompanysBusinessComprisesSingleSegment",
            escapedHtml: "当行グループは、銀行業の単一セグメントであるため、記載を省略しております。"
        )
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let reason = BreakdownExtractor.classifyNotApplicableReason(
                segments: segments, consolidatedSales: 1_000_000, xbrlDir: dir)
            #expect(reason == .singleSegmentDisclosed)
        }
    }

    /// 地域軸でも単一セグメント開示でもない not_found は unknown（要調査）。
    @Test func classifyNotApplicableReasonFallsBackToUnknown() {
        let segments = ExtractedBreakdown(method: "not_found", tables: [], facts: [])
        XBRLTestSupport.withXbrlDir(nil) { dir in
            let reason = BreakdownExtractor.classifyNotApplicableReason(
                segments: segments, consolidatedSales: 1_000_000, xbrlDir: dir)
            #expect(reason == .unknown)
        }
    }

    /// issue #135: html_table 経由で LLM が「地域別のみ」と判定した場合（method=="html_table"
    /// のため xbrl_facts 経路の判定は効かない）でも、llmHint 経由で geographyOnly を拾えること。
    @Test func classifyNotApplicableReasonDetectsGeographyOnlyFromLlmHint() {
        let segments = ExtractedBreakdown(
            method: "html_table",
            tables: [BreakdownTable(heading: "収益認識関係", markdown: "| 地域 | 金額 |", period: "当期")],
            facts: [])
        XBRLTestSupport.withXbrlDir(nil) { dir in
            let reason = BreakdownExtractor.classifyNotApplicableReason(
                segments: segments, consolidatedSales: 1_000_000, xbrlDir: dir,
                llmHint: "geography_only")
            #expect(reason == .geographyOnly)
        }
    }

    /// llmHint が geography_only 以外（"other" 等）のときは既存の判定（今回は unknown）へ
    /// フォールバックする。LLM の "other" 判定を無条件に geographyOnly 扱いしないことの回帰防止。
    @Test func classifyNotApplicableReasonIgnoresNonGeographyLlmHint() {
        let segments = ExtractedBreakdown(
            method: "html_table",
            tables: [BreakdownTable(heading: "セグメント情報", markdown: "| 製品 | 金額 |", period: "当期")],
            facts: [])
        XBRLTestSupport.withXbrlDir(nil) { dir in
            let reason = BreakdownExtractor.classifyNotApplicableReason(
                segments: segments, consolidatedSales: 1_000_000, xbrlDir: dir, llmHint: "other")
            #expect(reason == .unknown)
        }
    }
}

// MARK: - Python ゴールデンファイルとのパリティ検証

/// smoke/breakdown_extraction_expected.json（Python 実装の出力）と tmp_cache/edinet/ の
/// キャッシュ済み XBRL から Swift 実装の出力を突き合わせる。
/// BLT_EDINET_API_KEY が設定されていれば不足分を自動ダウンロードする（SmokeCacheSupport）。
/// 未設定かつキャッシュも無い docID は個別に SKIP する。
@Suite struct SegmentParityTests {

    @Test func parityWithPythonGolden() async throws {
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let goldenPath = projectRoot.appendingPathComponent("smoke/breakdown_extraction_expected.json")
        let xbrlBase = SmokeCacheSupport.cacheDir

        guard FileManager.default.fileExists(atPath: goldenPath.path) else {
            print("SKIP   smoke/breakdown_extraction_expected.json が見つかりません")
            return
        }

        let data = try Data(contentsOf: goldenPath)
        let golden = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        await SmokeCacheSupport.ensureCached(golden.keys)

        var diffs: [String] = []
        var checked = 0

        for (docID, expected) in golden.sorted(by: { $0.key < $1.key }) {
            let xbrlDir = xbrlBase.appendingPathComponent("\(docID)_xbrl")
            guard FileManager.default.fileExists(atPath: xbrlDir.path) else {
                print("SKIP   \(docID): XBRL キャッシュなし")
                continue
            }
            checked += 1

            let actuals = [
                ("segments", BreakdownExtractor.extractSegmentInfo(xbrlDir: xbrlDir)),
                ("geography", BreakdownExtractor.extractGeographyInfo(xbrlDir: xbrlDir)),
            ]
            for (kind, actual) in actuals {
                guard let exp = expected[kind] as? [String: Any] else { continue }
                diffs.append(contentsOf: compare(exp, actual, label: "\(docID).\(kind)"))
            }
        }

        print("PARITY \(checked) docs checked, \(diffs.count) diffs")
        for d in diffs.prefix(20) { print("DIFF   \(d)") }
        // SwiftSoup.Comment との曖昧性を避けるためモジュール修飾する（CI の Xcode で曖昧エラー）
        #expect(diffs.isEmpty, Testing.Comment(rawValue: "パリティ差分:\n" + diffs.joined(separator: "\n")))
    }

    private func compare(_ expected: [String: Any], _ actual: ExtractedBreakdown, label: String) -> [String] {
        var diffs: [String] = []

        let expMethod = expected["method"] as? String ?? ""
        if expMethod != actual.method {
            diffs.append("\(label): method \(expMethod) != \(actual.method)")
            return diffs
        }

        // tables: リスト順も含めて比較
        let expTables = expected["tables"] as? [[String: Any]] ?? []
        if expTables.count != actual.tables.count {
            diffs.append("\(label): tables 件数 \(expTables.count) != \(actual.tables.count)")
        } else {
            for (i, (exp, act)) in zip(expTables, actual.tables).enumerated() {
                if exp["heading"] as? String != act.heading {
                    diffs.append("\(label): tables[\(i)].heading \(exp["heading"] ?? "nil") != \(act.heading)")
                }
                if exp["period"] as? String != act.period {
                    diffs.append("\(label): tables[\(i)].period \(exp["period"] ?? "nil") != \(act.period ?? "nil")")
                }
                if exp["markdown"] as? String != act.markdown {
                    diffs.append("\(label): tables[\(i)].markdown 不一致\n--- expected\n\(exp["markdown"] ?? "")\n--- actual\n\(act.markdown)")
                }
            }
        }

        // facts: 順序不定のため (tag, contextRef) でソートして比較
        let expFacts = (expected["facts"] as? [[String: Any]] ?? []).sorted {
            (($0["tag"] as? String ?? ""), ($0["contextRef"] as? String ?? ""))
                < (($1["tag"] as? String ?? ""), ($1["contextRef"] as? String ?? ""))
        }
        if expFacts.count != actual.facts.count {
            diffs.append("\(label): facts 件数 \(expFacts.count) != \(actual.facts.count)")
            return diffs
        }
        for (i, (exp, act)) in zip(expFacts, actual.facts).enumerated() {
            let key = "\(label): facts[\(i)] (\(act.tag), \(act.contextRef))"
            if exp["tag"] as? String != act.tag || exp["contextRef"] as? String != act.contextRef {
                diffs.append("\(key): tag/contextRef 不一致 expected (\(exp["tag"] ?? ""), \(exp["contextRef"] ?? ""))")
                continue
            }
            if exp["dimensions"] as? [String: String] != act.dimensions {
                diffs.append("\(key): dimensions \(exp["dimensions"] ?? [:]) != \(act.dimensions)")
            }
            let expValue = (exp["value"] as? NSNumber)?.doubleValue
            if expValue != act.value {
                diffs.append("\(key): value \(expValue.map { String($0) } ?? "nil") != \(act.value)")
            }
            if exp["label"] as? String != act.label {
                diffs.append("\(key): label \(exp["label"] ?? "nil") != \(act.label ?? "nil")")
            }
            if exp["unitRef"] as? String != act.unitRef {
                diffs.append("\(key): unitRef \(exp["unitRef"] ?? "nil") != \(act.unitRef ?? "nil")")
            }
            if exp["decimals"] as? String != act.decimals {
                diffs.append("\(key): decimals \(exp["decimals"] ?? "nil") != \(act.decimals ?? "nil")")
            }
        }
        return diffs
    }
}
