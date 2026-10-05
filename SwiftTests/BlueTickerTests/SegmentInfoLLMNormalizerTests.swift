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
        fiscalYearEnd: String = "2026-03-31",
        docID: String = "S-seg"
    ) async -> (BreakdownSnapshot?, LLMBreakdownAudit?) {
        await SegmentInfoLLMNormalizer.normalize(
            ExtractedBreakdown(method: "html_table", tables: tables, facts: []),
            consolidatedSales: sales,
            decider: Self.decider(selected: selected, confidence: confidence, pNone: pNone),
            fiscalYearEnd: fiscalYearEnd,
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

    @Test func geographyOnlyReportingSegmentsAreNotApplicable() async throws {
        let markdown = """
            | 区分 | 当期 |
            | 日本 | 600 |
            | 米国 | 400 |
            | 合計 | 1,000 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let (snapshot, audit) = await Self.normalize(
            tables: [table], sales: 1_000 * Financial.millionYen)
        #expect(snapshot == nil)
        #expect(audit?.notApplicableReason == breakdownNotApplicableGeographyOnly)
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

    /// ヘッダー行が同じ事業名を繰り返すと `その他 / その他` にしない。
    @Test func collapsesDuplicateJoinedColumnHeaders() async throws {
        let markdown = """
            | | その他 | マーケット | 連結 |
            | | その他 | マーケット | 連結 |
            | 外部顧客への売上高 | 50 | 200 | 250 |
            | 営業利益 | 5 | 20 | 25 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 250 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(tables: [table], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let labels: Set<String> = Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.map { $0.labelRaw })
        #expect(labels == Set(["その他", "マーケット"]))
        #expect(!labels.contains(where: { $0.contains(" / ") }))
    }

    /// 全列にかかる「○○（連結）」親見出しで事業列を合計扱いしない（みずほ型）。
    @Test func spanningConsolidatedParentDoesNotSkipBusinessColumns() async throws {
        let markdown = """
            | | みずほフィナンシャルグループ（連結） | みずほフィナンシャルグループ（連結） | みずほフィナンシャルグループ（連結） |
            | | リテール・事業法人カンパニー | グローバルマーケッツカンパニー | 連結 |
            | 業務粗利益 | 700 | 400 | 1,100 |
            | 営業利益 | 60 | 150 | 210 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 1_100 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(tables: [table], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let labels: Set<String> = Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.map { $0.labelRaw })
        #expect(labels.contains("リテール・事業法人カンパニー"))
        #expect(labels.contains("グローバルマーケッツカンパニー"))
        #expect(!labels.contains(where: { $0.contains("業務粗利益") }))
        #expect(!labels.contains(where: { $0.contains("のれん") }))
        let retail = try #require(snapshot.rows.first { $0.labelRaw.contains("リテール") })
        #expect(retail.amount == 700 * Financial.millionYen)
    }

    /// `(1) 外部顧客に対する売上高` を売上行として列転置する（コマツ型）。
    @Test func enumeratedExternalCustomerSalesRowTransposes() async throws {
        let markdown = """
            | | 建設機械・車両 | リテールファイナンス | 産業機械他 | 計 | 連結 |
            | 売上高 | | | | | |
            | (1) 外部顧客に対する売上高 | 3,796,100 | 100,520 | 236,131 | 4,132,751 | 4,132,751 |
            | (2) セグメント間の内部売上高 | 9,940 | 25,617 | 2,619 | 38,176 | － |
            | 営業利益 | 400,000 | 20,000 | 10,000 | 430,000 | 430,000 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 4_132_751 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(tables: [table], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let labels: Set<String> = Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.map { $0.labelRaw })
        #expect(labels == Set(["建設機械・車両", "リテールファイナンス", "産業機械他"]))
        let construction = try #require(snapshot.rows.first { $0.labelRaw == "建設機械・車両" })
        #expect(construction.amount == 3_796_100 * Financial.millionYen)
        #expect(!snapshot.needsReview)
    }

    /// `収益(注)１` を売上行として列転置する（4324 型）。
    @Test func parentheticalRevenueRowTransposes() async throws {
        let markdown = """
            | | 広告業 | 情報サービス業 | その他の事業 | 計 |
            | 収益(注)１ | 800 | 300 | 143 | 1,243 |
            | セグメント利益 | 10 | 5 | 1 | 16 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 1_243 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(tables: [table], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let ads = try #require(snapshot.rows.first { $0.labelRaw == "広告業" })
        #expect(ads.amount == 800 * Financial.millionYen)
        #expect(!snapshot.needsReview)
    }

    /// 製品表と地域表が両方ある → 製品を採る（武田 / 3422 型）。
    @Test func prefersProductTableWhenGeographyAlsoExists() async throws {
        let product = BreakdownTable(
            heading: "セグメント情報",
            markdown: """
                | 区分 | 当期 |
                | ALOFISEL | 100 |
                | DEXILANT | 200 |
                | 合計 | 300 |
                """,
            period: "当期",
            unitCaption: "百万円")
        let geography = BreakdownTable(
            heading: "セグメント情報",
            markdown: """
                | | 日本 | タイ | 中国 | 計 |
                | 外部顧客への売上高 | 50 | 80 | 170 | 300 |
                | セグメント利益 | 5 | 8 | 17 | 30 |
                """,
            period: "当期",
            unitCaption: "百万円")
        let sales = 300 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(
            tables: [product, geography], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let labels: Set<String> = Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.map { $0.labelRaw })
        #expect(labels == Set(["ALOFISEL", "DEXILANT"]))
        #expect(!snapshot.needsReview)
        #expect(!snapshot.warnings.contains(
            SegmentInfoPublishGuards.warningGeographyWhileProductExists))
    }

    /// 製品表があるのに地域列を採った場合は公開しない（武田 / 3422 型のガード）。
    @Test func geographyLabelsNeedReviewWhenProductTableExists() {
        let parsed = RevenueRecognitionCandidates.parse(
            tables: [
                BreakdownTable(
                    heading: "セグメント情報",
                    markdown: """
                        | 区分 | 当期 |
                        | ALOFISEL | 100 |
                        | DEXILANT | 200 |
                        | 合計 | 300 |
                        """,
                    period: "当期"),
                BreakdownTable(
                    heading: "セグメント情報",
                    markdown: """
                        | | 日本 | タイ | 中国 | 計 |
                        | 外部顧客への売上高 | 50 | 80 | 170 | 300 |
                        | セグメント利益 | 5 | 8 | 17 | 30 |
                        """,
                    period: "当期"),
            ])
        let geography = parsed.first { table in
            table.columnHeaders.values.contains { $0.contains("タイ") }
        }
        var needsReview = false
        var warnings: [String] = []
        SegmentInfoPublishGuards.apply(
            rows: [
                BreakdownRow(labelRaw: "日本", amount: 50, share: nil, profit: 5, rowKind: "segment"),
                BreakdownRow(labelRaw: "タイ", amount: 80, share: nil, profit: 8, rowKind: "segment"),
                BreakdownRow(labelRaw: "中国", amount: 170, share: nil, profit: 17, rowKind: "segment"),
            ],
            allTables: parsed, selectedTable: geography, selectedColumn: nil,
            fiscalYearEnd: "2026-03-31", needsReview: &needsReview, warnings: &warnings)
        #expect(needsReview)
        #expect(warnings.contains(SegmentInfoPublishGuards.warningGeographyWhileProductExists))
    }

    /// 前期と当期の日本/アジア報告セグメント表だけなら、地域を採っても製品表警告は出さない。
    @Test func priorYearJapanAsiaMatrixIsNotAProductTable() {
        let parsed = RevenueRecognitionCandidates.parse(
            tables: [
                BreakdownTable(
                    heading: "セグメント情報",
                    markdown: """
                        | | 報告セグメント | 報告セグメント | 計 | 調整額 | 連結財務諸表計上額 |
                        | | 日本 | アジア | | | |
                        | 顧客との契約から生じる収益 | 4,376,916 | 1,269,509 | 5,646,425 | - | 5,646,425 |
                        | 外部顧客に対する売上高 | 4,376,916 | 1,269,509 | 5,646,425 | - | 5,646,425 |
                        | セグメント損失 | -180,207 | -42,256 | -222,464 | 26,630 | -195,833 |
                        | 有形固定資産及び無形固定資産の増加額 | 92,383 | 1,919 | 94,303 | - | 94,303 |
                        """,
                    period: "前期",
                    unitCaption: "千円"),
                BreakdownTable(
                    heading: "セグメント情報",
                    markdown: """
                        | | 報告セグメント | 報告セグメント | 計 | 調整額 | 連結財務諸表計上額 |
                        | | 日本 | アジア | | | |
                        | 顧客との契約から生じる収益 | 4,333,990 | 1,140,562 | 5,474,552 | - | 5,474,552 |
                        | 外部顧客に対する売上高 | 4,333,990 | 1,140,562 | 5,474,552 | - | 5,474,552 |
                        | セグメント損失 | -192,662 | -30,708 | -223,371 | 1,246 | -222,124 |
                        | 有形固定資産及び無形固定資産の増加額 | 33,072 | 25,188 | 58,261 | - | 58,261 |
                        """,
                    period: "当期",
                    unitCaption: "千円"),
            ])
        let current = parsed.first { $0.period == "当期" }
        let currentIsProduct: Bool = current.map {
            SegmentInfoPublishGuards.hasProductOrBusinessLabels($0)
        } ?? true
        #expect(currentIsProduct == false)
        var needsReview = false
        var warnings: [String] = []
        SegmentInfoPublishGuards.apply(
            rows: [
                BreakdownRow(labelRaw: "日本", amount: 4_333_990, share: nil, profit: nil, rowKind: "segment"),
                BreakdownRow(labelRaw: "アジア", amount: 1_140_562, share: nil, profit: nil, rowKind: "segment"),
            ],
            allTables: parsed, selectedTable: current, selectedColumn: nil,
            fiscalYearEnd: "2026-03-31", needsReview: &needsReview, warnings: &warnings)
        let flagged: Bool = needsReview
        let productWarning: Bool = warnings.contains(
            SegmentInfoPublishGuards.warningGeographyWhileProductExists)
        #expect(flagged == false)
        #expect(productWarning == false)
    }

    /// 金額セルをセグメント名にしない（3905 / 7734 型）。
    @Test func numericColumnHeaderIsNotPublishedAsSegment() async throws {
        let markdown = """
            | 区分 | 当期 |
            | 1,918,575 | 1,918,575 |
            | 合計 | 1,918,575 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 1_918_575 * Financial.millionYen
        let (snapshot, _) = await Self.normalize(tables: [table], sales: sales)
        let labels = snapshot?.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw) ?? []
        #expect(!labels.contains { SegmentInfoPublishGuards.isNumericOrCodeLabel($0) })
        if let snapshot, !labels.isEmpty {
            #expect(snapshot.needsReview)
        }
    }

    /// 指標行がセグメント名になった積み上げ表は公開しない（富士フイルム / ORIX 型）。
    @Test func metricRowLabelsNeedReview() async throws {
        let markdown = """
            | 区分 | 当期 |
            | セグメント収益 | 1,000 |
            | セグメント利益 | 100 |
            | セグメント資産 | 5,000 |
            | 支払利息 | 20 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 1_000 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(tables: [table], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains(SegmentInfoPublishGuards.warningMetricRowLabels))
    }

    /// 同一ラベルが指標ブロックごとに繰り返された表は公開しない（リコー型）。
    @Test func duplicateSegmentLabelsNeedReview() async throws {
        let markdown = """
            | 区分 | 当期 |
            | デジタルサービス | 100 |
            | デジタルプロダクツ | 80 |
            | デジタルサービス | 40 |
            | デジタルプロダクツ | 30 |
            | デジタルサービス | 10 |
            | デジタルプロダクツ | 5 |
            | 合計 | 265 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 265 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(tables: [table], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains(SegmentInfoPublishGuards.warningDuplicateSegmentLabels))
    }

    /// 前期列を採り、同じ表の当期列が売上に合う → 公開しない（キヤノン型）。
    @Test func priorPeriodColumnMatchingOtherYearNeedsReview() async throws {
        let markdown = """
            | 区分 | 前連結会計年度 | 当連結会計年度 |
            | オフィス | 1,749,165 | 1,437,188 |
            | イメージングシステム | 806,425 | 711,317 |
            | 合計 | 2,555,590 | 2,148,505 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 2_148_505 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(
            tables: [table], sales: sales, selected: "t0_c1")
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains(SegmentInfoPublishGuards.warningPriorPeriodColumn))
    }

    /// 地域グループ見出しは葉の製品名だけ残す（9274 型）。
    @Test func geographyGroupPrefixDroppedFromJoinedHeaders() async throws {
        let joined: String = RevenueRecognitionCandidates.joinHeaderParts(
            ["北東アジア・欧州／米州・アジアパシフィック", "板紙"])
        #expect(joined == "板紙")
        let markdown = """
            | | 北東アジア・欧州／米州・アジアパシフィック | 北東アジア・欧州／米州・アジアパシフィック | 連結 |
            | | 板紙 | パルプ・古紙 | 連結 |
            | 外部顧客に対する売上高 | 80 | 20 | 100 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 100 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(tables: [table], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let labels: Set<String> = Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.map { $0.labelRaw })
        #expect(labels.contains("板紙"))
        #expect(labels.contains("パルプ・古紙"))
        #expect(!labels.contains(where: { $0.contains("北東アジア") }))
        #expect(!snapshot.needsReview)
    }

    /// 同一ラベルが指標ブロックの group 違いで繰り返されても公開しない（リコー資産/設備型）。
    @Test func duplicateSegmentLabelsAcrossMetricGroupsNeedReview() async throws {
        let markdown = """
            | 区分 | 当期 |
            | 資産合計 | |
            | デジタルサービス | 1,323,991 |
            | デジタルプロダクツ | 446,654 |
            | 資本的支出 | |
            | デジタルサービス | 31,296 |
            | デジタルプロダクツ | 18,731 |
            | 合計 | 1,820,672 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 2_608_314 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(tables: [table], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains(SegmentInfoPublishGuards.warningDuplicateSegmentLabels)
            || snapshot.warnings.contains(SegmentInfoPublishGuards.warningMetricRowLabels))
    }

    /// 第N期が2表あるときは後期の外部顧客向けを採る（キヤノン US-GAAP 注記型）。
    @Test func laterFiscalEraMatrixIsPreferred() async throws {
        let prior = BreakdownTable(
            heading: "セグメント情報",
            markdown: """
                | | オフィス | イメージングシステム | メディカルシステム | 産業機器その他 | 連結 |
                | 外部顧客向け | 1,749,165 | 806,425 | 437,456 | 598,653 | 3,593,299 |
                | 営業利益 | 164,996 | 48,167 | 26,744 | 19,392 | 174,420 |
                """,
            period: nil, unitCaption: "百万円", precedingCaption: "第119期")
        let current = BreakdownTable(
            heading: "セグメント情報",
            markdown: """
                | | オフィス | イメージングシステム | メディカルシステム | 産業機器その他 | 連結 |
                | 外部顧客向け | 1,437,188 | 711,317 | 435,368 | 577,130 | 3,160,243 |
                | 営業利益 | 81,369 | 71,805 | 25,244 | 13,225 | 110,547 |
                """,
            period: nil, unitCaption: "百万円", precedingCaption: "第120期")
        let sales = 3_160_243 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(
            tables: [prior, current], sales: sales, fiscalYearEnd: "2020-12-31")
        let snapshot = try #require(snapshotOrNil)
        let office = try #require(snapshot.rows.first { $0.labelRaw == "オフィス" })
        #expect(office.amount == 1_437_188 * Financial.millionYen)
        #expect(!snapshot.needsReview)
    }

    /// 行が見出し年度のときは期末年の行を売上にする（キヤノン年次行型）。
    @Test func yearEndedRowMatchingFiscalYearEndIsPreferred() async throws {
        let markdown = """
            | | オフィス | イメージングシステム | 連結 |
            | 2019年12月31日に終了した事業年度 | 1,749,165 | 806,425 | 2,555,590 |
            | 2020年12月31日に終了した事業年度 | 1,437,188 | 711,317 | 2,148,505 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 2_148_505 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(
            tables: [table], sales: sales, fiscalYearEnd: "2020-12-31")
        let snapshot = try #require(snapshotOrNil)
        let office = try #require(snapshot.rows.first { $0.labelRaw == "オフィス" })
        #expect(office.amount == 1_437_188 * Financial.millionYen)
        #expect(!snapshot.needsReview)
    }

    /// 期間親見出しが join で落ちても当期の金額列を採る（第一三共 前/当・金額列型）。
    @Test func currentYearAmountColumnPreferredWhenPeriodParentIsSpanning() async throws {
        let markdown = """
            | | 前連結会計年度 | 前連結会計年度 | 当連結会計年度 | 当連結会計年度 |
            | | 金額 | 構成比（％） | 金額 | 構成比（％） |
            | 医療用医薬品 | 1,796,974 | 95.3 | 2,029,538 | 95.6 |
            | ヘルスケア | 86,587 | 4.6 | 90,784 | 4.3 |
            | その他 | 2,693 | 0.1 | 2,722 | 0.1 |
            | 合計 | 1,886,256 | 100.0 | 2,123,045 | 100.0 |
            """
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: markdown, period: "当期", unitCaption: "百万円")
        let sales = 2_123_045 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.normalize(tables: [table], sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let pharma = try #require(snapshot.rows.first { $0.labelRaw.contains("医療用医薬品") })
        #expect(pharma.amount == 2_029_538 * Financial.millionYen)
        #expect(!snapshot.needsReview)
    }
}
