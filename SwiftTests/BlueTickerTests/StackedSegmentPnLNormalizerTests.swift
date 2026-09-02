// 積み上げセグメント損益表の決定論寄せ（富士フイルム型）のユニットテスト。
// 同一事業ラベルが指標ブロックごとに繰り返され、末尾「XXX計」だけが指標名を持つ表で、
// 研究開発費ブロックを profit に誤寄せしないこと（実測: S100YIBH / S100W3XJ）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct StackedSegmentPnLNormalizerTests {

    /// S100YIBH（富士フイルム FY2026-03 IFRS）の積み上げ表 Markdown（抽出器実測）。
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

        #expect(snapshot.axis == "business")
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
}
