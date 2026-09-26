// 当期/前期ラベル: キャプション遡及・同一レイアウト隣接対・単独表 fallback。
// 公開 payload の形は変えない（periodBasis は内部のみ）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct BreakdownPeriodLabelTests {

    private func numericPairTable(_ a: String, _ b: String, _ total: String) -> String {
        """
        <table>
          <tr><td>報告セグメント</td><td>事業A</td><td>事業B</td><td>合計</td></tr>
          <tr><td>売上高</td><td>\(a)</td><td>\(b)</td><td>\(total)</td></tr>
        </table>
        """
    }

    // MARK: - (a) identical pair with captions (nested, not immediate sibling)

    @Test func identicalPairCaptionsWalkBackPastUnitRowAndWrapper() {
        // 27/29 件の実開示: キャプションは表の一段上（単位行・div 越し）。
        let html = """
            <div>
              <p>前連結会計年度（自 2024年4月1日 至 2025年3月31日）</p>
              <div>
                <p>（単位：百万円）</p>
                \(numericPairTable("100", "50", "150"))
              </div>
              <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
              <div>
                <p>（単位：百万円）</p>
                \(numericPairTable("120", "60", "180"))
              </div>
            </div>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(
            html, defaultHeading: "セグメント情報", fiscalYearEnd: "2026-03-31")
        #expect(tables.count == 2)
        #expect(tables.map(\.period) == ["前期", "当期"])
        #expect(tables.map(\.periodBasis) == [.caption, .caption])
        #expect(tables[0].markdown.contains("150"))
        #expect(tables[1].markdown.contains("180"))
        let keyword = BreakdownExtractor.keywordTablesFromHtml(
            "<p>セグメント情報</p>" + html,
            keywords: ["セグメント情報"],
            fiscalYearEnd: "2026-03-31")
        #expect(keyword.map(\.period) == ["前期", "当期"])
        #expect(keyword.map(\.periodBasis) == [.caption, .caption])
    }

    @Test func captionDateRangeWithoutPeriodWordsUsesFiscalYearEnd() {
        let html = """
            <p>（自 2024年4月1日 至 2025年3月31日）</p>
            \(numericPairTable("100", "50", "150"))
            <p>（自 2025年4月1日 至 2026年3月31日）</p>
            \(numericPairTable("120", "60", "180"))
            """
        let tables = BreakdownExtractor.allTablesFromHtml(
            html, defaultHeading: "収益認識関係", fiscalYearEnd: "2026-03-31")
        #expect(tables.map(\.period) == ["前期", "当期"])
        #expect(tables.map(\.periodBasis) == [.caption, .caption])
    }

    @Test func secondTableDoesNotInheritFirstTableCaption() {
        let html = """
            <p>前連結会計年度（自 2024年4月1日 至 2025年3月31日）</p>
            \(numericPairTable("100", "50", "150"))
            \(numericPairTable("120", "60", "180"))
            """
        let tables = BreakdownExtractor.allTablesFromHtml(
            html, defaultHeading: "セグメント情報")
        #expect(tables[0].period == "前期")
        #expect(tables[0].periodBasis == .caption)
        #expect(tables[1].period == "当期")
        #expect(tables[1].periodBasis == .pair)
    }

    // MARK: - (b) identical pair without captions (7203-like)

    @Test func identicalPairWithoutCaptionsUsesPosition() {
        let html =
            numericPairTable("3,245,000", "1,100,000", "4,345,000")
            + numericPairTable("3,410,000", "1,200,000", "4,610,000")
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
        #expect(tables.count == 2)
        #expect(tables.map(\.period) == ["前期", "当期"])
        #expect(tables.map(\.periodBasis) == [.pair, .pair])
        let keyword = BreakdownExtractor.keywordTablesFromHtml(
            "<p>セグメント情報</p>" + html, keywords: ["セグメント情報"])
        #expect(keyword.map(\.period) == ["前期", "当期"])
        #expect(keyword.map(\.periodBasis) == [.pair, .pair])
    }

    @Test func twoIdenticalPairsAlternatePriorCurrent() {
        var tables = (0..<4).map { i in
            BreakdownTable(
                heading: "セグメント情報",
                markdown: "| 事業A | \(100 + i) |\n| 事業B | \(50 + i) |",
                period: nil)
        }
        BreakdownExtractor.applyPeriodOrdering(&tables)
        #expect(tables.map(\.period) == ["前期", "当期", "前期", "当期"])
        #expect(tables.allSatisfy { $0.periodBasis == .pair })
    }

    // MARK: - (c) 前事業年度/当事業年度 header (4888-like)

    @Test func businessYearColumnHeadersAreComparison() {
        let html = """
            <table>
              <tr><td></td><td>前事業年度</td><td>当事業年度</td></tr>
              <tr><td>日本</td><td>100</td><td>120</td></tr>
              <tr><td>海外</td><td>80</td><td>90</td></tr>
            </table>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "地域ごとの情報")
        #expect(tables.count == 1)
        #expect(tables[0].period == "比較")
        #expect(tables[0].periodBasis == .header)
    }

    @Test func businessYearCaptionsLabelAdjacentPair() {
        let html = """
            <p>前事業年度</p>
            \(numericPairTable("10", "20", "30"))
            <p>当事業年度</p>
            \(numericPairTable("11", "21", "32"))
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "地域ごとの情報")
        #expect(tables.map(\.period) == ["前期", "当期"])
        #expect(tables.map(\.periodBasis) == [.caption, .caption])
    }

    @Test func nendoColumnHeadersAreComparison() {
        #expect(
            BreakdownExtractor.parsePeriodCue("前年度 当年度", allowBareComparison: true) == "比較")
        #expect(
            BreakdownExtractor.parsePeriodCue("前年度及び当年度のセグメント情報は以下のとおりであります。")
                == nil)
    }

    // MARK: - (d) lone current table must not become 前期

    @Test func loneUnlabeledNumericTableIsCurrentNotPrior() {
        let html = numericPairTable("38840", "14246", "59479")
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "地域ごとの情報")
        #expect(tables.count == 1)
        #expect(tables[0].period == "当期")
        #expect(tables[0].periodBasis == .fallback)
        let keyword = BreakdownExtractor.keywordTablesFromHtml(
            "<p>地域ごとの情報</p>" + html, keywords: ["地域ごとの情報"])
        #expect(keyword.count == 1)
        #expect(keyword[0].period == "当期")
        #expect(keyword[0].periodBasis == .fallback)
    }

    @Test func loneTableWithCurrentCaptionIsCurrent() {
        let html = """
            <div>
              <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
              <div>
                <p>（単位：百万円）</p>
                \(numericPairTable("110", "30", "140"))
              </div>
            </div>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
        #expect(tables.count == 1)
        #expect(tables[0].period == "当期")
        #expect(tables[0].periodBasis == .caption)
    }

    @Test func differentShapeNeighborsDoNotPairAsPrior() {
        let html = """
            <table>
              <tr><td>報告セグメント</td><td>事業A</td><td>合計</td></tr>
              <tr><td>売上高</td><td>100</td><td>100</td></tr>
            </table>
            <table>
              <tr><td>日本</td><td>海外</td></tr>
              <tr><td>80</td><td>20</td></tr>
            </table>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
        #expect(tables.count == 2)
        #expect(tables.map(\.period) == ["当期", "当期"])
        #expect(tables.map(\.periodBasis) == [.fallback, .fallback])
    }

    // MARK: - (e) existing correct cases unchanged

    @Test func immediateSiblingCaptionsStillWin() {
        let html = """
            <p>前連結会計年度</p>
            \(numericPairTable("100", "50", "150"))
            <p>当連結会計年度</p>
            \(numericPairTable("120", "60", "180"))
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
        #expect(tables.map(\.period) == ["前期", "当期"])
        #expect(tables.map(\.periodBasis) == [.caption, .caption])
    }

    @Test func comparisonHeaderStillComparison() {
        let html = """
            <table>
              <tr><td></td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>売上高</td><td>900</td><td>1000</td></tr>
            </table>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
        #expect(tables.count == 1)
        #expect(tables[0].period == "比較")
        #expect(tables[0].periodBasis == .header)
    }

    @Test func dedicatedContextRefStillLabelsSingleUnlabeledTable() {
        let html =
            "&lt;p&gt;(1)売上高&lt;/p&gt;"
            + "&lt;table&gt;&lt;tr&gt;&lt;td&gt;日本&lt;/td&gt;&lt;td&gt;海外&lt;/td&gt;&lt;/tr&gt;"
            + "&lt;tr&gt;&lt;td&gt;110&lt;/td&gt;&lt;td&gt;30&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jpcrp_cor:RevenuesFromExternalCustomersInformationForEachRegionTextBlock contextRef="CurrentYearDuration">\(html)</jpcrp_cor:RevenuesFromExternalCustomersInformationForEachRegionTextBlock>
            """
        )
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = BreakdownExtractor.extractGeographyInfo(xbrlDir: dir)
            #expect(result.tables.count == 1)
            #expect(result.tables[0].period == "当期")
            #expect(result.tables[0].periodBasis == .contextRef)
        }
    }

    @Test func periodBasisIsOmittedFromPublicDictionary() {
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: "| 1 |", period: "当期",
            periodBasis: .fallback)
        let dict = ExtractedBreakdown(method: "html_table", tables: [table], facts: []).toDictionary()
        let tables = dict["tables"] as? [[String: Any]]
        #expect(tables?.first?["period"] as? String == "当期")
        #expect(tables?.first?["periodBasis"] == nil)
    }

    @Test func currentFiscalYearEndParsesContext() {
        let xml = XBRLTestSupport.makeXbrlDuration("")
        #expect(BreakdownExtractor.currentFiscalYearEnd(in: xml) == "2024-03-31")
    }

    @Test func fiscalYearLabelUsesDocumentFY() {
        #expect(
            BreakdownExtractor.parsePeriodCue("2025年度", fiscalYearEnd: "2026-03-31") == "当期")
        #expect(
            BreakdownExtractor.parsePeriodCue("2024年度", fiscalYearEnd: "2026-03-31") == "前期")
        #expect(
            BreakdownExtractor.parsePeriodCue("2024年度 2025年度", fiscalYearEnd: "2026-03-31")
                == "比較")
    }
}
