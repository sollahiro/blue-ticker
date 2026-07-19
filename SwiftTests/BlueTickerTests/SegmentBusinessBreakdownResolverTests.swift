// SegmentBusinessBreakdownResolver のユニットテスト。
// docs/segment-normalization-concept.md「今後の検討事項3」のオークマ型配線チェックリスト
// (a)(b)(c) を実データ（smoke golden）+ モック LLM で検証する。

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
            segments: segments, revenueRecognition: nil, consolidatedSales: sales, client: client
        )

        #expect(source == .xbrlFacts)
        #expect(snapshot?.axis == "business")
        #expect(audit == nil)
        #expect(await client.timesCalled() == 0)
    }

    /// オークマ（xbrl_facts, axis=geography）+ 収益認識注記なし: (a) business としては採用せず not_found。
    @Test func okumaWithoutRevenueRecognitionFallbackIsNotFound() async throws {
        let segments = try Self.segmentsResult(docID: "S100W043")
        let sales = try #require(try Self.loadSales(code: "6103"))
        let client = MockChatCompleting(responseJSON: nil)

        let (snapshot, source, _) = await SegmentBusinessBreakdownResolver.resolve(
            segments: segments, revenueRecognition: nil, consolidatedSales: sales, client: client
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
        #expect(await client.timesCalled() == 0)
    }

    /// オークマ（xbrl_facts, axis=geography）+ 収益認識注記あり: (b) 収益認識注記から LLM で再抽出する。
    @Test func okumaWithRevenueRecognitionFallsBackToLLM() async throws {
        let segments = try Self.segmentsResult(docID: "S100W043")
        let sales = try #require(try Self.loadSales(code: "6103"))

        let revenueRecognition = SegmentResult(
            method: "html_table",
            tables: [SegmentTable(
                heading: "収益認識関係",
                markdown: "| NC旋盤 | 34,304 |\n| マシニングセンタ | 132,309 |",
                period: "当期"
            )],
            facts: []
        )
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "NC旋盤", "amount": 34_304, "row_kind": "segment"],
                ["label": "マシニングセンタ", "amount": 132_309, "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)

        let (snapshot, source, audit) = await SegmentBusinessBreakdownResolver.resolve(
            segments: segments, revenueRecognition: revenueRecognition, consolidatedSales: sales, client: client
        )

        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == "business")
        #expect(audit != nil)
        #expect(await client.timesCalled() == 1)
    }

    /// キヤノン（segments が html_table。US-GAAP 注23）: LLM 経由で business breakdown を得る。
    @Test func canonHtmlTableSegmentsResolvesViaLLM() async throws {
        let segments = try Self.segmentsResult(docID: "S100XTLJ")
        #expect(segments.method == "html_table")
        let sales = try #require(try Self.loadSales(code: "7751"))

        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "プリンティング", "amount": 2_487_885, "row_kind": "segment"],
                ["label": "メディカル", "amount": 579_723, "row_kind": "segment"],
                ["label": "イメージング", "amount": 1_054_513, "row_kind": "segment"],
                ["label": "インダストリアル", "amount": 357_924, "row_kind": "segment"],
                ["label": "その他及び全社", "amount": 144_682, "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)

        let (snapshot, source, audit) = await SegmentBusinessBreakdownResolver.resolve(
            segments: segments, revenueRecognition: nil, consolidatedSales: sales, client: client
        )

        #expect(source == .htmlTableLLM)
        #expect(snapshot?.axis == "business")
        #expect(audit != nil)
        #expect(await client.timesCalled() == 1)
    }

    /// segments が not_found（xbrl_facts も html_table も無い）の場合は revenueRecognition が
    /// あっても触らない（この分岐に来るのは segments 自体に事業別セグメント情報が無いケースで、
    /// オークマ型の axis=geography フォールバックとは別物のため）。
    @Test func segmentsNotFoundWithoutHtmlTableReturnsNotFound() async throws {
        let segments = SegmentResult(method: "not_found", tables: [], facts: [])
        let revenueRecognition = SegmentResult(
            method: "html_table",
            tables: [SegmentTable(heading: "収益認識関係", markdown: "| 製品A | 100 |", period: "当期")],
            facts: []
        )
        let client = MockChatCompleting(responseJSON: nil)

        let (snapshot, source, _) = await SegmentBusinessBreakdownResolver.resolve(
            segments: segments, revenueRecognition: revenueRecognition, consolidatedSales: 1_000_000, client: client
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
        #expect(await client.timesCalled() == 0)
    }

    /// オークマ型 + 収益認識注記あり だが LLM が非該当（applicable=false）と判定した場合、
    /// geography snapshot を business としてすり抜けさせず not_found のまま返す（チェックリスト(a)の保証）。
    @Test func okumaWithRevenueRecognitionNotApplicableReturnsNotFound() async throws {
        let segments = try Self.segmentsResult(docID: "S100W043")
        let sales = try #require(try Self.loadSales(code: "6103"))
        let revenueRecognition = SegmentResult(
            method: "html_table",
            tables: [SegmentTable(heading: "収益認識関係", markdown: "| 無関係な表 |", period: "当期")],
            facts: []
        )
        let response: [String: Any] = [
            "applicable": false,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [] as [[String: Any]],
            "notes": "該当なし",
        ]
        let client = MockChatCompleting(responseJSON: response)

        let (snapshot, source, audit) = await SegmentBusinessBreakdownResolver.resolve(
            segments: segments, revenueRecognition: revenueRecognition, consolidatedSales: sales, client: client
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
        #expect(audit?.notes == "該当なし")
        #expect(await client.timesCalled() == 1)
    }
}
