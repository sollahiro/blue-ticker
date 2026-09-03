// BusinessBreakdownResolver のユニットテスト。
// `BreakdownExtractor.extractSegmentInfo` の axis-aware swap（オークマ型は既に収益認識注記へ
// swap 済みで返る）を前提に、以降の振り分け（xbrl_facts / revenue_recognition_llm /
// segment_info_llm）を実データ golden + モック LLM で検証する。

import Testing
import Foundation
@testable import BlueTickerCore

private actor MockChatCompleting: ChatCompleting {
    private let responseJSON: [String: Any]?
    private(set) var callCount = 0

    init(responseJSON: [String: Any]?) {
        self.responseJSON = responseJSON
    }

    func complete(system: String, user: String, jsonSchema: Data, schemaName: String) async throws -> Data {
        callCount += 1
        guard let responseJSON else { throw ChatCompletionError.emptyContent }
        return try JSONSerialization.data(withJSONObject: responseJSON)
    }

    func timesCalled() async -> Int { callCount }
}

@Suite struct BusinessBreakdownResolverTests {

    private static func loadGolden() throws -> [String: [String: Any]] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let path = root.appendingPathComponent("smoke/breakdown_extraction_expected.json")
        let data = try Data(contentsOf: path)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
    }

    private static func loadSales(code: String) throws -> Double? {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dir = root.appendingPathComponent("smoke/smoke_expected")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let matches = files.filter { $0.hasPrefix("\(code)_") }.sorted()
        for file in matches {
            let data = try Data(contentsOf: dir.appendingPathComponent(file))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let income = json?["income_statement"] as? [String: Any]
            if let sales = (income?["sales"] as? NSNumber)?.doubleValue { return sales }
        }
        return nil
    }

    private static func segmentsResult(docID: String) throws -> ExtractedBreakdown {
        let golden = try loadGolden()
        let entry = try #require(golden[docID])
        let segDict = try #require(entry["segments"] as? [String: Any])
        return ExtractedBreakdown(dictionary: segDict)
    }

    /// 味の素（xbrl_facts, axis=business）: 決定的経路のみで解決し、LLM は一切呼ばれない。
    @Test func xbrlFactsBusinessAxisResolvesWithoutCallingLLM() async throws {
        let segments = try Self.segmentsResult(docID: "S100VXJA")
        let sales = try #require(try Self.loadSales(code: "2802"))
        let client = MockChatCompleting(responseJSON: nil)

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .xbrlFacts)
        #expect(snapshot?.axis == "business")
        #expect(audit == nil)
        #expect(await client.timesCalled() == 0)
    }

    /// オークマ（segments は既に収益認識関係へ swap 済み、見出しで振り分けて
    /// RevenueRecognitionLLMNormalizer 経由で解決する）。
    @Test func okumaSwappedSegmentsResolveViaRevenueRecognitionLLM() async throws {
        let segments = try Self.segmentsResult(docID: "S100W043")
        #expect(segments.method == "html_table")
        #expect(segments.tables.first?.heading == "収益認識関係")
        let sales = try #require(try Self.loadSales(code: "6103"))

        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 1,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "ＮＣ旋盤", "amount": 37_366, "profit": NSNull(), "row_kind": "segment"],
                ["label": "マシニングセンタ", "amount": 104_235, "profit": NSNull(), "row_kind": "segment"],
                ["label": "複合加工機", "amount": 55_653, "profit": NSNull(), "row_kind": "segment"],
                ["label": "ＮＣ研削盤", "amount": 2_280, "profit": NSNull(), "row_kind": "segment"],
                ["label": "その他", "amount": 7_287, "profit": NSNull(), "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == "business")
        #expect(!(snapshot?.needsReview ?? true))
        #expect(audit != nil)
        #expect(await client.timesCalled() == 1)
    }

    /// 収益認識 LLM が needs_review（分母不一致など）でも snapshot は採用する。
    /// 捨てると単一セグメント開示（F）へ落ち、東京エレクトロン型の製品別が取れない。
    @Test func revenueRecognitionLLMResultWithNeedsReviewIsStillAdopted() async throws {
        let segments = try Self.segmentsResult(docID: "S100W043")
        #expect(segments.tables.first?.heading == "収益認識関係")
        let sales = try #require(try Self.loadSales(code: "6103"))

        // 分母（sales）の117%相当を返し、llm_row_sum_mismatch で needs_review が立つ
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "前期",
            "profit_disclosed": false,
            "rows": [
                ["label": "ＮＣ旋盤", "amount": (sales * 1.17) / Financial.millionYen, "profit": NSNull(), "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.needsReview == true)
        #expect(snapshot?.warnings.contains("llm_row_sum_mismatch") == true)
    }

    /// Grok 4.5 レビュー指摘の回帰テスト（issue調査 2026-07-21）: `method == "xbrl_facts"` でも
    /// facts の正規化に失敗する（未知タグで売上高・銀行・保険いずれの経路にも一致しない）場合、
    /// tables が非空なら LLM の表フォールバックへ回る（facts 優先化で tables を破棄していた頃は
    /// ここで永久に notFound になっていた）。
    @Test func xbrlFactsMethodFallsBackToSegmentInfoLLMWhenFactsDoNotNormalize() async throws {
        let unresolvableFact = BreakdownFact(
            tag: "SomeUnknownProprietaryMetricNotInAnyWhitelist",
            contextRef: "CurrentYearDuration_AlphaMember",
            dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
            value: 999, label: nil, unitRef: "JPY", decimals: "-6"
        )
        let table = BreakdownTable(
            heading: "セグメント情報",
            markdown: "| 事業A | 事業B |\n|---|---|\n| 600 | 400 |",
            period: "当期"
        )
        let segments = ExtractedBreakdown(method: "xbrl_facts", tables: [table], facts: [unresolvableFact])

        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "事業A", "amount": 600, "profit": NSNull(), "row_kind": "segment"],
                ["label": "事業B", "amount": 400, "profit": NSNull(), "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: 1_000_000_000, client: client
        )

        #expect(source == .segmentInfoLLM)
        #expect(snapshot?.axis == "business")
        #expect(await client.timesCalled() == 1)
    }

    /// 富士フイルム（積み上げセグメント損益表）: 決定論寄せで解決し、LLM を呼ばない。
    /// 研究開発費ブロックを profit に誤寄せしないこと（S100W3XJ / S100YIBH 同型）。
    @Test func fujifilmStackedSegmentPnLResolvesWithoutCallingLLM() async throws {
        let segments = try Self.segmentsResult(docID: "S100W3XJ")
        #expect(segments.method == "html_table")
        let sales = try #require(try Self.loadSales(code: "4901"))
        let client = MockChatCompleting(responseJSON: nil)

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .stackedSegmentPnL)
        #expect(audit == nil)
        #expect(await client.timesCalled() == 0)
        let snap = try #require(snapshot)
        #expect(snap.sourceKind == "stacked_segment_pnl")
        let byLabel = Dictionary(
            uniqueKeysWithValues: snap.rows.filter { $0.rowKind == "segment" }.map {
                ($0.labelRaw, $0)
            })
        #expect(byLabel["ヘルスケア"]?.profit == 77_635 * Financial.millionYen)
        #expect(byLabel["ヘルスケア"]?.profit != 60_698 * Financial.millionYen)  // 研究開発費でない
        #expect(byLabel["エレクトロニクス"]?.profit == 77_315 * Financial.millionYen)
        #expect(byLabel["ビジネスイノベーション"]?.profit == 74_614 * Financial.millionYen)
        #expect(byLabel["イメージング"]?.profit == 139_214 * Financial.millionYen)
    }

    /// キヤノン（segments が html_table。US-GAAP 注23、見出しが「セグメント情報」で振り分けて
    /// SegmentInfoLLMNormalizer 経由で解決する）。
    @Test func canonSegmentInfoResolvesViaSegmentInfoLLM() async throws {
        let segments = try Self.segmentsResult(docID: "S100XTLJ")
        #expect(segments.method == "html_table")
        #expect(segments.tables.first?.heading != "収益認識関係")
        let sales = try #require(try Self.loadSales(code: "7751"))

        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 1,
            "period_column": "当期",
            "profit_disclosed": true,
            "rows": [
                ["label": "プリンティング", "amount": 2_487_885, "profit": 255_759, "row_kind": "segment"],
                ["label": "メディカル", "amount": 579_723, "profit": 32_775, "row_kind": "segment"],
                ["label": "イメージング", "amount": 1_054_513, "profit": 172_871, "row_kind": "segment"],
                ["label": "インダストリアル", "amount": 357_924, "profit": 62_525, "row_kind": "segment"],
                ["label": "その他及び全社", "amount": 144_682, "profit": -69_451, "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .segmentInfoLLM)
        #expect(snapshot?.axis == "business")
        #expect(!(snapshot?.needsReview ?? true))
        #expect(audit?.profitDisclosed == true)
        #expect(await client.timesCalled() == 1)
    }

    /// swap 対象の収益認識関係注記が見つからず `BreakdownExtractor` 側のフォールバックで
    /// 元の地域別 xbrl_facts がそのまま返ってきたケース（tables も空）。
    /// axis が geography のままの xbrl_facts は business としては採用せず not_found にする。
    /// 合成 fact（実データ golden には該当書類が無いため）で決定的に検証する。
    @Test func geographyAxisFallbackWithoutSwapIsNotFound() async throws {
        let segments = ExtractedBreakdown(
            method: "xbrl_facts",
            tables: [],
            facts: [
                BreakdownFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_JapanReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "JapanReportableSegmentsMember"],
                    value: 600_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
                BreakdownFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_OverseasReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "OverseasReportableSegmentsMember"],
                    value: 400_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
            ]
        )
        let client = MockChatCompleting(responseJSON: nil)

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: 1_000_000_000_000, client: client
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
        #expect(audit == nil)
        #expect(await client.timesCalled() == 0)
    }

    /// 住友ファーマ型: 報告セグメント facts は geography だが、セグメント注記 tables に製品別表が残る。
    /// geography snapshot を短絡 discard せず、SegmentInfoLLM へフォールバックする。
    @Test func geographyAxisWithSegmentTablesFallsBackToSegmentInfoLLM() async throws {
        let segments = ExtractedBreakdown(
            method: "xbrl_facts",
            tables: [
                BreakdownTable(
                    heading: "セグメント情報",
                    markdown: """
                    | 製品 | 前連結会計年度 | 当連結会計年度 |
                    |---|---|---|
                    | ラツーダ | 13153 | 13694 |
                    | ツイミーグ | 7614 | 10581 |
                    | 合計 | 398832 | 453294 |
                    """,
                    period: "当期"
                ),
            ],
            facts: [
                BreakdownFact(
                    tag: "RevenueFromExternalCustomersIFRS",
                    contextRef: "CurrentYearDuration_JapanReportableSegmentMember",
                    dimensions: ["OperatingSegmentsAxis": "JapanReportableSegmentMember"],
                    value: 92_365_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
                BreakdownFact(
                    tag: "RevenueFromExternalCustomersIFRS",
                    contextRef: "CurrentYearDuration_NorthAmericaReportableSegmentMember",
                    dimensions: ["OperatingSegmentsAxis": "NorthAmericaReportableSegmentMember"],
                    value: 337_923_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
            ]
        )
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当連結会計年度",
            "profit_disclosed": false,
            "rows": [
                ["label": "ラツーダ", "amount": 13_694, "profit": NSNull(), "row_kind": "segment"],
                ["label": "ツイミーグ", "amount": 10_581, "profit": NSNull(), "row_kind": "segment"],
            ],
            "notes": "製品及びサービスごとの情報を採用",
        ]
        let client = MockChatCompleting(responseJSON: response)

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: 453_294_000_000, client: client
        )

        #expect(source == .segmentInfoLLM)
        #expect(snapshot?.axis == "business")
        #expect(await client.timesCalled() == 1)
    }

    /// issue #135: LLM が applicable=false・not_applicable_reason=geography_only を返した場合、
    /// resolve() は not_found を返しつつ、その audit（理由込み）を呼び出し元へ持ち帰ること
    /// （`BltServerFacade.resolveBusinessBreakdown` が `classifyNotApplicableReason` の
    /// llmHint に使う）。以前は notFound 確定時に audit を nil で握り潰していた。
    @Test func propagatesAuditWithGeographyOnlyReasonWhenLlmSaysNotApplicable() async throws {
        let segments = try Self.segmentsResult(docID: "S100XTLJ")
        #expect(segments.method == "html_table")
        let sales = try #require(try Self.loadSales(code: "7751"))

        let response: [String: Any] = [
            "applicable": false,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [[String: Any]](),
            "not_applicable_reason": "geography_only",
            "notes": "地域別のみで事業別データが存在しない",
        ]
        let client = MockChatCompleting(responseJSON: response)

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
        #expect(audit?.notApplicableReason == "geography_only")
    }

    /// issue #135: revenueRecognitionLLM 経路でも同様に、applicable=false・
    /// not_applicable_reason=geography_only のとき audit が notFound まで伝搬すること
    /// （segmentInfoLLM 経路は `propagatesAuditWithGeographyOnlyReasonWhenLlmSaysNotApplicable` で
    /// カバー済み。Opus監査 2026-07-26 指摘: 両分岐を個別に検証する）。
    @Test func revenueRecognitionLLMPropagatesAuditWithGeographyOnlyReasonWhenNotApplicable() async throws {
        let segments = try Self.segmentsResult(docID: "S100W043")
        #expect(segments.tables.first?.heading == "収益認識関係")
        let sales = try #require(try Self.loadSales(code: "6103"))

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

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
        #expect(audit?.notApplicableReason == "geography_only")
    }

    /// 収益認識 LLM が needs_review でも採用する。schema 制約で埋まった
    /// not_applicable_reason（applicable=true）は audit へ漏らさない。
    @Test func adoptedNeedsReviewResultDoesNotLeakStrayNotApplicableReasonIntoAudit() async throws {
        let segments = try Self.segmentsResult(docID: "S100W043")
        #expect(segments.tables.first?.heading == "収益認識関係")
        let sales = try #require(try Self.loadSales(code: "6103"))

        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "前期",
            "profit_disclosed": false,
            "rows": [
                ["label": "ＮＣ旋盤", "amount": (sales * 1.17) / Financial.millionYen, "profit": NSNull(), "row_kind": "segment"],
            ],
            // schema 制約でやむなく埋まった値。applicable=true のため無視されるべき。
            "not_applicable_reason": "geography_only",
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(snapshot?.needsReview == true)
        #expect(source == .revenueRecognitionLLM)
        #expect(audit?.notApplicableReason == nil)
    }

    /// segments が not_found の場合は何も呼ばない。
    @Test func segmentsNotFoundReturnsNotFound() async throws {
        let segments = ExtractedBreakdown(method: "not_found", tables: [], facts: [])
        let client = MockChatCompleting(responseJSON: nil)

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: 1_000_000, client: client
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
        #expect(await client.timesCalled() == 0)
    }
}
