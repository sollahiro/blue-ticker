// SPEC_ORACLE: LLM 内訳は表ヘッダーの単位で円換算する。
// 332A S100YKM2 / 7096 S100YI32 型の実表（単位スタブ表 + データ表。単位行は markdown に残らない）。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct BreakdownLLMHeaderUnitTests {

    private actor MockChat: ChatCompleting {
        let response: [String: Any]
        init(_ response: [String: Any]) { self.response = response }
        func complete(system: String, user: String, jsonSchema: Data, schemaName: String) async throws -> Data {
            try JSONSerialization.data(withJSONObject: response)
        }
    }

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

    /// 7096 S100YI32 型: 同じく千円スタブだが LLM が unit=other と返すケース。
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

    @Test func revenueRecognitionSenYenHeaderScalesThousandNotMillion() async throws {
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: Self.tables(from: Self.senYenStubHtml, heading: "収益認識関係"),
            facts: []
        )
        let current = extracted.tables.last { $0.period == "当期" } ?? extracted.tables.last!
        let tableIndex = extracted.tables.firstIndex(of: current) ?? 0
        let sales = 5_330_400 * BreakdownLLMAmountScale.thousandYen
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当連結会計年度",
            "profit_disclosed": false,
            "rows": [
                ["label": "MVNEサービス", "amount": 5_120_400, "profit": NSNull(), "row_kind": "segment"],
                ["label": "その他", "amount": 210_000, "profit": NSNull(), "row_kind": "segment"],
                [
                    "label": "顧客との契約から生じる収益", "amount": 5_330_400, "profit": NSNull(),
                    "row_kind": "subtotal",
                ],
            ],
            "notes": "LLM は million_yen と誤申告",
        ]
        let (snapshotOrNil, _) = await RevenueRecognitionLLMNormalizer.normalize(
            extracted, consolidatedSales: sales, client: MockChat(response)
        )
        let snapshot = try #require(snapshotOrNil)
        let mvne = try #require(snapshot.rows.first { $0.labelRaw == "MVNEサービス" })
        #expect(mvne.amount == 5_120_400 * BreakdownLLMAmountScale.thousandYen)
        #expect(mvne.amount != 5_120_400 * Financial.millionYen)
        #expect(snapshot.needsReview == false)
        #expect(snapshot.warnings.contains(BreakdownLLMAmountScale.headerLlmMismatchWarning))
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
        let response: [String: Any] = [
            "applicable": true,
            "unit": "other",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "製品A", "amount": 12_345, "profit": NSNull(), "row_kind": "segment"],
                ["label": "製品B", "amount": 7_655, "profit": NSNull(), "row_kind": "segment"],
                ["label": "合計", "amount": 20_000, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "LLM は other",
        ]
        let (snapshotOrNil, _) = await RevenueRecognitionLLMNormalizer.normalize(
            extracted, consolidatedSales: sales, client: MockChat(response)
        )
        let snapshot = try #require(snapshotOrNil)
        let productA = try #require(snapshot.rows.first { $0.labelRaw == "製品A" })
        #expect(productA.amount == 12_345 * BreakdownLLMAmountScale.thousandYen)
        #expect(snapshot.needsReview == false)
        #expect(!snapshot.warnings.contains("llm_unit_unresolved"))
        #expect(!snapshot.warnings.contains(BreakdownLLMAmountScale.headerLlmMismatchWarning))
        #expect(snapshot.sourceKind == "revenue_recognition")
        #expect(
            Self.publiclyServable(snapshot, source: breakdownSourceRevenueRecognitionLLM) == true)
    }

    @Test func millionYenHeaderKeepsMillionScaleWithoutMismatch() async throws {
        let html = """
            <table><tr><td>（単位：百万円）</td></tr></table>
            <table>
              <tr><td>製品A</td><td>10,000</td></tr>
              <tr><td>合計</td><td>10,000</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: Self.tables(from: html, heading: "収益認識関係"),
            facts: []
        )
        let sales = 10_000 * Financial.millionYen
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "製品A", "amount": 10_000, "profit": NSNull(), "row_kind": "segment"],
                ["label": "合計", "amount": 10_000, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "百万円",
        ]
        let (snapshotOrNil, _) = await RevenueRecognitionLLMNormalizer.normalize(
            extracted, consolidatedSales: sales, client: MockChat(response)
        )
        let snapshot = try #require(snapshotOrNil)
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
        let response: [String: Any] = [
            "applicable": true,
            "unit": "yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "事業A", "amount": 1_000_000_000, "profit": NSNull(), "row_kind": "segment"],
            ],
            "notes": "円",
        ]
        let (snapshotOrNil, _) = await SegmentInfoLLMNormalizer.normalize(
            extracted, consolidatedSales: sales, client: MockChat(response)
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.rows[0].amount == sales)
        #expect(!snapshot.warnings.contains(BreakdownLLMAmountScale.headerLlmMismatchWarning))
        #expect(!snapshot.needsReview)
    }

    @Test func noHeaderFallsBackToLLMForGeography() async throws {
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: [
                BreakdownTable(
                    heading: "地域ごとの情報",
                    markdown: "| 日本 | 合計 |\n| 100 | 100 |\n",
                    period: "当期")
            ],
            facts: []
        )
        let sales = 100 * Financial.millionYen
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "日本", "amount": 100, "row_kind": "segment"],
                ["label": "合計", "amount": 100, "row_kind": "subtotal"],
            ],
            "notes": "ヘッダー単位なし",
        ]
        let (snapshotOrNil, _) = await GeographyBreakdownLLMNormalizer.normalize(
            extracted, consolidatedSales: sales, client: MockChat(response)
        )
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
        let response: [String: Any] = [
            "applicable": true,
            "unit": "other",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "製品A", "amount": 100, "profit": NSNull(), "row_kind": "segment"],
            ],
            "notes": "単位不明",
        ]
        let (snapshotOrNil, _) = await RevenueRecognitionLLMNormalizer.normalize(
            extracted, consolidatedSales: 100 * Financial.millionYen, client: MockChat(response)
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.rows[0].amount == 100)
        #expect(snapshot.needsReview == true)
        #expect(snapshot.warnings.contains("llm_unit_unresolved"))
        #expect(
            Self.publiclyServable(snapshot, source: breakdownSourceRevenueRecognitionLLM) == false)
    }

    @Test func borrowedSiblingHeaderMismatchStaysUnservable() async throws {
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: [
                BreakdownTable(
                    heading: "契約資産", markdown: "| a | 1 |", period: "当期", unitCaption: "千円"),
                BreakdownTable(
                    heading: "収益分解",
                    markdown: "| MVNEサービス | 5,120,400 |\n| 合計 | 5,120,400 |\n",
                    period: "当期"),
            ],
            facts: []
        )
        let sales = 5_120_400 * BreakdownLLMAmountScale.thousandYen
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 1,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "MVNEサービス", "amount": 5_120_400, "profit": NSNull(), "row_kind": "segment"],
                ["label": "合計", "amount": 5_120_400, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "兄弟表から千円を借りた mismatch",
        ]
        let (snapshotOrNil, _) = await RevenueRecognitionLLMNormalizer.normalize(
            extracted, consolidatedSales: sales, client: MockChat(response)
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.rows[0].amount == sales)
        #expect(snapshot.needsReview == true)
        #expect(snapshot.warnings.contains(BreakdownLLMAmountScale.headerLlmMismatchWarning))
        #expect(
            Self.publiclyServable(snapshot, source: breakdownSourceRevenueRecognitionLLM) == false)
    }

    @Test func wrapperDivPrecedingHeaderMismatchIsServable() async throws {
        let html = """
            <p>１．顧客との契約から生じる収益を分解した情報</p>
            <p>当社グループは、生鮮流通プラットフォーム事業の単一セグメントであり、以下のとおりであります。</p>
            <p style="text-align: right">（単位：千円）</p>
            <div style="margin-left: 80px">
            <table>
              <tr><td>サービス別</td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>BtoBコマースサービス</td><td>5,471,053</td><td>6,348,109</td></tr>
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
        let current = extracted.tables.last { $0.period == "当期" } ?? extracted.tables.last!
        let tableIndex = extracted.tables.firstIndex(of: current) ?? 0
        let sales = 7_820_013 * BreakdownLLMAmountScale.thousandYen
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当連結会計年度",
            "profit_disclosed": false,
            "rows": [
                [
                    "label": "BtoBコマースサービス", "amount": 6_348_109, "profit": NSNull(),
                    "row_kind": "segment",
                ],
                [
                    "label": "その他", "amount": 1_471_904, "profit": NSNull(),
                    "row_kind": "segment",
                ],
                [
                    "label": "顧客との契約から生じる収益", "amount": 7_820_013, "profit": NSNull(),
                    "row_kind": "subtotal",
                ],
            ],
            "notes": "7114 / 7416 型: 単位は wrapper div の兄 p",
        ]
        let (snapshotOrNil, _) = await RevenueRecognitionLLMNormalizer.normalize(
            extracted, consolidatedSales: sales, client: MockChat(response)
        )
        let snapshot = try #require(snapshotOrNil)
        let btob = try #require(snapshot.rows.first { $0.labelRaw == "BtoBコマースサービス" })
        #expect(btob.amount == 6_348_109 * BreakdownLLMAmountScale.thousandYen)
        #expect(snapshot.needsReview == false)
        #expect(snapshot.warnings.contains(BreakdownLLMAmountScale.headerLlmMismatchWarning))
        #expect(!snapshot.warnings.contains("llm_unit_unresolved"))
        #expect(
            Self.publiclyServable(snapshot, source: breakdownSourceRevenueRecognitionLLM) == true)
    }
}
