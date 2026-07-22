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
