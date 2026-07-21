// SegmentExtractor のユニットテスト
// Python tests/test_segment_extractor.py 相当＋TextBlock/dimension fact 統合テスト

// 注意: このファイルで SwiftSoup を import しないこと。
// SwiftSoup.Comment が #expect マクロ展開の生成する Comment と曖昧衝突し、
// CI のツールチェーンでコンパイルエラーになる。HTML パースは XBRLTestSupport 経由で行う。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct SegmentExtractorTests {

    // MARK: - gridToMarkdown

    @Test func gridToMarkdownSimple2x2() {
        let md = SegmentExtractor.gridToMarkdown([["A", "B"], ["1", "2"]])
        #expect(md.contains("| A | B |"))
        #expect(md.contains("| 1 | 2 |"))
        #expect(md.contains("---"))
    }

    @Test func gridToMarkdownEmptyGridReturnsEmpty() {
        #expect(SegmentExtractor.gridToMarkdown([]) == "")
    }

    @Test func gridToMarkdownHeaderSeparatorAfterFirstRow() {
        let md = SegmentExtractor.gridToMarkdown([["Header"], ["Value"]])
        #expect(md.split(separator: "\n").count == 3)  // header / separator / value
    }

    @Test func gridToMarkdownColumnsArePaddedToMaxWidth() {
        let md = SegmentExtractor.gridToMarkdown([["Short", "A very long column header"]])
        #expect(md.contains("A very long column header"))
    }

    @Test func gridToMarkdownSingleRow() {
        let md = SegmentExtractor.gridToMarkdown([["Only", "Row"]])
        #expect(md.contains("Only"))
        #expect(md.contains("Row"))
    }

    // MARK: - detectPeriodFromGrid

    @Test func detectPeriodCurrentPeriod() {
        #expect(SegmentExtractor.detectPeriodFromGrid([["当連結会計年度", "数値"], ["売上高", "1000"]]) == "当期")
    }

    @Test func detectPeriodPriorPeriod() {
        #expect(SegmentExtractor.detectPeriodFromGrid([["前連結会計年度", "数値"], ["売上高", "900"]]) == "前期")
    }

    @Test func detectPeriodComparisonWhenBothPresent() {
        #expect(SegmentExtractor.detectPeriodFromGrid([["前連結会計年度", "当連結会計年度"], ["900", "1000"]]) == "比較")
    }

    @Test func detectPeriodShortFormCurrent() {
        #expect(SegmentExtractor.detectPeriodFromGrid([["当期", "数値"]]) == "当期")
    }

    @Test func detectPeriodShortFormPrior() {
        #expect(SegmentExtractor.detectPeriodFromGrid([["前期", "数値"]]) == "前期")
    }

    @Test func detectPeriodNoKeywordReturnsNil() {
        #expect(SegmentExtractor.detectPeriodFromGrid([["セグメント", "売上高"], ["事業A", "500"]]) == nil)
    }

    @Test func detectPeriodOnlyChecksFirst3Rows() {
        let grid = [
            ["セグメント名", "値"],
            ["事業A", "100"],
            ["事業B", "200"],
            ["当連結会計年度の合計", "300"],
        ]
        #expect(SegmentExtractor.detectPeriodFromGrid(grid) == nil)
    }

    @Test func detectPeriodEmptyGridReturnsNil() {
        #expect(SegmentExtractor.detectPeriodFromGrid([]) == nil)
    }

    // MARK: - applyPeriodOrdering

    @Test func periodOrderingUnlabeledGetsAlternatingLabels() {
        var tables = ["A", "B", "C", "D"].map {
            SegmentTable(heading: "セグメント情報", markdown: "| \($0) |", period: nil)
        }
        SegmentExtractor.applyPeriodOrdering(&tables)
        #expect(tables.map(\.period) == ["前期", "当期", "前期", "当期"])
    }

    @Test func periodOrderingAlreadyLabeledIsNotChanged() {
        var tables = [
            SegmentTable(heading: "X", markdown: "| 1 |", period: "当期"),
            SegmentTable(heading: "X", markdown: "| 2 |", period: nil),
        ]
        SegmentExtractor.applyPeriodOrdering(&tables)
        #expect(tables[0].period == "当期")
        #expect(tables[1].period == "前期")
    }

    @Test func periodOrderingAllLabeledUnchanged() {
        var tables = [SegmentTable(heading: "X", markdown: "| 1 |", period: "比較")]
        SegmentExtractor.applyPeriodOrdering(&tables)
        #expect(tables[0].period == "比較")
    }

    @Test func periodOrderingEmptyListDoesNothing() {
        var tables: [SegmentTable] = []
        SegmentExtractor.applyPeriodOrdering(&tables)
        #expect(tables.isEmpty)
    }

    // MARK: - expandTable

    @Test func expandTableSimple() throws {
        let table = try XBRLTestSupport.parseFirstTable("<table><tr><td>A</td><td>B</td></tr><tr><td>1</td><td>2</td></tr></table>")
        #expect(SegmentExtractor.expandTable(table) == [["A", "B"], ["1", "2"]])
    }

    @Test func expandTableColspanExpandsCell() throws {
        let table = try XBRLTestSupport.parseFirstTable("<table><tr><td colspan='2'>合計</td></tr><tr><td>事業A</td><td>100</td></tr></table>")
        let grid = SegmentExtractor.expandTable(table)
        #expect(grid[0] == ["合計", "合計"])
        #expect(grid[1] == ["事業A", "100"])
    }

    @Test func expandTableRowspanRepeatsCellDownward() throws {
        let table = try XBRLTestSupport.parseFirstTable("<table><tr><td rowspan='2'>期間</td><td>Q1</td></tr><tr><td>Q2</td></tr></table>")
        let grid = SegmentExtractor.expandTable(table)
        #expect(grid[0][0] == "期間")
        #expect(grid[1][0] == "期間")
        #expect(grid[0][1] == "Q1")
        #expect(grid[1][1] == "Q2")
    }

    @Test func expandTableEmptyTableReturnsEmpty() throws {
        let table = try XBRLTestSupport.parseFirstTable("<table></table>")
        #expect(SegmentExtractor.expandTable(table).isEmpty)
    }

    @Test func expandTableStripsWhitespaceFromCells() throws {
        let table = try XBRLTestSupport.parseFirstTable("<table><tr><td>  事業A  </td><td>  100  </td></tr></table>")
        #expect(SegmentExtractor.expandTable(table)[0] == ["事業A", "100"])
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractGeographyInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractGeographyInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractGeographyInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractGeographyInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractGeographyInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("100") && result.tables[0].markdown.contains("200"))
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
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
            let geo = SegmentExtractor.extractGeographyInfo(xbrlDir: dir)
            #expect(geo.method == "not_found")
        }
    }

    // MARK: - 収益認識関係（オークマ型: docs/segment-normalization-concept.md 今後の検討事項3）

    @Test func revenueRecognitionInfoFromTextBlock() {
        let xml = textBlockXml(
            tag: "NotesRevenueRecognitionConsolidatedFinancialStatementsTextBlock",
            escapedHtml: "&lt;table&gt;&lt;tr&gt;&lt;td&gt;ＮＣ旋盤&lt;/td&gt;&lt;td&gt;34304&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        )
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = SegmentExtractor.extractRevenueRecognitionInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].markdown.contains("ＮＣ旋盤"))
        }
    }

    @Test func notFoundWhenNoRevenueRecognitionTextBlock() {
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jppfs_cor:NetSales contextRef="CurrentYearDuration" unitRef="JPY" decimals="-6">1000000</jppfs_cor:NetSales>
            """
        )
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = SegmentExtractor.extractRevenueRecognitionInfo(xbrlDir: dir)
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
          <jppfs_cor:NetSales contextRef="CurrentYearDuration_JapanMember" unitRef="JPY" decimals="-6">600000</jppfs_cor:NetSales>
          <jppfs_cor:NetSales contextRef="CurrentYearDuration_AmericasMember" unitRef="JPY" decimals="-6">400000</jppfs_cor:NetSales>
          \(revenueBlock)
        </xbrli:xbrl>
        """
    }

    @Test func segmentInfoSwapsToRevenueRecognitionWhenAxisIsGeography() throws {
        // オークマ型の回帰: 報告セグメントの member が全て地域名（Japan/Americas）だと、
        // 収益認識関係注記に本当の事業別（製品別）データが見つかればそちらを segments として返す。
        let xml = okumaLikeXml(includeRevenueRecognitionBlock: true)
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.facts.isEmpty)
            let table = try #require(result.tables.first)
            #expect(table.markdown.contains("ＮＣ旋盤"))
        }
    }

    @Test func segmentInfoKeepsGeographyFactsWhenRevenueRecognitionNotFound() throws {
        // 収益認識関係注記が見つからない場合は、表示が消える(not_found)のではなく
        // 元の地域別 xbrl_facts をそのまま維持する（未検証企業での誤判定時の regression 回避）。
        let xml = okumaLikeXml(includeRevenueRecognitionBlock: false)
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            let markdown = try #require(result.tables.first?.markdown)
            #expect(markdown.contains("新規装置"))
            #expect(markdown.contains("フィールドソリューション他"))
        }
    }

    // MARK: - toDictionary（JSON 出力）

    @Test func toDictionarySerializesWithOptionalKeysOmitted() throws {
        let result = SegmentResult(
            method: "html_table",
            tables: [
                SegmentTable(heading: "セグメント情報", markdown: "| A |", period: "当期"),
                SegmentTable(heading: "セグメント情報", markdown: "| B |", period: nil),
            ],
            facts: [
                SegmentFact(
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
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
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
            let disclosure = SegmentExtractor.detectSingleSegmentDisclosure(xbrlDir: dir)
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
            #expect(SegmentExtractor.detectSingleSegmentDisclosure(xbrlDir: dir) == nil)
        }
    }
}

// MARK: - Python ゴールデンファイルとのパリティ検証

/// smoke/segment_expected.json（Python 実装の出力）と tmp_cache/edinet/ の
/// キャッシュ済み XBRL から Swift 実装の出力を突き合わせる。
/// BLT_EDINET_API_KEY が設定されていれば不足分を自動ダウンロードする（SmokeCacheSupport）。
/// 未設定かつキャッシュも無い docID は個別に SKIP する。
@Suite struct SegmentParityTests {

    @Test func parityWithPythonGolden() async throws {
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let goldenPath = projectRoot.appendingPathComponent("smoke/segment_expected.json")
        let xbrlBase = SmokeCacheSupport.cacheDir

        guard FileManager.default.fileExists(atPath: goldenPath.path) else {
            print("SKIP   smoke/segment_expected.json が見つかりません")
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
                ("segments", SegmentExtractor.extractSegmentInfo(xbrlDir: xbrlDir)),
                ("geography", SegmentExtractor.extractGeographyInfo(xbrlDir: xbrlDir)),
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

    private func compare(_ expected: [String: Any], _ actual: SegmentResult, label: String) -> [String] {
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
