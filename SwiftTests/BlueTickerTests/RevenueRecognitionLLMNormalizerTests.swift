// RevenueRecognitionLLMNormalizer のユニットテスト（ChatCompleting をモック化）。
// 利益(profit)抽出と、profit_disclosed（「未開示確認済み」と「LLMの見落とし・不明」の区別）を検証する。

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

@Suite struct RevenueRecognitionLLMNormalizerTests {

    private static func htmlTableResult(markdown: String = "| dummy |") -> SegmentResult {
        SegmentResult(
            method: "html_table",
            tables: [SegmentTable(heading: "収益認識関係", markdown: markdown, period: "当期")],
            facts: []
        )
    }

    @Test func returnsNilWhenMethodIsNotHtmlTable() async {
        let result = SegmentResult(method: "xbrl_facts", tables: [], facts: [])
        let client = MockChatCompleting(responseJSON: ["applicable": true])
        let (snapshot, audit) = await RevenueRecognitionLLMNormalizer.normalize(
            result, consolidatedSales: 1_000_000, client: client
        )
        #expect(snapshot == nil)
        #expect(audit == nil)
    }

    /// オークマ型: 収益認識注記には製品別の利益が無いため、LLM が profit=null・profit_disclosed=false
    /// を返す。「未開示（確認済み）」を表す組み合わせであり needsReview は立たない。
    @Test func leavesProfitNilWhenNotDisclosed() async throws {
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
        let (snapshotOrNil, audit) = await RevenueRecognitionLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 37_366 * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.rows[0].profit == nil)
        #expect(!snapshot.warnings.contains("profit_disclosed_but_row_missing"))
        #expect(!snapshot.warnings.contains("profit_present_despite_not_disclosed"))
        #expect(!snapshot.warnings.contains("llm_profit_disclosed_unresolved"))
        #expect(audit?.profitDisclosed == false)
    }

    /// 収益認識注記であっても製品別利益が併記されているケース（稀だが構造上あり得る）は拾う。
    @Test func capturesProfitWhenDisclosed() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": true,
            "rows": [
                ["label": "製品A", "amount": 1_000, "profit": 100, "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, audit) = await RevenueRecognitionLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 1_000 * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.rows[0].profit == 100 * Financial.millionYen)
        #expect(!snapshot.needsReview)
        #expect(audit?.profitDisclosed == true)
    }

    @Test func flagsInconsistencyWhenDisclosedButNoRowHasProfit() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": true,
            "rows": [
                ["label": "製品A", "amount": 1_000, "profit": NSNull(), "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await RevenueRecognitionLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 1_000 * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("profit_disclosed_but_row_missing"))
    }

    @Test func flagsInconsistencyWhenNotDisclosedButRowHasProfit() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "製品A", "amount": 1_000, "profit": 100, "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await RevenueRecognitionLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 1_000 * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("profit_present_despite_not_disclosed"))
    }

    /// profit_disclosed キーが欠落・型不正な場合、silent に false（＝「未開示確認済み」）扱いせず
    /// 「不明」として needs_review で拾う。
    @Test func flagsUnresolvedWhenProfitDisclosedKeyMissing() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            // profit_disclosed キーを意図的に省略する
            "rows": [
                ["label": "製品A", "amount": 1_000, "profit": NSNull(), "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, audit) = await RevenueRecognitionLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 1_000 * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("llm_profit_disclosed_unresolved"))
        #expect(audit?.profitDisclosed == false)
    }
}
