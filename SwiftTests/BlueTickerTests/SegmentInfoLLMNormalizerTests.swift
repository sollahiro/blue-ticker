// SegmentInfoLLMNormalizer: 決定論の表構造 + Jev 列・行選択（Chat Completions は使わない）。
// キヤノン型（列が見出しの事業、行が売上高・営業利益）と、行が事業の単純表を検証する。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct SegmentInfoLLMNormalizerTests {

    private static func decider(
        selected: String? = nil, confidence: Double = 0.9,
        pNone: Double? = nil
    ) -> FakeRevenueRecognitionColumnDecider {
        FakeRevenueRecognitionColumnDecider(
            selected: selected, confidence: confidence, pNone: pNone)
    }

    private static func normalize(
        tables: [BreakdownTable],
        sales: Double?,
        selected: String? = nil,
        confidence: Double = 0.9,
        pNone: Double? = nil,
        docID: String = "S-seg"
    ) async -> (BreakdownSnapshot?, LLMBreakdownAudit?) {
        await SegmentInfoLLMNormalizer.normalize(
            ExtractedBreakdown(method: "html_table", tables: tables, facts: []),
            consolidatedSales: sales,
            decider: Self.decider(selected: selected, confidence: confidence, pNone: pNone),
            fiscalYearEnd: "2026-03-31",
            docID: docID)
    }

    @Test func returnsNilWhenTablesAreEmpty() async {
        let (snapshot, audit) = await SegmentInfoLLMNormalizer.normalize(
            ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: []),
            consolidatedSales: 1_000_000,
            decider: Self.decider(),
            fiscalYearEnd: nil,
            docID: "S-empty"
        )
        #expect(snapshot == nil)
        #expect(audit == nil)
    }

    /// キヤノン型: 列が見出しの事業、外部顧客向けを売上、営業利益を profit にする。
    @Test func transposesColumnsAndCapturesProfit() async throws {
        let markdown = """
            |           | プリンティング   |  | メディカル   |  | イメージング    |  | インダストリアル |  | その他及び全社   |  | 消去       |  | 連結        |
            | 売上高       |           |  |         |  |           |  |          |  |           |  |          |  |           |
            | 外部顧客向け    | 2,487,885 |  | 579,723 |  | 1,054,513 |  | 357,924  |  | 144,682   |  | -        |  | 4,624,727 |
            | セグメント間取引  | 6,513     |  | 899     |  | 387       |  | 3,204    |  | 92,434    |  | △103,437 |  | -         |
            | 計         | 2,494,398 |  | 580,622 |  | 1,054,900 |  | 361,128  |  | 237,116   |  | △103,437 |  | 4,624,727 |
            | 営業利益      | 255,759   |  | 32,775  |  | 172,871   |  | 62,525   |  | △69,451   |  | 911      |  | 455,390   |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 4_624_727 * Financial.millionYen
        let (snapshotOrNil, audit) = await Self.normalize(tables: [table], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.axis == "business")
        #expect(snapshot.sourceKind == "segment_info")
        #expect(audit?.profitDisclosed == true)
        #expect(audit?.columnJev?.model == "typesafe/jev-1.13")
        let printing = try #require(snapshot.rows.first { $0.labelRaw == "プリンティング" })
        #expect(printing.amount == 2_487_885 * Financial.millionYen)
        #expect(printing.profit == 255_759 * Financial.millionYen)
        let medical = try #require(snapshot.rows.first { $0.labelRaw == "メディカル" })
        #expect(medical.profit == 32_775 * Financial.millionYen)
        #expect(snapshot.rows.contains { $0.labelRaw == "その他及び全社" })
        #expect(!snapshot.rows.contains { $0.labelRaw == "連結" })
        #expect(!snapshot.needsReview)
    }

    @Test func takesGeographyOnlyReportingSegments() async throws {
        let markdown = """
            | 区分 | 当期 |
            | 日本 | 600 |
            | 米国 | 400 |
            | 合計 | 1,000 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let (snapshotOrNil, _) = await Self.normalize(
            tables: [table], sales: 1_000 * Financial.millionYen)
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.warnings.contains(SegmentInfoLLMNormalizer.warningGeographyTaken))
        #expect(!snapshot.warnings.contains("business_label_looks_like_geography"))
        let labels: Set<String> = Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.map { $0.labelRaw })
        #expect(labels == Set(["日本", "米国"]))
        #expect(!snapshot.needsReview)
    }

    @Test func flagsSuspicionWhenGeographicBusinessUnitNamesLookLikeRegions() async throws {
        let markdown = """
            | 区分 | 当期 |
            | 日本事業 | 300 |
            | 米州事業 | 200 |
            | 欧州事業 | 500 |
            | 合計 | 1,000 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let (snapshotOrNil, _) = await Self.normalize(
            tables: [table], sales: 1_000 * Financial.millionYen)
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("business_label_looks_like_geography"))
    }

    @Test func doesNotFlagSuspicionWhenLabelsAreDomesticOverseasPrefixedBusinessNames() async throws {
        let markdown = """
            | 区分 | 当期 |
            | 国内食料品製造・販売 | 155,718 |
            | 海外食料品製造・販売 | 149,491 |
            | 海外食料品卸売 | 432,800 |
            | 合計 | 738,009 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = (155_718 + 149_491 + 432_800) * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(tables: [table], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        #expect(!snapshot.needsReview)
        #expect(!snapshot.warnings.contains("business_label_looks_like_geography"))
    }

    @Test func fallsBackToInternalSubtotalWhenSalesBasisMismatchesButTableReconciles() async throws {
        let markdown = """
            | 部門 | 当期 |
            | ウェルス・マネジメント部門 | 487,906 |
            | インベストメント・マネジメント部門 | 258,516 |
            | ホールセール部門 | 1,162,229 |
            | バンキング部門 | 53,918 |
            | その他（消去分を含む） | 196,873 |
            | 計 | 2,159,442 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let (snapshotOrNil, _) = await Self.normalize(
            tables: [table], sales: 4_758_486 * Financial.millionYen)
        let snapshot = try #require(snapshotOrNil)
        #expect(!snapshot.needsReview)
        #expect(snapshot.denominatorTag == "llm_table_subtotal")
        #expect(snapshot.denominator == 2_159_442 * Financial.millionYen)
        #expect(snapshot.warnings.contains("llm_denominator_from_internal_subtotal"))
        let otherRow = try #require(snapshot.rows.first { $0.labelRaw.contains("その他") })
        #expect(otherRow.rowKind == "segment")
    }

    @Test func keepsPureEliminationRowsAsReconciling() async throws {
        let markdown = """
            | 区分 | 当期 |
            | A事業 | 80 |
            | B事業 | 20 |
            | 消去 | 0 |
            | その他の調整額 | 0 |
            | 計 | 100 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let (snapshotOrNil, _) = await Self.normalize(
            tables: [table], sales: 100 * Financial.millionYen)
        let snapshot = try #require(snapshotOrNil)
        let elim = try #require(snapshot.rows.first { $0.labelRaw == "消去" })
        #expect(elim.rowKind == "reconciling")
        let otherAdj = try #require(snapshot.rows.first { $0.labelRaw == "その他の調整額" })
        #expect(otherAdj.rowKind == "reconciling")
    }

    @Test func transposesPeriodRowsWhenColumnsAreProducts() async throws {
        let markdown = """
            | | ニューロロジー領域製品 | オンコロジー領域製品 | その他 | 合計 |
            | 当連結会計年度(自2025年4月1日至2026年3月31日) | 260,568 | 362,668 | 202,142 | 825,378 |
            | 前連結会計年度(自2024年4月1日至2025年3月31日) | 1 | 1 | 1 | 3 |
            """
        let table = BreakdownTable(
            heading: BreakdownExtractor.productOrServiceHeading,
            markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 825_378 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(tables: [table], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let labels: Set<String> = Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.map { $0.labelRaw })
        #expect(labels.contains("ニューロロジー領域製品"))
        #expect(labels.contains("オンコロジー領域製品"))
        #expect(!labels.contains("合計"))
        let neuro = try #require(snapshot.rows.first { $0.labelRaw.contains("ニューロロジー") })
        #expect(neuro.amount == 260_568 * Financial.millionYen)
        #expect(!snapshot.needsReview)
    }

    @Test func prefersProductServiceTableOverGeographicReportingSegments() async throws {
        let product = BreakdownTable(
            heading: BreakdownExtractor.productOrServiceHeading,
            markdown: """
                | 区分 | 当連結会計年度 |
                | ラツーダ（非定型抗精神病薬） | 40 |
                | オルゴビクス（進行性前立腺がん治療剤） | 250 |
                | 合計 | 290 |
                """,
            period: "当期",
            unitCaption: "百万円")
        let geography = BreakdownTable(
            heading: "セグメント情報",
            markdown: """
                | | 日本 | 北米 | 計 |
                | 外部顧客への売上収益等 | 90 | 200 | 290 |
                | セグメント利益 | 10 | 20 | 30 |
                """,
            period: "当期",
            unitCaption: "百万円")
        let sales = 290 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(
            tables: [product, geography], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let labels = snapshot.rows.map(\.labelRaw).joined(separator: " ")
        #expect(labels.contains("ラツーダ"))
        #expect(labels.contains("オルゴビクス"))
        #expect(!labels.contains("北米"))
        #expect(!snapshot.warnings.contains(SegmentInfoLLMNormalizer.warningGeographyTaken))
    }

    @Test func transposedMatrixKeepsSelectedBusinessColumn() async throws {
        let markdown = """
            | | 日本事業 | 中国・トラベルリテール事業 | 米州事業 | 欧州事業 |
            | 外部顧客への売上高 | 295,343 | 342,244 | 150,000 | 182,405 |
            | セグメント利益 | 10 | 20 | 30 | 40 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 969_992 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(
            tables: [table], sales: sales, selected: "t0_c1")
        let snapshot = try #require(snapshotOrNil)
        let japan = try #require(snapshot.rows.first { $0.labelRaw.contains("日本") })
        #expect(japan.amount == 295_343 * Financial.millionYen)
        let china = try #require(snapshot.rows.first { $0.labelRaw.contains("トラベルリテール") })
        #expect(china.amount == 342_244 * Financial.millionYen)
        #expect(snapshot.warnings.contains("business_label_looks_like_geography"))
        #expect(snapshot.needsReview)
    }

    @Test func dropsReportableSegmentStubFromColumnHeaders() async throws {
        let markdown = """
            | | 報告セグメント | 報告セグメント | 報告セグメント |
            | | 日本事業 | 米州事業 | 欧州事業 |
            | 外部顧客への売上高 | 300 | 200 | 500 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 1_000 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(tables: [table], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let labels: Set<String> = Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.map { $0.labelRaw })
        #expect(labels.contains("日本事業"))
        #expect(labels.contains("米州事業"))
        #expect(!labels.contains(where: { $0.contains("報告セグメント") }))
    }

    @Test func doesNotFallBackWhenSubtotalFarFromSegmentSum() async throws {
        let markdown = """
            | 区分 | 当期 |
            | A事業 | 100 |
            | B事業 | 100 |
            | 計 | 400 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let (snapshotOrNil, _) = await Self.normalize(
            tables: [table], sales: 1_000 * Financial.millionYen)
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("llm_row_sum_mismatch"))
    }

    @Test func noneOfTheseAtHighConfidenceReturnsNil() async {
        let markdown = """
            | 区分 | 当期 |
            | A事業 | 100 |
            | 合計 | 100 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let (snapshot, audit) = await Self.normalize(
            tables: [table], sales: 100 * Financial.millionYen,
            selected: RevenueRecognitionColumnNormalizer.noneOfThese,
            confidence: 0.9, pNone: 0.9)
        #expect(snapshot == nil)
        #expect(audit?.columnJev?.calls.first?.selected == RevenueRecognitionColumnNormalizer.noneOfThese)
    }

    @Test func noneOfTheseBelowPNoneFallsBackAndFlagsReview() async throws {
        let markdown = """
            | 区分 | 当期 |
            | A事業 | 100 |
            | B事業 | 50 |
            | 合計 | 150 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let (snapshotOrNil, _) = await Self.normalize(
            tables: [table], sales: 150 * Financial.millionYen,
            selected: RevenueRecognitionColumnNormalizer.noneOfThese,
            confidence: 0.6, pNone: 0.4)
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains(SegmentInfoLLMNormalizer.warningNoneOfTheseOverridden))
    }

    @Test func yenHeaderDoesNotMultiplyAmounts() async throws {
        let markdown = """
            | （単位：円） | 当期 |
            | 事業A | 1000000000 |
            | 事業B | 0 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "円")
        let sales = 1_000_000_000.0
        let (snapshotOrNil, _) = await Self.normalize(tables: [table], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let businessA = try #require(snapshot.rows.first { $0.labelRaw == "事業A" })
        #expect(businessA.amount == sales)
        #expect(!snapshot.warnings.contains(BreakdownLLMAmountScale.headerLlmMismatchWarning))
    }

    @Test func infersMillionYenWhenHeaderUnitMissingButTableTotalMatchesSales() async throws {
        let markdown = """
            |           | プリンティング   |  | メディカル   |  | 連結        |
            | 外部顧客向け    | 2,487,885 |  | 579,723 |  | 3,067,608 |
            | 営業利益      | 255,759   |  | 32,775  |  | 288,534   |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期")
        let sales = 3_067_608 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(tables: [table], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let printing = try #require(snapshot.rows.first { $0.labelRaw == "プリンティング" })
        #expect(printing.amount == 2_487_885 * Financial.millionYen)
        #expect(!snapshot.warnings.contains("llm_unit_unresolved"))
        #expect(!snapshot.needsReview)
    }
}
