// 積み上げセグメント損益表の決定論寄せ（富士フイルム型）のユニットテスト。
// 同一事業ラベルが指標ブロックごとに繰り返され、末尾「XXX計」だけが指標名を持つ表で、
// 研究開発費ブロックを profit に誤寄せしないこと（実測: S100YIBH / S100W3XJ）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct StackedSegmentPnLNormalizerTests {

    /// S100YIBH（富士フイルム FY2026-03 米国基準）の積み上げ表 Markdown（抽出器実測）。
    private static let yibhMarkdown = """
        |             |  | 前連結会計年度(百万円) |  | 当連結会計年度(百万円) |
        |-------------|--|--------------|--|--------------|
        | ヘルスケア       |  | 1,047,754    |  | 1,098,925    |
        | エレクトロニクス    |  | 407,607      |  | 456,157      |
        | ビジネスイノベーション |  | 1,198,494    |  | 1,174,800    |
        | イメージング      |  | 541,973      |  | 627,087      |
        | 売上高 計       |  | 3,195,828    |  | 3,356,969    |
        | ヘルスケア       |  | 61,279       |  | 53,346       |
        | エレクトロニクス    |  | 25,179       |  | 28,209       |
        | ビジネスイノベーション |  | 54,507       |  | 55,406       |
        | イメージング      |  | 13,329       |  | 13,366       |
        | 研究開発費 計     |  | 154,294      |  | 150,327      |
        | ヘルスケア       |  | 906,593      |  | 981,942      |
        | エレクトロニクス    |  | 307,360      |  | 327,065      |
        | ビジネスイノベーション |  | 1,069,373    |  | 1,055,682    |
        | イメージング      |  | 389,430      |  | 453,718      |
        | その他費用 計     |  | 2,672,756    |  | 2,818,407    |
        | ヘルスケア       |  | 79,882       |  | 63,637       |
        | エレクトロニクス    |  | 75,068       |  | 100,883      |
        | ビジネスイノベーション |  | 74,614       |  | 63,712       |
        | イメージング      |  | 139,214      |  | 160,003      |
        | 営業利益 計      |  | 368,778      |  | 388,235      |
        | 全社費用等       |  | △38,623      |  | △38,025      |
        | 連結営業利益      |  | 330,155      |  | 350,210      |
        """

    @Test func yibhMapsOperatingProfitNotResearchAndDevelopment() throws {
        let sales = 3_356_969 * Financial.millionYen
        let snapshot = try #require(
            StackedSegmentPnLNormalizer.normalizeMarkdown(
                Self.yibhMarkdown, consolidatedSales: sales))

        #expect(snapshot.axis == breakdownAxisProductService)
        #expect(snapshot.sourceKind == "stacked_segment_pnl")
        #expect(snapshot.needsReview == false)

        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        #expect(segments.count == 4)

        let byLabel = Dictionary(uniqueKeysWithValues: segments.map { ($0.labelRaw, $0) })
        #expect(byLabel["ヘルスケア"]?.amount == 1_098_925 * Financial.millionYen)
        #expect(byLabel["ヘルスケア"]?.profit == 63_637 * Financial.millionYen)
        #expect(byLabel["エレクトロニクス"]?.amount == 456_157 * Financial.millionYen)
        #expect(byLabel["エレクトロニクス"]?.profit == 100_883 * Financial.millionYen)
        #expect(byLabel["ビジネスイノベーション"]?.amount == 1_174_800 * Financial.millionYen)
        #expect(byLabel["ビジネスイノベーション"]?.profit == 63_712 * Financial.millionYen)
        #expect(byLabel["イメージング"]?.amount == 627_087 * Financial.millionYen)
        #expect(byLabel["イメージング"]?.profit == 160_003 * Financial.millionYen)

        // 研究開発費（HC 53,346 等）を profit に載せていないこと。
        #expect(byLabel["ヘルスケア"]?.profit != 53_346 * Financial.millionYen)
        #expect(byLabel["エレクトロニクス"]?.profit != 28_209 * Financial.millionYen)

        let subtotal = try #require(snapshot.rows.first { $0.rowKind == "subtotal" })
        #expect(subtotal.amount == 3_356_969 * Financial.millionYen)
        #expect(subtotal.profit == 388_235 * Financial.millionYen)
    }

    @Test func returnsNilWhenOnlySalesBlockExists() {
        let markdown = """
            |  | 当連結会計年度(百万円) |
            |--|--|
            | 事業A | 100 |
            | 事業B | 200 |
            | 売上高 計 | 300 |
            """
        #expect(
            StackedSegmentPnLNormalizer.normalizeMarkdown(
                markdown, consolidatedSales: 300 * Financial.millionYen) == nil)
    }

    @Test func returnsNilForColumnOrientedSegmentTable() {
        // キヤノン型（列=事業、行=指標）は積み上げパターンに該当しない。
        let markdown = """
            |  | 印刷 | メディカル | 計 |
            |--|--|--|--|
            | 外部顧客への売上高 | 100 | 50 | 150 |
            | 営業利益 | 10 | 5 | 15 |
            """
        #expect(
            StackedSegmentPnLNormalizer.normalizeMarkdown(
                markdown, consolidatedSales: 150 * Financial.millionYen) == nil)
    }

    // MARK: - 期間積み上げ・事業列型（野村 S100YC5C［事業別セグメント］: 期間を縦に積んだ事業列の表）

    /// 野村 S100YC5C［事業別セグメント］の表（金額は原本どおり）。
    static let nomuraSegmentHTML = """
        <p>［事業別セグメント］</p>
        <table>
          <tr><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td>（単位：百万円）</td></tr>
          <tr><td></td><td>ウェルス・マネジメント部門</td><td></td><td>インベストメント・マネジメント部門</td><td></td><td>ホールセール部門</td><td></td><td>バンキング部門</td><td></td><td>その他（消去分を含む）</td><td></td><td>計</td></tr>
          <tr><td>2025年３月期</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
          <tr><td>金融収益以外の収益</td><td>422,617</td><td></td><td>181,010</td><td></td><td>1,015,803</td><td></td><td>36,344</td><td></td><td>154,657</td><td></td><td>1,810,431</td></tr>
          <tr><td>純金融収益</td><td>10,934</td><td></td><td>11,463</td><td></td><td>42,135</td><td></td><td>10,828</td><td></td><td>8,243</td><td></td><td>83,603</td></tr>
          <tr><td>収益合計（金融費用控除後）</td><td>433,551</td><td></td><td>192,473</td><td></td><td>1,057,938</td><td></td><td>47,172</td><td></td><td>162,900</td><td></td><td>1,894,034</td></tr>
          <tr><td>金融費用以外の費用(1)</td><td>267,369</td><td></td><td>102,882</td><td></td><td>891,656</td><td></td><td>30,815</td><td></td><td>127,799</td><td></td><td>1,420,521</td></tr>
          <tr><td>税引前当期純利益</td><td>166,182</td><td></td><td>89,591</td><td></td><td>166,282</td><td></td><td>16,357</td><td></td><td>35,101</td><td></td><td>473,513</td></tr>
          <tr><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
          <tr><td>2026年３月期</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
          <tr><td>金融収益以外の収益</td><td>473,282</td><td></td><td>248,388</td><td></td><td>1,168,966</td><td></td><td>42,081</td><td></td><td>147,858</td><td></td><td>2,080,575</td></tr>
          <tr><td>純金融収益</td><td>14,624</td><td></td><td>10,128</td><td></td><td>△6,737</td><td></td><td>11,837</td><td></td><td>49,015</td><td></td><td>78,867</td></tr>
          <tr><td>収益合計（金融費用控除後）</td><td>487,906</td><td></td><td>258,516</td><td></td><td>1,162,229</td><td></td><td>53,918</td><td></td><td>196,873</td><td></td><td>2,159,442</td></tr>
          <tr><td>金融費用以外の費用(1)</td><td>283,882</td><td></td><td>170,219</td><td></td><td>961,662</td><td></td><td>39,902</td><td></td><td>172,227</td><td></td><td>1,627,892</td></tr>
          <tr><td>税引前当期純利益</td><td>204,024</td><td></td><td>88,297</td><td></td><td>200,567</td><td></td><td>14,016</td><td></td><td>24,646</td><td></td><td>531,550</td></tr>
        </table>
        """

    private static func m(_ n: Int) -> Double { Double(n) * Financial.millionYen }

    private static func nomuraMarkdown() throws -> String {
        let tables = BreakdownExtractor.allTablesFromHtml(
            nomuraSegmentHTML, defaultHeading: "セグメント情報")
        return try #require(tables.first).markdown
    }

    /// 当期（2026年３月期）ブロックの純収益と税引前利益を事業別に取る。損益計算書の「収益合計」
    /// 4,758,486（総額）とは基準が違うので、事業列の和＝「計」2,159,442 を分母にする。
    @Test func nomuraPeriodStackedColumnsUsesCurrentBlockAndTableTotal() throws {
        let snapshot = try #require(StackedSegmentPnLNormalizer.normalizePeriodStackedColumns(
            try Self.nomuraMarkdown(), consolidatedSales: Self.m(4_758_486)))
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        #expect(segments.map(\.labelRaw) == [
            "ウェルス・マネジメント部門", "インベストメント・マネジメント部門", "ホールセール部門",
            "バンキング部門", "その他（消去分を含む）",
        ])
        #expect(segments.map(\.amount) == [
            Self.m(487_906), Self.m(258_516), Self.m(1_162_229), Self.m(53_918), Self.m(196_873),
        ])
        #expect(segments.map(\.profit) == [
            Self.m(204_024), Self.m(88_297), Self.m(200_567), Self.m(14_016), Self.m(24_646),
        ])
        let total = try #require(snapshot.rows.first { $0.rowKind == "subtotal" })
        #expect(total.labelRaw == "計")
        #expect(total.amount == Self.m(2_159_442))
        #expect(total.profit == Self.m(531_550))
        #expect(snapshot.denominator == Self.m(2_159_442))
        #expect(snapshot.denominatorTag == "stacked_table_sales_total")
        #expect(snapshot.sourceKind == "stacked_segment_pnl")
        #expect(!snapshot.needsReview)
    }

    /// normalize（表リスト）経由でも同じ結果（富士フイルム型の normalizeMarkdown は nil）。
    @Test func nomuraNormalizeFallsThroughToPeriodStackedColumns() throws {
        let md = try Self.nomuraMarkdown()
        #expect(StackedSegmentPnLNormalizer.normalizeMarkdown(
            md, consolidatedSales: Self.m(4_758_486)) == nil)
        let snapshot = try #require(StackedSegmentPnLNormalizer.normalize(
            ExtractedBreakdown(
                method: "html_table",
                tables: [BreakdownTable(heading: "セグメント情報", markdown: md, period: nil)],
                facts: []),
            consolidatedSales: Self.m(4_758_486)))
        #expect(snapshot.denominator == Self.m(2_159_442))
    }

    /// fail closed: 売上行が純収益でなく（売上高合計）、損益計算書売上とも整合しなければ採用しない。
    @Test func periodStackedColumnsRejectsGrossLabelWithMismatchedSales() throws {
        let md = try Self.nomuraMarkdown()
            .replacingOccurrences(of: "収益合計（金融費用控除後）", with: "売上高合計")
        #expect(StackedSegmentPnLNormalizer.normalizePeriodStackedColumns(
            md, consolidatedSales: Self.m(4_758_486)) == nil)
    }

    /// fail closed: 事業列の和が「計」列と合わない表は採用しない。
    @Test func periodStackedColumnsRejectsSegmentSumNotMatchingTotalColumn() throws {
        let md = try Self.nomuraMarkdown().replacingOccurrences(of: "2,159,442", with: "2,500,000")
        #expect(StackedSegmentPnLNormalizer.normalizePeriodStackedColumns(
            md, consolidatedSales: Self.m(4_758_486)) == nil)
    }

    /// 期間行で積まれていない（1期だけの）事業列表は対象外。
    @Test func periodStackedColumnsRequiresTwoPeriodBlocks() {
        let md = BreakdownExtractor.gridToMarkdown([
            ["", "A部門", "B部門", "計"],
            ["2026年３月期", "", "", ""],
            ["売上高", "60", "40", "100"],
            ["営業利益", "6", "4", "10"],
        ])
        #expect(StackedSegmentPnLNormalizer.normalizePeriodStackedColumns(
            md, consolidatedSales: Self.m(100)) == nil)
    }
}
