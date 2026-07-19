// SegmentBreakdownLLMNormalizer のユニットテスト（ChatCompleting をモック化）。
// axis="geography"（既存回帰）と axis="business"（今後の検討事項3で追加）の両方を検証する。

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

@Suite struct SegmentBreakdownLLMNormalizerTests {

    private static func htmlTableResult(markdown: String = "| dummy |") -> SegmentResult {
        SegmentResult(
            method: "html_table",
            tables: [SegmentTable(heading: "テスト", markdown: markdown, period: "当期")],
            facts: []
        )
    }

    @Test func returnsNilWhenMethodIsNotHtmlTable() async {
        let result = SegmentResult(method: "xbrl_facts", tables: [], facts: [])
        let client = MockChatCompleting(responseJSON: ["applicable": true])
        let (snapshot, audit) = await SegmentBreakdownLLMNormalizer.normalize(
            result, axis: "business", consolidatedSales: 1_000_000, client: client
        )
        #expect(snapshot == nil)
        #expect(audit == nil)
    }

    @Test func returnsNilWhenConsolidatedSalesMissing() async {
        let client = MockChatCompleting(responseJSON: ["applicable": true])
        let (snapshot, audit) = await SegmentBreakdownLLMNormalizer.normalize(
            Self.htmlTableResult(), axis: "geography", consolidatedSales: nil, client: client
        )
        #expect(snapshot == nil)
        #expect(audit == nil)
    }

    @Test func geographyAxisProducesGeographySnapshotAndSchemaName() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "日本", "amount": 600, "row_kind": "segment"],
                ["label": "米州", "amount": 400, "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, audit) = await SegmentBreakdownLLMNormalizer.normalize(
            Self.htmlTableResult(), axis: "geography", consolidatedSales: 1_000_000_000, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.axis == "geography")
        #expect(snapshot.sourceKind == "html_table")
        #expect(!snapshot.needsReview)
        #expect(snapshot.rows.count == 2)
        let schemaName = await client.schemaName()
        #expect(schemaName == "geography_breakdown")
        #expect(audit?.unit == "million_yen")
    }

    @Test func businessAxisProducesBusinessSnapshotAndSchemaName() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "プリンティング", "amount": 2_487_885, "row_kind": "segment"],
                ["label": "メディカル", "amount": 579_723, "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await SegmentBreakdownLLMNormalizer.normalize(
            Self.htmlTableResult(), axis: "business", consolidatedSales: 4_624_727_000_000, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.axis == "business")
        #expect(!snapshot.warnings.contains("business_label_looks_like_geography"))
        let schemaName = await client.schemaName()
        #expect(schemaName == "business_breakdown")
    }

    @Test func geographyAxisFlagsMismatchWhenLabelsAreNotGeographic() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "プリンティング", "amount": 600, "row_kind": "segment"],
                ["label": "メディカル", "amount": 400, "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await SegmentBreakdownLLMNormalizer.normalize(
            Self.htmlTableResult(), axis: "geography", consolidatedSales: 1_000_000, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("geography_label_mismatch"))
    }

    @Test func businessAxisFlagsSuspicionWhenAllLabelsAreGeographic() async throws {
        // オークマ型の逆パターンの安全網: business を期待したのに地域名だけの表を拾ってしまうケース。
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "日本", "amount": 600, "row_kind": "segment"],
                ["label": "米国", "amount": 400, "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await SegmentBreakdownLLMNormalizer.normalize(
            Self.htmlTableResult(), axis: "business", consolidatedSales: 1_000_000, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("business_label_looks_like_geography"))
    }

    @Test func businessAxisFlagsSuspicionWhenAllLabelsAreGeographicExceptOtherRow() async throws {
        // Fable監査で指摘: 「その他の地域」を除外せずに allSatisfy すると、地域名だけの表でも
        // この1行の不一致でガードが素通りしてしまう（false negative）。「その他」を含むラベルを
        // 判定から除いた残りが全て地域名なら、それでも疑いを立てなければならない。
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "国内", "amount": 400, "row_kind": "segment"],
                ["label": "米州", "amount": 300, "row_kind": "segment"],
                ["label": "欧州", "amount": 200, "row_kind": "segment"],
                ["label": "アジア", "amount": 50, "row_kind": "segment"],
                ["label": "その他の地域", "amount": 50, "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await SegmentBreakdownLLMNormalizer.normalize(
            Self.htmlTableResult(), axis: "business", consolidatedSales: 1_000_000, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("business_label_looks_like_geography"))
    }

    @Test func businessAxisAllowsOtherLabelWithoutFlaggingGeographyMismatch() async throws {
        // 「その他」は地域名キーワードに含めない設計（学び参照）。事業別表の「その他」単独では
        // business_label_looks_like_geography を立てない（他行が事業名なら誤検知させない）。
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "ＮＣ旋盤", "amount": 700, "row_kind": "segment"],
                ["label": "その他", "amount": 300, "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await SegmentBreakdownLLMNormalizer.normalize(
            Self.htmlTableResult(), axis: "business", consolidatedSales: 1_000_000, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(!snapshot.warnings.contains("business_label_looks_like_geography"))
    }

    @Test func returnsNilSnapshotButAuditWhenNotApplicable() async throws {
        let response: [String: Any] = [
            "applicable": false,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [] as [[String: Any]],
            "notes": "該当なし",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, audit) = await SegmentBreakdownLLMNormalizer.normalize(
            Self.htmlTableResult(), axis: "business", consolidatedSales: 1_000_000, client: client
        )
        #expect(snapshotOrNil == nil)
        #expect(audit?.notes == "該当なし")
    }
}
