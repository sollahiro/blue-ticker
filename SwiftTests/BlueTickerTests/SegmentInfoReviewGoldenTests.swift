// SPEC_ORACLE: 空行 NR・専用タグ+製品表・真の単一セグメント・keepTable 取り違え。
// 1 専用タグ + 製品・サービス別表 → 製品表を組む（475A S100YJX2）
// 2 真の単一セグメント（顧客表だけ）→ single_segment_disclosed のまま
// 3 空行 LLM は保存せず xbrl_facts へフォールバック（7273）
// 4 keepTable が組立不能な表でも製品/地域表を残す（3600 / 4324）
// ネットワークなし。cache_version は breakdown-business-v15 のまま。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct SegmentInfoReviewGoldenTests {
    private let tagText = "当社グループは単一セグメントであるため、記載を省略しております。"

    @Test func singleSegmentTagWithProductTableAssemblesProductRows() async throws {
        let product = productServiceTable()
        let (snapshotOrNil, _) = await SegmentInfoLLMNormalizer.normalize(
            ExtractedBreakdown(method: "html_table", tables: [product], facts: []),
            consolidatedSales: 3_842 * Financial.millionYen,
            decider: FakeRevenueRecognitionColumnDecider(),
            fiscalYearEnd: "2026-03-31",
            docID: "S100YJX2")
        let snapshot = try #require(snapshotOrNil)
        let labels: Set<String> = Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw))
        #expect(labels.contains("メディア事業"))
        #expect(labels.contains("プラットフォーム事業"))
        #expect(!snapshot.needsReview)
        #expect(BusinessBreakdownResolver.hasUsableSegmentRows(snapshot))

        let xml = dedicatedTagXml()
        try await XBRLTestSupport.withXbrlDir(xml) { dir in
            let extracted = ExtractedBreakdown(
                method: "html_table", tables: [product], facts: [])
            let decider = FakeSegmentNoteDeciderForReview(selection: .table(0))
            let gate = await noteContext(decider: decider).segmentsAfterNoteDecision(
                axis: .business, docID: "S100YJX2", extracted: extracted, xbrlDir: dir,
                consolidatedSales: 3_842 * Financial.millionYen, labelsByTag: [:])
            #expect(gate.extracted != nil)
            #expect(gate.outcome.omissionReason == nil)
            #expect(gate.extracted?.tables.contains {
                $0.heading == BreakdownExtractor.productOrServiceHeading
            } == true)
        }
    }

    @Test func trueSingleSegmentStaysNotApplicable() async throws {
        let xml = dedicatedTagXml()
        try await XBRLTestSupport.withXbrlDir(xml) { dir in
            let extracted = ExtractedBreakdown(
                method: "html_table",
                tables: [
                    BreakdownTable(
                        heading: "セグメント情報",
                        markdown: "| 主要な顧客 | 売上高 |\n| A社 | 100 |",
                        period: "当期")
                ],
                facts: [])
            let decider = FakeSegmentNoteDeciderForReview(selection: .noneOfThese)
            let gate = await noteContext(decider: decider).segmentsAfterNoteDecision(
                axis: .business, docID: "S-ss", extracted: extracted, xbrlDir: dir,
                consolidatedSales: 100, labelsByTag: [:])
            #expect(gate.extracted == nil)
            #expect(gate.outcome.omissionReason == breakdownNotApplicableSingleSegmentDisclosed)
            #expect(
                gate.outcome.audit?.decisionSource == SegmentNoteDecision.dedicatedTagDecisionSource)
        }
    }

    @Test func emptyBuiltRowsRefuseSnapshotAndFallBackToFacts() async throws {
        let emptyMatrix = BreakdownTable(
            heading: "セグメント情報",
            markdown: """
                | | 事業A | 事業B | 連結 |
                | 営業利益 | 10 | 20 | 30 |
                """,
            period: "当期",
            unitCaption: "百万円")
        let (emptySnapshot, audit) = await SegmentInfoLLMNormalizer.normalize(
            ExtractedBreakdown(method: "html_table", tables: [emptyMatrix], facts: []),
            consolidatedSales: 100 * Financial.millionYen,
            decider: FakeRevenueRecognitionColumnDecider(),
            fiscalYearEnd: "2026-03-31",
            docID: "S100YLTN-empty")
        #expect(emptySnapshot == nil)
        #expect(audit != nil)

        let facts = [
            BreakdownFact(
                tag: "RevenuesFromExternalCustomers",
                contextRef: "CurrentYearDuration_AutoPartsMember",
                dimensions: ["OperatingSegmentsAxis": "AutoPartsMember"],
                value: 80 * Financial.millionYen, label: nil, unitRef: "JPY", decimals: "-6"),
            BreakdownFact(
                tag: "RevenuesFromExternalCustomers",
                contextRef: "CurrentYearDuration_OtherMember",
                dimensions: ["OperatingSegmentsAxis": "OtherMember"],
                value: 20 * Financial.millionYen, label: nil, unitRef: "JPY", decimals: "-6"),
        ]
        let extracted = ExtractedBreakdown(
            method: "html_table", tables: [emptyMatrix], facts: facts)
        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: extracted,
            consolidatedSales: 100 * Financial.millionYen,
            client: UnavailableChatClient(),
            segmentInfoDecider: FakeRevenueRecognitionColumnDecider())
        let snap = try #require(snapshot)
        #expect(source == .xbrlFacts)
        #expect(BusinessBreakdownResolver.hasUsableSegmentRows(snap))
        #expect(!snap.rows.isEmpty)
    }

    @Test func keepTableDoesNotIsolateUnbuildableOrNonProductTable() async throws {
        let product = BreakdownTable(
            heading: BreakdownExtractor.productOrServiceHeading,
            markdown: """
                | 区分 | 当連結会計年度 |
                | 広告業 | 800 |
                | 情報サービス業 | 300 |
                | その他の事業 | 143 |
                | 合計 | 1,243 |
                """,
            period: "当期",
            unitCaption: "百万円")
        let geography = BreakdownTable(
            heading: "セグメント情報",
            markdown: """
                | | 国内 | 海外 | 計 |
                | 収益(注)１ | 1,000 | 243 | 1,243 |
                | セグメント利益 | 10 | 5 | 15 |
                """,
            period: "当期",
            unitCaption: "百万円")
        let junk = BreakdownTable(
            heading: "セグメント情報",
            markdown: "| 記載の省略 | 理由 |\n| 単一セグメント | 省略 |",
            period: "当期")
        #expect(
            !SegmentInfoLLMNormalizer.shouldIsolateKeptTable(
                index: 1, tables: [product, geography], fiscalYearEnd: "2026-03-31"))
        #expect(
            !SegmentInfoLLMNormalizer.shouldIsolateKeptTable(
                index: 1, tables: [geography, junk], fiscalYearEnd: "2026-03-31"))
        let reportable = BreakdownTable(
            heading: "セグメント情報",
            markdown: """
                | | 日本 | アジア | 計 |
                | 外部顧客に対する売上高 | 4,334 | 1,141 | 5,475 |
                | セグメント損失 | △193 | △31 | △224 |
                """,
            period: "当期",
            unitCaption: "百万円")
        let relatedGeography = BreakdownTable(
            heading: "セグメント情報",
            markdown: """
                | 日本 | 中国 | アジア(中国除く) | その他の地域 | 合計 |
                | 4,249 | 743 | 442 | 41 | 5,475 |
                """,
            period: "当期",
            unitCaption: "百万円",
            precedingCaption: "単一の製品・サービスの区分の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。")
        #expect(
            !SegmentInfoLLMNormalizer.shouldIsolateKeptTable(
                index: 1, tables: [reportable, relatedGeography], fiscalYearEnd: "2026-03-31"))

        let sales = 1_243 * Financial.millionYen
        let (snapshotOrNil, _) = await SegmentInfoLLMNormalizer.normalize(
            ExtractedBreakdown(method: "html_table", tables: [junk, product, geography], facts: []),
            consolidatedSales: sales,
            decider: FakeRevenueRecognitionColumnDecider(),
            fiscalYearEnd: "2026-03-31",
            docID: "S100QHOJ")
        let snapshot = try #require(snapshotOrNil)
        let labels = snapshot.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw).joined()
        #expect(labels.contains("広告業") || labels.contains("情報サービス"))
        #expect(!labels.contains("国内"))
    }

    @Test func japanAsiaMatrixRecoversWhenSelectedTableIsEmpty() async throws {
        let junk = BreakdownTable(
            heading: "セグメント情報",
            markdown: "| 注記 | 内容 |\n| 省略 | 記載を省略しております |",
            period: "当期")
        let japanAsia = BreakdownTable(
            heading: "セグメント情報",
            markdown: """
                | | 日本 | アジア | 計 |
                | 顧客との契約から生じる収益 | 4,333,990 | 1,140,562 | 5,474,552 |
                | セグメント利益 | 100 | 20 | 120 |
                """,
            period: "当期",
            unitCaption: "千円")
        let sales = 5_474_552_000.0
        let (snapshotOrNil, _) = await SegmentInfoLLMNormalizer.normalize(
            ExtractedBreakdown(method: "html_table", tables: [junk, japanAsia], facts: []),
            consolidatedSales: sales,
            decider: FakeRevenueRecognitionColumnDecider(),
            fiscalYearEnd: "2026-03-31",
            docID: "S100YHMW")
        let snapshot = try #require(snapshotOrNil)
        let labels: Set<String> = Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw))
        #expect(labels.contains("日本"))
        #expect(labels.contains("アジア"))
        #expect(!snapshot.needsReview)
        #expect(!snapshot.warnings.contains(
            SegmentInfoPublishGuards.warningGeographyWhileProductExists))
        #expect(snapshot.warnings.contains(SegmentInfoLLMNormalizer.warningGeographyTaken))
    }

    @Test func reviewRecoversProductTableAtHighConfidence() async {
        let product = productServiceTable()
        let outcome = SegmentNoteDecision.dedicatedTagBusinessOutcome(
            docID: "S-review", tagText: tagText)
        let decider = FakeSegmentNoteDeciderForReview(
            selection: .noneOfThese, reviewSelected: "0", reviewProbability: 0.95)
        let reviewed = await SegmentNoteDecision.review(
            proposal: .singleSegment(reason: SegmentNoteDecision.dedicatedTagDecisionSource),
            docID: "S-review", tables: [product], sentences: [tagText],
            existing: outcome, decider: decider)
        #expect(reviewed.action == .keepTable(0))
        #expect(reviewed.omissionReason == nil)
        #expect(reviewed.audit?.decisionSource == SegmentNoteDecision.reviewDecisionSource)
        #expect(await decider.reviewCalls == 1)
    }

    @Test func reviewKeepsOmissionWhenLowConfidenceOrKeep() async {
        let product = productServiceTable()
        let outcome = SegmentNoteDecision.dedicatedTagBusinessOutcome(
            docID: "S-keep", tagText: tagText)
        let keep = FakeSegmentNoteDeciderForReview(selection: .noneOfThese)
        let kept = await SegmentNoteDecision.review(
            proposal: .singleSegment(reason: SegmentNoteDecision.dedicatedTagDecisionSource),
            docID: "S-keep", tables: [product], sentences: [tagText],
            existing: outcome, decider: keep)
        #expect(kept.action == .omitBusiness)
        #expect(kept.omissionReason == breakdownNotApplicableSingleSegmentDisclosed)

        let weak = FakeSegmentNoteDeciderForReview(
            selection: .noneOfThese, reviewSelected: "0", reviewProbability: 0.5)
        let unchanged = await SegmentNoteDecision.review(
            proposal: .needsReview(reason: "empty_rows"),
            docID: "S-weak", tables: [product], sentences: [tagText],
            existing: outcome, decider: weak)
        #expect(unchanged.action == .omitBusiness)
        #expect(unchanged.audit?.calls.contains {
            $0.question == OpenRouterSegmentNoteDecider.reviewDecisionQuestion && !$0.applied
        } == true)
    }

    @Test func cacheVersionStaysBreakdownBusinessV15() {
        #expect(businessBreakdownCacheVersion == "breakdown-business-v15")
    }

    private func productServiceTable() -> BreakdownTable {
        BreakdownTable(
            heading: BreakdownExtractor.productOrServiceHeading,
            markdown: """
                | 区分 | 当連結会計年度 |
                | メディア事業 | 3,200 |
                | プラットフォーム事業 | 500 |
                | その他 | 142 |
                | 合計 | 3,842 |
                """,
            period: "当期",
            unitCaption: "百万円")
    }

    private func dedicatedTagXml() -> String {
        XBRLTestSupport.makeXbrlDuration(
            """
            <jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment contextRef="CurrentYearDuration">\(tagText)</jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment>
            """)
    }

    private func noteContext(decider: (any SegmentNoteDeciding)?) -> BltServerContext {
        BltServerContext(
            apiKey: "test", cacheDir: URL(fileURLWithPath: NSTemporaryDirectory()),
            businessChatClient: UnavailableChatClient(),
            geographyChatClient: UnavailableChatClient(),
            segmentNoteDecider: decider)
    }
}

private actor FakeSegmentNoteDeciderForReview: SegmentNoteDeciding {
    private(set) var tableCalls = 0
    private(set) var reviewCalls = 0
    let selection: SegmentNoteTableSelection
    let reviewSelected: String
    let reviewProbability: Double?

    init(
        selection: SegmentNoteTableSelection,
        reviewSelected: String = OpenRouterSegmentNoteDecider.reviewKeep,
        reviewProbability: Double? = 1
    ) {
        self.selection = selection
        self.reviewSelected = reviewSelected
        self.reviewProbability = reviewProbability
    }

    func selectBreakdownTable(
        tables: [SegmentNoteTableCandidate], sentences: [String]
    ) async -> SegmentNoteConsultedChoice {
        tableCalls += 1
        return SegmentNoteConsultedChoice(
            question: OpenRouterSegmentNoteDecider.breakdownTableQuestion,
            selected: selection.choiceKey,
            probability: 1,
            options: tables.map { "\($0.index)" } + [OpenRouterSegmentNoteDecider.noneOfThese],
            sentences: sentences)
    }

    func classifyOmission(sentence: String) async -> SegmentNoteConsultedChoice {
        SegmentNoteConsultedChoice(
            question: OpenRouterSegmentNoteDecider.omissionQuestion,
            selected: SegmentNoteOmission.singleSegment.choiceKey,
            probability: 1,
            options: OpenRouterSegmentNoteDecider.omissionOptionKeys,
            sentences: [sentence])
    }

    func reviewDecision(
        proposal: SegmentNoteReviewProposal,
        tables: [SegmentNoteTableCandidate],
        sentences: [String]
    ) async -> SegmentNoteConsultedChoice {
        reviewCalls += 1
        return SegmentNoteConsultedChoice(
            question: OpenRouterSegmentNoteDecider.reviewDecisionQuestion,
            selected: reviewSelected,
            probability: reviewProbability,
            options: tables.map { "\($0.index)" } + [OpenRouterSegmentNoteDecider.reviewKeep],
            sentences: sentences)
    }
}
