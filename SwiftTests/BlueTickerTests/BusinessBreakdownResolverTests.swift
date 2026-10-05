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

    private static func extracted(docID: String, key: String = "segments") throws -> ExtractedBreakdown {
        let golden = try loadGolden()
        let entry = try #require(golden[docID])
        let dict = try #require(entry[key] as? [String: Any])
        return ExtractedBreakdown(dictionary: dict)
    }

    private static func segmentsResult(docID: String) throws -> ExtractedBreakdown {
        try extracted(docID: docID, key: "segments")
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

    /// オークマ最新 S100YFQC: 収益認識の品目表が前期（table 0, 206,822）と当期
    /// （table 1, 235,888）に分かれ、行は NC旋盤 / マシニングセンタ 等 5 つ＋構成比。
    /// 地理行は無い。当期表を選んで公開する。
    @Test func okumaSwappedSegmentsResolveViaRevenueRecognitionLLM() async throws {
        let segments = try Self.extracted(docID: "S100YFQC", key: "revenue_recognition")
        #expect(segments.method == "html_table")
        #expect(segments.tables.count == 2)
        #expect(segments.tables[0].period == "前期")
        #expect(segments.tables[1].period == "当期")
        #expect(segments.tables.first?.heading == "収益認識関係")
        let parsed = RevenueRecognitionCandidates.parse(tables: segments.tables)
        #expect(parsed.count == 2)
        let priorAxis = RevenueRecognitionTableStructure.tableAxis(of: parsed[0])
        let currentAxis = RevenueRecognitionTableStructure.tableAxis(of: parsed[1])
        let priorNotGeoOrCustomer = priorAxis != .geography && priorAxis != .customer
        let currentNotGeoOrCustomer = currentAxis != .geography && currentAxis != .customer
        #expect(priorNotGeoOrCustomer)
        #expect(currentNotGeoOrCustomer)
        let priorTotal = RevenueRecognitionCandidates.tableTotal(table: parsed[0], column: 1)
        let currentTotal = RevenueRecognitionCandidates.tableTotal(table: parsed[1], column: 1)
        #expect(priorTotal?.amount == 206_822)
        #expect(currentTotal?.amount == 235_888)
        #expect(segments.tables[0].unitCaption == "百万円")
        #expect(segments.tables[1].unitCaption == "百万円")
        let sales: Double = 235_888 * Financial.millionYen
        let client = MockChatCompleting(responseJSON: nil)
        let decider = FakeRevenueRecognitionColumnDecider()

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client, columnDecider: decider,
            fiscalYearEnd: "2026-03-31", docID: "S100YFQC"
        )

        let needsReview: Bool = snapshot?.needsReview ?? true
        let denominator: Double = snapshot?.denominator ?? 0
        let expectedDenom: Double = 235_888 * Financial.millionYen
        let sourceTable: Int? = audit?.sourceTableIndex
        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == "business")
        #expect(needsReview == false)
        #expect(denominator == expectedDenom)
        #expect(sourceTable == 1)
        let selected = try #require(parsed.first { $0.tableIndex == sourceTable })
        let selectedTotal = RevenueRecognitionCandidates.tableTotal(table: selected, column: 1)
        #expect(selectedTotal?.amount == 235_888)
        #expect(audit?.jev?.model == "typesafe/jev-1.13")
        #expect(await client.timesCalled() == 0)
        let labels = Set(snapshot?.rows.map(\.categoryGroup) ?? [])
        #expect(labels.contains("ＮＣ旋盤"))
        #expect(labels.contains("マシニングセンタ"))
    }

    /// 列選択の confidence が閾値未満でも snapshot は採用する（needs_review）。
    /// 捨てると単一セグメント開示（F）へ落ち、東京エレクトロン型の製品別が取れない。
    @Test func revenueRecognitionLLMResultWithNeedsReviewIsStillAdopted() async throws {
        let segments = try Self.segmentsResult(docID: "S100W043")
        #expect(segments.tables.first?.heading == "収益認識関係")
        let sales = try #require(try Self.loadSales(code: "6103"))
        let client = MockChatCompleting(responseJSON: nil)
        let decider = FakeRevenueRecognitionColumnDecider(confidence: 0.49)

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client, columnDecider: decider
        )

        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.needsReview == true)
        #expect(snapshot?.warnings.contains(RevenueRecognitionColumnNormalizer.warningLowConfidence) == true)
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
            markdown: """
            | 区分 | 当期 |
            | 事業A | 600 |
            | 事業B | 400 |
            | 合計 | 1,000 |
            """,
            period: "当期",
            unitCaption: "百万円"
        )
        let segments = ExtractedBreakdown(method: "xbrl_facts", tables: [table], facts: [unresolvableFact])
        let client = MockChatCompleting(responseJSON: nil)
        let decider = FakeRevenueRecognitionColumnDecider()

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: 1_000 * Financial.millionYen, client: client,
            columnDecider: decider
        )

        #expect(source == .segmentInfoLLM)
        #expect(snapshot?.axis == "business")
        #expect(await client.timesCalled() == 0)
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
        let client = MockChatCompleting(responseJSON: nil)
        let decider = FakeRevenueRecognitionColumnDecider()

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client, columnDecider: decider
        )

        #expect(source == .segmentInfoLLM)
        #expect(snapshot?.axis == "business")
        #expect(!(snapshot?.needsReview ?? true))
        #expect(audit?.profitDisclosed == true)
        #expect(audit?.columnJev?.model == "typesafe/jev-1.13")
        let labels = Set(snapshot?.rows.map(\.labelRaw) ?? [])
        #expect(labels.contains("プリンティング"))
        #expect(labels.contains("メディカル"))
        #expect(await client.timesCalled() == 0)
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
        let client = MockChatCompleting(responseJSON: nil)
        let decider = FakeRevenueRecognitionColumnDecider()

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: 453_294_000_000, client: client,
            columnDecider: decider
        )

        #expect(source == .segmentInfoLLM)
        #expect(snapshot?.axis == "business")
        let labels = Set(snapshot?.rows.map(\.labelRaw) ?? [])
        #expect(labels.contains("ラツーダ"))
        #expect(await client.timesCalled() == 0)
    }

    /// 地域別のみのセグメント情報表は business に載せない。audit の geography_only を持ち帰る。
    @Test func geographyOnlySegmentInfoTableIsNotApplicable() async throws {
        let segments = ExtractedBreakdown(
            method: "html_table",
            tables: [
                BreakdownTable(
                    heading: "セグメント情報",
                    markdown: """
                    | 区分 | 当期 |
                    | 日本 | 600 |
                    | 米国 | 400 |
                    | 合計 | 1,000 |
                    """,
                    period: "当期",
                    unitCaption: "百万円")
            ],
            facts: []
        )
        let client = MockChatCompleting(responseJSON: nil)
        let decider = FakeRevenueRecognitionColumnDecider()

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: 1_000 * Financial.millionYen, client: client,
            columnDecider: decider
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
        #expect(audit?.notApplicableReason == breakdownNotApplicableGeographyOnly)
        #expect(await client.timesCalled() == 0)
    }

    /// Jev が none_of_these のとき snapshot は無く、列選択の audit は持ち帰る。
    @Test func revenueRecognitionLLMPropagatesAuditWithGeographyOnlyReasonWhenNotApplicable() async throws {
        let segments = try Self.segmentsResult(docID: "S100W043")
        #expect(segments.tables.first?.heading == "収益認識関係")
        let sales = try #require(try Self.loadSales(code: "6103"))
        let client = MockChatCompleting(responseJSON: nil)
        let decider = FakeRevenueRecognitionColumnDecider(
            selected: RevenueRecognitionColumnNormalizer.noneOfThese, confidence: 0.95,
            pNone: 0.9)

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client, columnDecider: decider
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
        #expect(audit?.jev?.calls.first?.selected == RevenueRecognitionColumnNormalizer.noneOfThese)
    }

    /// 列選択が needs_review でも採用する。not_applicable_reason は無い。
    @Test func adoptedNeedsReviewResultDoesNotLeakStrayNotApplicableReasonIntoAudit() async throws {
        let segments = try Self.segmentsResult(docID: "S100W043")
        #expect(segments.tables.first?.heading == "収益認識関係")
        let sales = try #require(try Self.loadSales(code: "6103"))
        let client = MockChatCompleting(responseJSON: nil)
        let decider = FakeRevenueRecognitionColumnDecider(confidence: 0.49)

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client, columnDecider: decider
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
