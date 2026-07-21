// SegmentBusinessBreakdownResolver のユニットテスト。
// `SegmentExtractor.extractSegmentInfo` の axis-aware swap（オークマ型は既に収益認識注記へ
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

@Suite struct SegmentBusinessBreakdownResolverTests {

    private static func loadGolden() throws -> [String: [String: Any]] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let path = root.appendingPathComponent("smoke/segment_expected.json")
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

    private static func segmentsResult(docID: String) throws -> SegmentResult {
        let golden = try loadGolden()
        let entry = try #require(golden[docID])
        let segDict = try #require(entry["segments"] as? [String: Any])
        return SegmentResult(dictionary: segDict)
    }

    /// 味の素（xbrl_facts, axis=business）: 決定的経路のみで解決し、LLM は一切呼ばれない。
    @Test func xbrlFactsBusinessAxisResolvesWithoutCallingLLM() async throws {
        let segments = try Self.segmentsResult(docID: "S100VXJA")
        let sales = try #require(try Self.loadSales(code: "2802"))
        let client = MockChatCompleting(responseJSON: nil)

        let (snapshot, source, audit) = await SegmentBusinessBreakdownResolver.resolve(
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

        let (snapshot, source, audit) = await SegmentBusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == "business")
        #expect(!(snapshot?.needsReview ?? true))
        #expect(audit != nil)
        #expect(await client.timesCalled() == 1)
    }

    /// Grok 4.5 レビュー指摘の回帰テスト（issue調査 2026-07-21）: `method == "xbrl_facts"` でも
    /// facts の正規化に失敗する（未知タグで売上高・銀行・保険いずれの経路にも一致しない）場合、
    /// tables が非空なら LLM の表フォールバックへ回る（facts 優先化で tables を破棄していた頃は
    /// ここで永久に notFound になっていた）。
    @Test func xbrlFactsMethodFallsBackToSegmentInfoLLMWhenFactsDoNotNormalize() async throws {
        let unresolvableFact = SegmentFact(
            tag: "SomeUnknownProprietaryMetricNotInAnyWhitelist",
            contextRef: "CurrentYearDuration_AlphaMember",
            dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
            value: 999, label: nil, unitRef: "JPY", decimals: "-6"
        )
        let table = SegmentTable(
            heading: "セグメント情報",
            markdown: "| 事業A | 事業B |\n|---|---|\n| 600 | 400 |",
            period: "当期"
        )
        let segments = SegmentResult(method: "xbrl_facts", tables: [table], facts: [unresolvableFact])

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

        let (snapshot, source, _) = await SegmentBusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: 1_000_000_000, client: client
        )

        #expect(source == .segmentInfoLLM)
        #expect(snapshot?.axis == "business")
        #expect(await client.timesCalled() == 1)
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

        let (snapshot, source, audit) = await SegmentBusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .segmentInfoLLM)
        #expect(snapshot?.axis == "business")
        #expect(!(snapshot?.needsReview ?? true))
        #expect(audit?.profitDisclosed == true)
        #expect(await client.timesCalled() == 1)
    }

    /// swap 対象の収益認識関係注記が見つからず `SegmentExtractor` 側のフォールバックで
    /// 元の地域別 xbrl_facts がそのまま返ってきたケース（今回の和解の核心セマンティクス）。
    /// axis が geography のままの xbrl_facts は business としては採用せず not_found にする。
    /// 合成 fact（実データ golden には該当書類が無いため）で決定的に検証する。
    @Test func geographyAxisFallbackWithoutSwapIsNotFound() async throws {
        let segments = SegmentResult(
            method: "xbrl_facts",
            tables: [],
            facts: [
                SegmentFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_JapanReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "JapanReportableSegmentsMember"],
                    value: 600_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
                SegmentFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_OverseasReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "OverseasReportableSegmentsMember"],
                    value: 400_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
            ]
        )
        let client = MockChatCompleting(responseJSON: nil)

        let (snapshot, source, audit) = await SegmentBusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: 1_000_000_000_000, client: client
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
        #expect(audit == nil)
        #expect(await client.timesCalled() == 0)
    }

    /// segments が not_found の場合は何も呼ばない。
    @Test func segmentsNotFoundReturnsNotFound() async throws {
        let segments = SegmentResult(method: "not_found", tables: [], facts: [])
        let client = MockChatCompleting(responseJSON: nil)

        let (snapshot, source, _) = await SegmentBusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: 1_000_000, client: client
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
        #expect(await client.timesCalled() == 0)
    }
}
