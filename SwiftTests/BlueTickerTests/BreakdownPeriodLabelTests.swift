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

    @Test func nendoDateRangeColumnHeadersAreComparison() {
        // クボタ S100XR0M 地域ごと: 列が 前年度(自…至…) | 当年度(自…至…)。
        // 旧語彙は 前連結会計年度 のみで、lone-table fallback が 当期 にしていた。
        let html = """
            <table>
              <tr><td></td><td>前年度(自　2024年１月１日至　2024年12月31日)</td><td>当年度(自　2025年１月１日至　2025年12月31日)</td></tr>
              <tr><td>日本</td><td>632,476</td><td>685,184</td></tr>
              <tr><td>北米</td><td>1,272,503</td><td>1,218,454</td></tr>
              <tr><td>計</td><td>3,016,281</td><td>3,018,891</td></tr>
            </table>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(
            html, defaultHeading: "地域ごとの情報", fiscalYearEnd: "2025-12-31")
        #expect(tables.count == 1)
        #expect(tables[0].period == "比較")
        #expect(tables[0].periodBasis == .header)
    }

    @Test func ikoubiDateCaptionIsPrior() {
        #expect(
            BreakdownExtractor.parsePeriodCue("移行日(2023年４月１日)", fiscalYearEnd: "2025-03-31")
                == "前期")
        let html = """
            <p>移行日(2023年４月１日)</p>
            \(numericPairTable("100", "50", "150"))
            <p>前連結会計年度（自 2023年4月1日 至 2024年3月31日）</p>
            \(numericPairTable("110", "55", "165"))
            <p>当連結会計年度（自 2024年4月1日 至 2025年3月31日）</p>
            \(numericPairTable("120", "60", "180"))
            """
        let tables = BreakdownExtractor.allTablesFromHtml(
            html, defaultHeading: "セグメント情報", fiscalYearEnd: "2025-03-31")
        #expect(tables.map(\.period) == ["前期", "前期", "当期"])
        #expect(tables.map(\.periodBasis) == [.caption, .caption, .caption])
    }

    @Test func relatedInfoSectionHeadingCoversGeographyAndCustomers() {
        // ニチレイ型: 【関連情報】の 前連結会計年度 が見出しで、地域・有形・顧客表が続く。
        let html = """
            <div>
              <p>【関連情報】</p>
              <p>前連結会計年度（自 2023年4月1日 至 2024年3月31日）</p>
              <p>２．地域ごとの情報</p>
              <p>(1)売上高</p>
              <table>
                <tr><td>日本</td><td>海外</td><td>合計</td></tr>
                <tr><td>535,076</td><td>145,014</td><td>680,091</td></tr>
              </table>
              <p>(2)有形固定資産</p>
              <table>
                <tr><td>日本</td><td>海外</td><td>合計</td></tr>
                <tr><td>163,227</td><td>43,857</td><td>207,084</td></tr>
              </table>
              <p>３．主要な顧客ごとの情報</p>
              <table>
                <tr><td>顧客の名称又は氏名</td><td>売上高</td></tr>
                <tr><td>三菱食品株式会社</td><td>77,181</td></tr>
              </table>
              <p>当連結会計年度（自 2024年4月1日 至 2025年3月31日）</p>
              <p>２．地域ごとの情報</p>
              <p>(1)売上高</p>
              <table>
                <tr><td>日本</td><td>海外</td><td>合計</td></tr>
                <tr><td>536,293</td><td>165,787</td><td>702,080</td></tr>
              </table>
            </div>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(
            html, defaultHeading: "セグメント情報", fiscalYearEnd: "2025-03-31")
        #expect(tables.map(\.period) == ["前期", "前期", "前期", "当期"])
        #expect(tables.map(\.periodBasis) == [.caption, .caption, .caption, .caption])
    }

    @Test func comparisonHeaderAfterCurrentCaptionStaysComparison() {
        let html = """
            <p>当連結会計年度（自 2024年4月1日 至 2025年3月31日）</p>
            \(numericPairTable("120", "60", "180"))
            <p>(4) 地域別に関する情報</p>
            <table>
              <tr><td></td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>日本</td><td>100</td><td>120</td></tr>
            </table>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(
            html, defaultHeading: "セグメント情報", fiscalYearEnd: "2025-03-31")
        #expect(tables.map(\.period) == ["当期", "比較"])
        #expect(tables[1].periodBasis == .header)
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

    // MARK: - compound words and ancestor prose must not stamp 前期

    @Test func parsePeriodCueIgnoresCompoundWords() {
        #expect(BreakdownExtractor.parsePeriodCue("当期純利益") == nil)
        #expect(BreakdownExtractor.parsePeriodCue("当期純損失") == nil)
        #expect(BreakdownExtractor.parsePeriodCue("当期利益") == nil)
        #expect(BreakdownExtractor.parsePeriodCue("当期損失") == nil)
        #expect(BreakdownExtractor.parsePeriodCue("前期比") == nil)
        #expect(BreakdownExtractor.parsePeriodCue("前年度比") == nil)
        #expect(BreakdownExtractor.parsePeriodCue("前年同期比") == nil)
        #expect(BreakdownExtractor.parsePeriodCue("前期末比") == nil)
        #expect(BreakdownExtractor.parsePeriodCue("前期末") == "前期")
        #expect(BreakdownExtractor.parsePeriodCue("当期末") == "当期")
    }

    @Test func captionLikeRejectsIntroProseButKeepsPeriodHeadings() {
        #expect(
            BreakdownExtractor.isCaptionLikePeriodText(
                "当連結会計年度において、当社グループの売上高は増加しました。") == false)
        #expect(
            BreakdownExtractor.isCaptionLikePeriodText(
                "前連結会計年度（自 2024年4月1日 至 2025年3月31日）") == true)
        #expect(BreakdownExtractor.isCaptionLikePeriodText("前期末") == true)
        #expect(BreakdownExtractor.isCaptionLikePeriodText("前期比増減") == false)
        #expect(BreakdownExtractor.isCaptionLikePeriodText("当期純利益") == false)
        #expect(BreakdownExtractor.isCaptionLikePeriodText("第119期") == true)
        #expect(BreakdownExtractor.isCaptionLikePeriodText("第120期") == true)
        #expect(
            BreakdownExtractor.isCaptionLikePeriodText(
                "第119期及び第120期におけるセグメント情報は以下のとおりであります。") == false)
    }

    @Test func consecutiveEraCaptionsStaySeparateTablesWithCaptions() {
        let html = """
            <div>
              <p>第119期</p>
              \(numericPairTable("100", "50", "150"))
              <p>第120期</p>
              \(numericPairTable("120", "60", "180"))
            </div>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(
            html, defaultHeading: "セグメント情報", fiscalYearEnd: "2020-12-31")
        #expect(tables.count == 2)
        #expect(tables[0].precedingCaption?.contains("第119期") == true)
        #expect(tables[1].precedingCaption?.contains("第120期") == true)
    }

    @Test func tableUnderPriorYearChangeCaptionStaysCurrent() {
        let html = """
            <div>
              <p>前期比増減</p>
              <div>
                <p>（単位：百万円）</p>
                \(numericPairTable("120", "60", "180"))
              </div>
            </div>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
        #expect(tables.count == 1)
        #expect(tables[0].period == "当期")
        #expect(tables[0].periodBasis == .fallback)
    }

    @Test func tableUnderNetIncomeCaptionStaysCurrent() {
        let html = """
            <div>
              <p>当期純利益</p>
              <div>
                \(numericPairTable("120", "60", "180"))
              </div>
            </div>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
        #expect(tables.count == 1)
        #expect(tables[0].period == "当期")
        #expect(tables[0].periodBasis == .fallback)
    }

    @Test func ancestorIntroSentenceDoesNotLabelTable() {
        let html = """
            <div>
              <p>当連結会計年度において、当社グループは報告セグメントの区分を変更しております。</p>
              <div>
                <p>（単位：百万円）</p>
                \(numericPairTable("120", "60", "180"))
              </div>
            </div>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
        #expect(tables.count == 1)
        #expect(tables[0].period == "当期")
        #expect(tables[0].periodBasis == .fallback)
    }

    @Test func barePeriodEndCaptionsStillLabel() {
        let html = """
            <p>前期末</p>
            \(numericPairTable("100", "50", "150"))
            <p>当期末</p>
            \(numericPairTable("120", "60", "180"))
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
        #expect(tables.map(\.period) == ["前期", "当期"])
        #expect(tables.map(\.periodBasis) == [.caption, .caption])
    }
}
