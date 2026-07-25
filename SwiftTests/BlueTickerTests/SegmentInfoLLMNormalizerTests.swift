// SegmentInfoLLMNormalizer のユニットテスト（ChatCompleting をモック化）。
// キヤノン型（segments キー自体が html_table、US-GAAP注23の事業別セグメント表を列→行に転置）を
// 想定した business 軸正規化、利益(profit)抽出、profit_disclosed の整合性チェックを検証する。

import Testing
import Foundation
@testable import BlueTickerCore

private actor MockChatCompleting: ChatCompleting {
    private let responseJSON: [String: Any]
    private(set) var capturedSchemaName: String?

    init(responseJSON: [String: Any]) {
        self.responseJSON = responseJSON
    }

    func complete(system: String, user: String, jsonSchema: Data, schemaName: String) async throws -> Data {
        capturedSchemaName = schemaName
        return try JSONSerialization.data(withJSONObject: responseJSON)
    }

    func schemaName() async -> String? { capturedSchemaName }
}

@Suite struct SegmentInfoLLMNormalizerTests {

    private static func htmlTableResult(markdown: String = "| dummy |") -> ExtractedBreakdown {
        ExtractedBreakdown(
            method: "html_table",
            tables: [BreakdownTable(heading: "セグメント情報", markdown: markdown, period: "当期")],
            facts: []
        )
    }

    @Test func returnsNilWhenMethodIsNotHtmlTable() async {
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: [])
        let client = MockChatCompleting(responseJSON: ["applicable": true])
        let (snapshot, audit) = await SegmentInfoLLMNormalizer.normalize(
            result, consolidatedSales: 1_000_000, client: client
        )
        #expect(snapshot == nil)
        #expect(audit == nil)
    }

    /// キヤノン型: US-GAAP注23の事業別セグメント表（列見出しが事業名）を転置し、
    /// 営業利益も一緒に取得する。
    @Test func transposesColumnsAndCapturesProfit() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": true,
            "rows": [
                ["label": "プリンティング", "amount": 2_487_885, "profit": 255_759, "row_kind": "segment"],
                ["label": "メディカル", "amount": 579_723, "profit": 32_775, "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, audit) = await SegmentInfoLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: (2_487_885 + 579_723) * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.axis == "business")
        #expect(snapshot.sourceKind == "segment_info")
        #expect(snapshot.rows[0].profit == 255_759 * Financial.millionYen)
        #expect(snapshot.rows[1].profit == 32_775 * Financial.millionYen)
        #expect(!snapshot.needsReview)
        let schemaName = await client.schemaName()
        #expect(schemaName == "segment_info_breakdown")
        #expect(audit?.profitDisclosed == true)
    }

    @Test func flagsSuspicionWhenAllLabelsAreGeographic() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "日本", "amount": 600, "profit": NSNull(), "row_kind": "segment"],
                ["label": "米国", "amount": 400, "profit": NSNull(), "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await SegmentInfoLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 1_000_000, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("business_label_looks_like_geography"))
    }

    @Test func doesNotFlagSuspicionWhenLabelsAreDomesticOverseasPrefixedBusinessNames() async throws {
        // キッコーマン型の回帰（issue調査 2026-07-21）: 「国内食料品製造・販売」
        // 「海外食料品製造・販売」のような事業区分×国内海外クロス集計は、全行が
        // 「国内」「海外」を含むため誤って地域別表と判定されていた。特定の国・地域名
        // （日本・米国等）を1件も伴わない場合は誤検知としてガードを立てない。
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "国内食料品製造・販売", "amount": 155_718, "profit": NSNull(), "row_kind": "segment"],
                ["label": "海外食料品製造・販売", "amount": 149_491, "profit": NSNull(), "row_kind": "segment"],
                ["label": "海外食料品卸売", "amount": 432_800, "profit": NSNull(), "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await SegmentInfoLLMNormalizer.normalize(
            Self.htmlTableResult(),
            consolidatedSales: (155_718 + 149_491 + 432_800) * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(!snapshot.needsReview)
        #expect(!snapshot.warnings.contains("business_label_looks_like_geography"))
    }

    @Test func flagsInconsistencyWhenDisclosedButNoRowHasProfit() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": true,
            "rows": [
                ["label": "プリンティング", "amount": 2_487_885, "profit": NSNull(), "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await SegmentInfoLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 4_624_727_000_000, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("profit_disclosed_but_row_missing"))
    }

    /// 野村HD型の回帰（issue #105）: 証券会社は資金調達費用（金融費用）が大きく、
    /// セグメント表の「収益合計（金融費用控除後）」は連結売上高（総額）の半分以下になる。
    /// segment 合計が表自身の subtotal 行（「計」）と一致する場合、
    /// consolidatedSales 基準では乖離しても needs_review を立てず、subtotal へ分母を差し替える。
    /// 「その他（消去分を含む）」は LLM が reconciling と返しても残事業バケットとして segment に直す
    /// （ユーザー確認 2026-07-25）。
    @Test func fallsBackToInternalSubtotalWhenSalesBasisMismatchesButTableReconciles() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "2026年３月期",
            "profit_disclosed": true,
            "rows": [
                ["label": "ウェルス・マネジメント部門", "amount": 487_906, "profit": 204_024, "row_kind": "segment"],
                ["label": "インベストメント・マネジメント部門", "amount": 258_516, "profit": 88_297, "row_kind": "segment"],
                ["label": "ホールセール部門", "amount": 1_162_229, "profit": 200_567, "row_kind": "segment"],
                ["label": "バンキング部門", "amount": 53_918, "profit": 14_016, "row_kind": "segment"],
                // LLM が誤って reconciling と返しても決定的に segment へ直すことを検証する。
                ["label": "その他（消去分を含む）", "amount": 196_873, "profit": 24_646, "row_kind": "reconciling"],
                ["label": "計", "amount": 2_159_442, "profit": 531_550, "row_kind": "subtotal"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await SegmentInfoLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 4_758_486 * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(!snapshot.needsReview)
        #expect(snapshot.denominatorTag == "llm_table_subtotal")
        #expect(snapshot.denominator == 2_159_442 * Financial.millionYen)
        #expect(snapshot.warnings.contains("llm_denominator_from_internal_subtotal"))
        #expect(!snapshot.warnings.contains("llm_row_sum_mismatch"))
        let otherRow = try #require(snapshot.rows.first { $0.labelRaw == "その他（消去分を含む）" })
        #expect(otherRow.rowKind == "segment")
        let wealthRow = try #require(snapshot.rows.first { $0.labelRaw == "ウェルス・マネジメント部門" })
        #expect(wealthRow.share == 487_906 * Financial.millionYen / (2_159_442 * Financial.millionYen))
        let segmentShare = snapshot.rows.filter { $0.rowKind == "segment" }
            .reduce(0.0) { $0 + ($1.share ?? 0) }
        #expect(abs(segmentShare - 1.0) < 0.001)
    }

    @Test func keepsPureEliminationRowsAsReconciling() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "A事業", "amount": 80, "profit": NSNull(), "row_kind": "segment"],
                ["label": "B事業", "amount": 20, "profit": NSNull(), "row_kind": "segment"],
                ["label": "消去", "amount": 0, "profit": NSNull(), "row_kind": "reconciling"],
                ["label": "その他の調整額", "amount": 0, "profit": NSNull(), "row_kind": "reconciling"],
                ["label": "計", "amount": 100, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await SegmentInfoLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 100 * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        let elim = try #require(snapshot.rows.first { $0.labelRaw == "消去" })
        #expect(elim.rowKind == "reconciling")
        let otherAdj = try #require(snapshot.rows.first { $0.labelRaw == "その他の調整額" })
        #expect(otherAdj.rowKind == "reconciling")
    }

    /// subtotal行がsegment+reconciling合計から大きく乖離する（5%超）場合はフォールバックせず、
    /// 表取り違えの疑いとしてneeds_reviewを維持する。
    @Test func doesNotFallBackWhenSubtotalFarFromSegmentSum() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "A事業", "amount": 100, "profit": NSNull(), "row_kind": "segment"],
                ["label": "B事業", "amount": 100, "profit": NSNull(), "row_kind": "segment"],
                ["label": "計", "amount": 400, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await SegmentInfoLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 1_000 * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("llm_row_sum_mismatch"))
        #expect(snapshot.denominatorTag == "income_statement.sales")
    }

    @Test func flagsUnresolvedWhenProfitDisclosedKeyMissing() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "プリンティング", "amount": 1_000, "profit": NSNull(), "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, audit) = await SegmentInfoLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 1_000 * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("llm_profit_disclosed_unresolved"))
        #expect(audit?.profitDisclosed == false)
    }
}
