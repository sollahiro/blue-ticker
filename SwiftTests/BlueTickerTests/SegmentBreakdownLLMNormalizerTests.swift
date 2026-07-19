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

    /// キヤノン型: 事業別セグメント表に営業利益行も並んでいる場合、profit も unit 換算して拾う。
    /// profit_disclosed=true と rows の profit 値が整合しているため needsReview は立たない。
    @Test func businessAxisCapturesOptionalProfitWhenLLMProvidesIt() async throws {
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
        // 分母整合性チェック対象外にするため、consolidatedSales はこの2行の合計に合わせる
        // （実キヤノンは5事業だが、このテストの主眼は profit の抽出であって分母整合性ではない）。
        let (snapshotOrNil, audit) = await SegmentBreakdownLLMNormalizer.normalize(
            Self.htmlTableResult(), axis: "business", consolidatedSales: (2_487_885 + 579_723) * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.rows[0].profit == 255_759 * Financial.millionYen)
        #expect(snapshot.rows[1].profit == 32_775 * Financial.millionYen)
        // needsReview 全体ではなく profit 関連警告に限定して見る（他の決定的チェックが将来
        // 追加されてもこのテストの主眼＝profit 抽出の正しさには影響させないため）。
        #expect(!snapshot.warnings.contains("profit_disclosed_but_row_missing"))
        #expect(!snapshot.warnings.contains("profit_present_despite_not_disclosed"))
        #expect(!snapshot.warnings.contains("llm_profit_disclosed_unresolved"))
        #expect(audit?.profitDisclosed == true)
    }

    /// オークマ型: 収益認識注記には利益が無いため、LLM が profit=null・profit_disclosed=false を返す。
    /// JSON null は NSNumber キャストが自然に nil になるだけで、決して 0 や誤った値を作らない。
    /// 「未開示（確認済み）」を表す組み合わせであり needsReview は立たない。
    @Test func businessAxisLeavesProfitNilWhenLLMReturnsNull() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "ＮＣ旋盤", "amount": 37_366, "profit": NSNull(), "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        // 分母整合性チェック対象外にするため、consolidatedSales はこの1行の合計に合わせる。
        let (snapshotOrNil, audit) = await SegmentBreakdownLLMNormalizer.normalize(
            Self.htmlTableResult(), axis: "business", consolidatedSales: 37_366 * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.rows[0].profit == nil)
        #expect(!snapshot.warnings.contains("profit_disclosed_but_row_missing"))
        #expect(!snapshot.warnings.contains("profit_present_despite_not_disclosed"))
        #expect(!snapshot.warnings.contains("llm_profit_disclosed_unresolved"))
        #expect(audit?.profitDisclosed == false)
    }

    /// profit_disclosed=true と自己申告したのに rows に profit が1件も無いのは矛盾（LLM の見落とし
    /// の疑いがある）ため needsReview で拾う。「未開示（確認済み）」と取り違えさせないための要。
    @Test func businessAxisFlagsInconsistencyWhenDisclosedButNoRowHasProfit() async throws {
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
        let (snapshotOrNil, _) = await SegmentBreakdownLLMNormalizer.normalize(
            Self.htmlTableResult(), axis: "business", consolidatedSales: 4_624_727_000_000, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("profit_disclosed_but_row_missing"))
    }

    /// profit_disclosed=false と自己申告したのに rows に profit 値が入っているのも矛盾。
    @Test func businessAxisFlagsInconsistencyWhenNotDisclosedButRowHasProfit() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "ＮＣ旋盤", "amount": 37_366, "profit": 5_000, "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await SegmentBreakdownLLMNormalizer.normalize(
            Self.htmlTableResult(), axis: "business", consolidatedSales: 1_000_000, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("profit_present_despite_not_disclosed"))
    }

    /// profit_disclosed キーが欠落・型不正な場合、silent に false（＝「未開示確認済み」）扱いせず
    /// 「不明」として needs_review で拾う（Fable監査指摘。unit の "other" フラグ付けと同じ考え方）。
    @Test func businessAxisFlagsUnresolvedWhenProfitDisclosedKeyMissing() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            // profit_disclosed キーを意図的に省略する
            "rows": [
                ["label": "ＮＣ旋盤", "amount": 37_366, "profit": NSNull(), "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, audit) = await SegmentBreakdownLLMNormalizer.normalize(
            Self.htmlTableResult(), axis: "business", consolidatedSales: 37_366 * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("llm_profit_disclosed_unresolved"))
        #expect(audit?.profitDisclosed == false)
    }

    /// geography 軸は profit_disclosed・profit ともプロンプト任せにせずコード側で常に無効化する
    /// （Fable監査指摘）。LLM が誤って profit 値・profit_disclosed=true を返しても無視される。
    @Test func geographyAxisAlwaysClampsProfitToNilRegardlessOfLLMResponse() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": true,
            "rows": [
                ["label": "日本", "amount": 600, "profit": 100, "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, audit) = await SegmentBreakdownLLMNormalizer.normalize(
            Self.htmlTableResult(), axis: "geography", consolidatedSales: 1_000_000, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.rows[0].profit == nil)
        #expect(audit?.profitDisclosed == false)
        #expect(!snapshot.warnings.contains("profit_present_despite_not_disclosed"))
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
