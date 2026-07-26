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

    private static func htmlTableResult(markdown: String = "| dummy |") -> ExtractedBreakdown {
        ExtractedBreakdown(
            method: "html_table",
            tables: [BreakdownTable(heading: "収益認識関係", markdown: markdown, period: "当期")],
            facts: []
        )
    }

    @Test func returnsNilWhenMethodIsNotHtmlTable() async {
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: [])
        let client = MockChatCompleting(responseJSON: ["applicable": true])
        let (snapshot, audit) = await RevenueRecognitionLLMNormalizer.normalize(
            result, consolidatedSales: 1_000_000, client: client
        )
        #expect(snapshot == nil)
        #expect(audit == nil)
    }

    /// ファナック型: 部門が列・地域が行のマトリクス表から、合計行の列金額を転置した LLM 応答を受け入れる。
    /// （プロンプト側で転置を指示。本テストは決定的ガードが転置後の事業ラベルを通すことだけを見る。）
    @Test func acceptsTransposedDepartmentColumnsFromGeographyMatrix() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 1,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "ＦＡ", "amount": 208_478, "profit": NSNull(), "row_kind": "segment"],
                ["label": "ロボット", "amount": 378_610, "profit": NSNull(), "row_kind": "segment"],
                ["label": "ロボマシン", "amount": 129_600, "profit": NSNull(), "row_kind": "segment"],
                ["label": "サービス", "amount": 141_143, "profit": NSNull(), "row_kind": "segment"],
                ["label": "外部顧客への売上高", "amount": 857_831, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "当期表の外部顧客への売上高行から部門列を転置",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, audit) = await RevenueRecognitionLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 857_831 * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.axis == "business")
        #expect(snapshot.needsReview == false)
        #expect(!snapshot.warnings.contains("business_label_mismatch"))
        #expect(!snapshot.warnings.contains("llm_row_sum_mismatch"))
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        #expect(segments.map(\.labelRaw) == ["ＦＡ", "ロボット", "ロボマシン", "サービス"])
        #expect(segments.map(\.amount) == [
            208_478 * Financial.millionYen,
            378_610 * Financial.millionYen,
            129_600 * Financial.millionYen,
            141_143 * Financial.millionYen,
        ])
        #expect(audit?.sourceTableIndex == 1)
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

    /// 地域名らしい行が過半数なら地域別表の取り違えとみなし business_label_mismatch。
    @Test func flagsWhenAllSegmentLabelsLookLikeGeography() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "日本", "amount": 600, "profit": NSNull(), "row_kind": "segment"],
                ["label": "米州", "amount": 400, "profit": NSNull(), "row_kind": "segment"],
                ["label": "合計", "amount": 1_000, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "誤って地域別表を採用",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await RevenueRecognitionLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 1_000 * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("business_label_mismatch"))
    }

    /// 地域表に「その他」が1行混ざるケースでも過半数ルールで mismatch になること。
    @Test func flagsMajorityGeographyTableEvenWithOtherBucket() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "日本", "amount": 500, "profit": NSNull(), "row_kind": "segment"],
                ["label": "北米", "amount": 200, "profit": NSNull(), "row_kind": "segment"],
                ["label": "欧州", "amount": 150, "profit": NSNull(), "row_kind": "segment"],
                ["label": "アジア", "amount": 100, "profit": NSNull(), "row_kind": "segment"],
                ["label": "その他", "amount": 50, "profit": NSNull(), "row_kind": "segment"],
                ["label": "合計", "amount": 1_000, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "地域表＋その他",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await RevenueRecognitionLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 1_000 * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("business_label_mismatch"))
    }

    /// パンパシHD型: 製品明細＋海外地域残。地域行が混ざっても製品行があれば mismatch にしない。
    @Test func acceptsProductRowsWithOverseasGeographyRemainder() async throws {
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 1,
            "period_column": "合計",
            "profit_disclosed": false,
            "rows": [
                ["label": "家電製品（ディスカウントストア）", "amount": 92_391, "profit": NSNull(), "row_kind": "segment"],
                ["label": "日用雑貨品（ディスカウントストア）", "amount": 393_490, "profit": NSNull(), "row_kind": "segment"],
                ["label": "食品（ディスカウントストア）", "amount": 613_713, "profit": NSNull(), "row_kind": "segment"],
                ["label": "時計・ファッション用品（ディスカウントストア）", "amount": 182_209, "profit": NSNull(), "row_kind": "segment"],
                ["label": "スポーツ・レジャー用品（ディスカウントストア）", "amount": 92_288, "profit": NSNull(), "row_kind": "segment"],
                ["label": "その他（ディスカウントストア）", "amount": 21_998, "profit": NSNull(), "row_kind": "segment"],
                ["label": "衣料品（総合スーパー）", "amount": 43_789, "profit": NSNull(), "row_kind": "segment"],
                ["label": "住居関連品（総合スーパー）", "amount": 67_551, "profit": NSNull(), "row_kind": "segment"],
                ["label": "食品（総合スーパー）", "amount": 313_828, "profit": NSNull(), "row_kind": "segment"],
                ["label": "その他（総合スーパー）", "amount": 986, "profit": NSNull(), "row_kind": "segment"],
                ["label": "海外（北米）", "amount": 257_088, "profit": NSNull(), "row_kind": "segment"],
                ["label": "海外（アジア）", "amount": 91_037, "profit": NSNull(), "row_kind": "segment"],
                ["label": "顧客との契約から生じる収益", "amount": 2_170_368, "profit": NSNull(), "row_kind": "subtotal"],
                ["label": "その他の収益", "amount": 76_390, "profit": NSNull(), "row_kind": "segment"],
                ["label": "外部顧客への売上高", "amount": 2_246_758, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "製品明細＋海外残。合計列で分母一致",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, _) = await RevenueRecognitionLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 2_246_758 * Financial.millionYen, client: client
        )
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview == false)
        #expect(!snapshot.warnings.contains("business_label_mismatch"))
        #expect(!snapshot.warnings.contains("llm_row_sum_mismatch"))
        let labels = Set(snapshot.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw))
        #expect(labels.contains("家電製品（ディスカウントストア）"))
        #expect(labels.contains("海外（北米）"))
        #expect(labels.contains("海外（アジア）"))
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

    /// issue #135: LLM が「地域別のみで事業別データが無い」と判定した場合、applicable=false と
    /// 併せて not_applicable_reason=geography_only を返す。audit 経由で呼び出し元
    /// （`BusinessBreakdownResolver`）まで理由が伝搬すること。
    @Test func propagatesGeographyOnlyReasonWhenNotApplicable() async {
        let response: [String: Any] = [
            "applicable": false,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [[String: Any]](),
            "not_applicable_reason": "geography_only",
            "notes": "仕向地別の地域分解のみで事業別データが存在しない",
        ]
        let client = MockChatCompleting(responseJSON: response)
        let (snapshotOrNil, audit) = await RevenueRecognitionLLMNormalizer.normalize(
            Self.htmlTableResult(), consolidatedSales: 1_000 * Financial.millionYen, client: client
        )
        #expect(snapshotOrNil == nil)
        #expect(audit?.notApplicableReason == "geography_only")
    }
}
