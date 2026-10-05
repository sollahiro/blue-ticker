// SPEC_ORACLE: LLM 内訳は表ヘッダーの単位で円換算する。
// 332A S100YKM2 / 7096 S100YI32 型の実表（単位スタブ表 + データ表。単位行は markdown に残らない）。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct BreakdownLLMHeaderUnitTests {

    /// 332A S100YKM2 収益認識表に近い形。単位は別表「（単位：千円）」で、データ表に単位行が無い。
    private static let senYenStubHtml = """
        <table><tr><td>（単位：千円）</td></tr></table>
        <table>
          <tr><td></td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
          <tr><td>MVNEサービス</td><td>4,800,000</td><td>5,120,400</td></tr>
          <tr><td>その他</td><td>200,000</td><td>210,000</td></tr>
          <tr><td>顧客との契約から生じる収益</td><td>5,000,000</td><td>5,330,400</td></tr>
        </table>
        """

    /// 7096 S100YI32 型: 同じく千円スタブだがヘッダー単位で換算する。
    private static let senYenUnscaledHtml = """
        <table><tr><td>(単位:千円)</td></tr></table>
        <table>
          <tr><td>区分</td><td>当期</td></tr>
          <tr><td>製品A</td><td>12,345</td></tr>
          <tr><td>製品B</td><td>7,655</td></tr>
          <tr><td>合計</td><td>20,000</td></tr>
        </table>
        """

    private static func tables(from html: String, heading: String) -> [BreakdownTable] {
        BreakdownExtractor.allTablesFromHtml(html, defaultHeading: heading)
    }

    @Test func senYenStubCaptionsCarryOntoDataTables() {
        let tables = Self.tables(from: Self.senYenStubHtml, heading: "収益認識関係")
        #expect(tables.count >= 1)
        #expect(tables.contains { $0.unitCaption == "千円" && $0.unitCaptionOrigin == .table })
        #expect(!tables.contains { $0.markdown.contains("単位") })
        #expect(tables.contains { $0.markdown.contains("5,120,400") || $0.markdown.contains("5120400") })
    }

    private static func publiclyServable(
        _ snapshot: BreakdownSnapshot, source: String
    ) -> Bool {
        isPubliclyServableBreakdown(
            source: source, needsReview: snapshot.needsReview, warnings: snapshot.warnings)
    }

    private static func normalizeRR(
        _ extracted: ExtractedBreakdown, sales: Double?, pick: String? = nil
    ) async -> BreakdownSnapshot? {
        let (snapshot, _) = await RevenueRecognitionColumnNormalizer.normalize(
            extracted, consolidatedSales: sales,
            decider: FakeRevenueRecognitionColumnDecider(selected: pick),
            fiscalYearEnd: "2025-03-31", docID: "S-rr-unit")
        return snapshot
    }

    @Test func revenueRecognitionSenYenHeaderScalesThousandNotMillion() async throws {
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: Self.tables(from: Self.senYenStubHtml, heading: "収益認識関係"),
            facts: []
        )
        let sales = 5_330_400 * BreakdownLLMAmountScale.thousandYen
        let snapshot = try #require(await Self.normalizeRR(extracted, sales: sales))
        let mvne = try #require(
            snapshot.rows.first { $0.labelRaw == "MVNEサービス" || $0.categoryGroup == "MVNEサービス" })
        #expect(mvne.amount == 5_120_400 * BreakdownLLMAmountScale.thousandYen)
        #expect(mvne.amount != 5_120_400 * Financial.millionYen)
        #expect(snapshot.needsReview == false)
        #expect(!snapshot.warnings.contains("llm_unit_unresolved"))
        #expect(
            Self.publiclyServable(snapshot, source: breakdownSourceRevenueRecognitionLLM) == true)
    }

    @Test func revenueRecognitionSenYenHeaderScalesWhenLLMSaysOther() async throws {
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: Self.tables(from: Self.senYenUnscaledHtml, heading: "収益認識関係"),
            facts: []
        )
        let sales = 20_000 * BreakdownLLMAmountScale.thousandYen
        let snapshot = try #require(await Self.normalizeRR(extracted, sales: sales))
        let productA = try #require(
            snapshot.rows.first { $0.labelRaw == "製品A" || $0.categoryGroup == "製品A" })
        #expect(productA.amount == 12_345 * BreakdownLLMAmountScale.thousandYen)
        #expect(snapshot.needsReview == false)
        #expect(!snapshot.warnings.contains("llm_unit_unresolved"))
        #expect(snapshot.sourceKind == "revenue_recognition")
        #expect(
            Self.publiclyServable(snapshot, source: breakdownSourceRevenueRecognitionLLM) == true)
    }

    @Test func millionYenHeaderKeepsMillionScaleWithoutMismatch() async throws {
        let html = """
            <table><tr><td>（単位：百万円）</td></tr></table>
            <table>
              <tr><td>製品A</td><td>10,000</td></tr>
              <tr><td>製品B</td><td>5,000</td></tr>
              <tr><td>合計</td><td>15,000</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: Self.tables(from: html, heading: "収益認識関係"),
            facts: []
        )
        let sales = 15_000 * Financial.millionYen
        let snapshot = try #require(await Self.normalizeRR(extracted, sales: sales))
        #expect(snapshot.rows[0].amount == 10_000 * Financial.millionYen)
        #expect(snapshot.needsReview == false)
        #expect(!snapshot.warnings.contains(BreakdownLLMAmountScale.headerLlmMismatchWarning))
    }

    @Test func yenHeaderDoesNotMultiplySegmentInfo() async throws {
        let html = """
            <table>
              <tr><td>（単位：円）</td><td>当期</td></tr>
              <tr><td>事業A</td><td>1000000000</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: Self.tables(from: html, heading: "セグメント情報"),
            facts: []
        )
        let sales = 1_000_000_000.0
        let (snapshotOrNil, _) = await SegmentInfoLLMNormalizer.normalize(
            extracted, consolidatedSales: sales,
            decider: FakeRevenueRecognitionColumnDecider(),
            fiscalYearEnd: "2025-03-31",
            docID: "S-yen"
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.rows[0].amount == sales)
        #expect(!snapshot.warnings.contains(BreakdownLLMAmountScale.headerLlmMismatchWarning))
        #expect(!snapshot.needsReview)
    }

    @Test func noHeaderInfersMillionFromConsolidatedSalesForGeography() async throws {
        let html = """
            <p>当連結会計年度</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>100</td></tr>
              <tr><td>合計</td><td>100</td></tr>
            </table>
            """
        var tables = Self.tables(from: html, heading: "地域ごとの情報")
        if !tables.isEmpty { tables[0].period = "当期" }
        let extracted = ExtractedBreakdown(method: "html_table", tables: tables, facts: [])
        let sales = 100 * Financial.millionYen
        let (snapshotOrNil, _) = await GeographyBreakdownLLMNormalizer.normalize(
            extracted, consolidatedSales: sales,
            decider: FakeRevenueRecognitionColumnDecider(),
            fiscalYearEnd: "2026-03-31",
            docID: "S-geo-unit")
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.rows[0].amount == sales)
        #expect(!snapshot.warnings.contains("llm_unit_unresolved"))
        #expect(!snapshot.warnings.contains(BreakdownLLMAmountScale.headerLlmMismatchWarning))
    }

    @Test func missingUnitFailsClosedWithoutGuessingMillion() async throws {
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: [
                BreakdownTable(
                    heading: "収益認識関係",
                    markdown: "| 製品A | 100 |\n",
                    period: "当期")
            ],
            facts: []
        )
        let snapshot = try #require(
            await Self.normalizeRR(extracted, sales: 100 * Financial.millionYen, pick: "t0_c1"))
        #expect(snapshot.rows[0].amount == 100)
        #expect(snapshot.needsReview == true)
        #expect(snapshot.warnings.contains("llm_unit_unresolved"))
        #expect(
            Self.publiclyServable(snapshot, source: breakdownSourceRevenueRecognitionLLM) == false)
    }

    @Test func borrowedSiblingHeaderScalesWithoutDeclaredUnit() async throws {
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: [
                BreakdownTable(
                    heading: "契約資産", markdown: "| a | 1 |", period: "当期", unitCaption: "千円"),
                BreakdownTable(
                    heading: BreakdownExtractor.revenueRecognitionHeading,
                    markdown: """
                        | MVNEサービス | 5,120,400 |
                        | その他 | 210,000 |
                        | 合計 | 5,330,400 |
                        """,
                    period: "当期"),
            ],
            facts: []
        )
        let sales = 5_330_400 * BreakdownLLMAmountScale.thousandYen
        let snapshot = try #require(await Self.normalizeRR(extracted, sales: sales, pick: "t1_c1"))
        #expect(snapshot.rows[0].amount == 5_120_400 * BreakdownLLMAmountScale.thousandYen)
        #expect(!snapshot.warnings.contains("llm_unit_unresolved"))
        #expect(
            Self.publiclyServable(snapshot, source: breakdownSourceRevenueRecognitionLLM) == true)
    }

    @Test func wrapperDivPrecedingHeaderScalesThousand() async throws {
        let html = """
            <p>１．顧客との契約から生じる収益を分解した情報</p>
            <p>当社グループは、生鮮流通プラットフォーム事業の単一セグメントであり、以下のとおりであります。</p>
            <p style="text-align: right">（単位：千円）</p>
            <div style="margin-left: 80px">
            <table>
              <tr><td>サービス別</td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>BtoBコマースサービス</td><td>5,471,053</td><td>6,348,109</td></tr>
              <tr><td>その他</td><td>1,395,271</td><td>1,471,904</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>6,866,324</td><td>7,820,013</td></tr>
            </table>
            </div>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: Self.tables(from: html, heading: "収益認識関係"),
            facts: []
        )
        #expect(extracted.tables.contains { $0.unitCaption == "千円" && $0.unitCaptionOrigin == .preceding })
        let sales = 7_820_013 * BreakdownLLMAmountScale.thousandYen
        let snapshot = try #require(await Self.normalizeRR(extracted, sales: sales))
        let btob = try #require(
            snapshot.rows.first {
                $0.labelRaw == "BtoBコマースサービス" || $0.categoryGroup == "BtoBコマースサービス"
            })
        #expect(btob.amount == 6_348_109 * BreakdownLLMAmountScale.thousandYen)
        #expect(snapshot.needsReview == false)
        #expect(!snapshot.warnings.contains("llm_unit_unresolved"))
        #expect(
            Self.publiclyServable(snapshot, source: breakdownSourceRevenueRecognitionLLM) == true)
    }
}
