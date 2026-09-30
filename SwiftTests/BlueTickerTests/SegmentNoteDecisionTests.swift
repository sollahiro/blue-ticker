// セグメント注記の Jev 判定。既定はフィクスチャのみで、ネットワークは使わない。
// ライブ呼び出しは OPENROUTER_DECISION_API_KEY が無いとクライアント自体を作らない。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct SegmentNoteDecisionTests {
    private let singleSegment = "当社グループは、コミュニケーション・プラットフォーム関連事業の単一セグメントであるため、記載を省略しております。"
    private let productNinety = "単一の製品・サービスの区分の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。"
    private let domesticNinety = "本邦の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。"
    private let domesticComprehensive = "本邦の外部顧客への売上高が連結損益及び包括利益計算書の売上高の90％を超えるため、記載を省略しております。"
    private let duplicateDisclosure = "セグメント情報に同様の情報を開示しているため、記載を省略しています。"

    @Test func endpointRequiresOpenRouterAPIKey() {
        #expect(openRouterDecisionsAPIKeyEnv == "OPENROUTER_DECISION_API_KEY")
        #expect(resolveOpenRouterDecisionsEndpoint([:]) == nil)
        #expect(resolveOpenRouterDecisionsEndpoint([openRouterDecisionsAPIKeyEnv: "  "]) == nil)
        #expect(resolveOpenRouterDecisionsEndpoint(["OPENROUTER_API_KEY": "generic-key"]) == nil)
        #expect(resolveOpenRouterDecisionsEndpoint(["OPENROUTER_OVERVIEW_API_KEY": "overview-key"]) == nil)
        let endpoint = resolveOpenRouterDecisionsEndpoint([openRouterDecisionsAPIKeyEnv: "decisions-key"])
        #expect(endpoint?.apiKey == "decisions-key")
        #expect(endpoint?.model == "typesafe/jev-1.13")
        #expect(endpoint?.url == "https://openrouter.ai/api/alpha/decisions")
    }

    @Test func parsesChoiceNoulAndScore() throws {
        let json = """
        {
          "answers": {
            "breakdown_table": {
              "type": "choice",
              "choice": "none_of_these",
              "confidence": 0.8,
              "probabilities": { "0": 0.1, "none_of_these": 0.9 }
            },
            "is_omission": { "type": "noul", "noul": 0.96 },
            "urgency": {
              "type": "score",
              "score": 1.99,
              "confidence": 0.99,
              "probabilities": { "0": 0, "1": 0.01, "2": 0.99 }
            }
          },
          "model": "typesafe/jev-1.13",
          "usage": { "input_tokens": 12, "output_tokens": 4 }
        }
        """.data(using: .utf8)!
        let answers = OpenRouterDecisionsCodec.answers(from: json)
        let choice = try #require(answers["breakdown_table"]?.choice)
        #expect(choice.selected == "none_of_these")
        #expect(choice.probabilities["none_of_these"] == 0.9)
        #expect(choice.confidence == 0.8)
        guard case .noul(let yes) = answers["is_omission"]?.kind else {
            Issue.record("noul")
            return
        }
        #expect(yes == 0.96)
        guard case .score(let score, let probabilities, let confidence) = answers["urgency"]?.kind else {
            Issue.record("score")
            return
        }
        #expect(score == 1.99)
        #expect(probabilities["2"] == 0.99)
        #expect(confidence == 0.99)
    }

    @Test func extractsListedOmissionSentencesIncludingComprehensiveIncome() {
        let prose = """
        前置きです。\(singleSegment)補足。\(productNinety)
        \(domesticNinety)\(domesticComprehensive)
        """
        let sentences = BreakdownExtractor.omissionSentences(in: prose)
        #expect(sentences == [singleSegment, productNinety, domesticNinety, domesticComprehensive])
    }

    @Test func ignoresDuplicateDisclosureAndLongUnrelatedText() {
        let sentences = BreakdownExtractor.omissionSentences(
            in: "売上高は増加しました。\(duplicateDisclosure)")
        #expect(sentences == [duplicateDisclosure])
        let withoutMarker = BreakdownExtractor.omissionSentences(in: "記載はありません。")
        #expect(withoutMarker.isEmpty)
    }

    @Test func softfrontProseIsSingleSegmentAndRelatedTableIsNotDropped() throws {
        let html = """
        &lt;p&gt;当社グループは、ソフトフロントジャパン事業の単一セグメントであるため、記載を省略しております。&lt;/p&gt;
        &lt;p&gt;関連情報&lt;/p&gt;
        &lt;table&gt;&lt;tr&gt;&lt;td&gt;主要な顧客&lt;/td&gt;&lt;td&gt;売上高&lt;/td&gt;&lt;/tr&gt;
        &lt;tr&gt;&lt;td&gt;A社&lt;/td&gt;&lt;td&gt;100&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;
        &lt;p&gt;\(domesticNinety)&lt;/p&gt;
        """
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment contextRef="CurrentYearDuration">当社グループは、ソフトフロントジャパン事業の単一セグメントであるため、記載を省略しております。</jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment>
            <jpcrp_cor:SegmentInformationTextBlock contextRef="CurrentYearDuration">\(html)</jpcrp_cor:SegmentInformationTextBlock>
            """)
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let sentences = BreakdownExtractor.segmentNoteOmissionSentences(xbrlDir: dir)
            #expect(sentences.contains("当社グループは、ソフトフロントジャパン事業の単一セグメントであるため、記載を省略しております。"))
            #expect(sentences.contains(domesticNinety))
            let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(!segments.tables.isEmpty)
            let reason = BreakdownExtractor.classifyNotApplicableReason(
                segments: segments, consolidatedSales: 1_000_000, xbrlDir: dir)
            #expect(reason == .unknown)
        }
    }

    @Test func taiheiCurrentYearIsDomesticOmissionAndStoredTableIsPrior() throws {
        let priorTable = """
        &lt;table&gt;&lt;tr&gt;&lt;td&gt;日本&lt;/td&gt;&lt;td&gt;112974&lt;/td&gt;&lt;/tr&gt;
        &lt;tr&gt;&lt;td&gt;アジア&lt;/td&gt;&lt;td&gt;12799&lt;/td&gt;&lt;/tr&gt;
        &lt;tr&gt;&lt;td&gt;合計&lt;/td&gt;&lt;td&gt;125774&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;
        """
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jpcrp_cor:RevenuesFromExternalCustomersInformationForEachRegionTextBlock contextRef="Prior1YearDuration">\(priorTable)</jpcrp_cor:RevenuesFromExternalCustomersInformationForEachRegionTextBlock>
            <jpcrp_cor:RevenuesFromExternalCustomersInformationForEachRegionTextBlock contextRef="CurrentYearDuration">\(domesticComprehensive)</jpcrp_cor:RevenuesFromExternalCustomersInformationForEachRegionTextBlock>
            """)
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let sentences = BreakdownExtractor.segmentNoteOmissionSentences(xbrlDir: dir)
            #expect(sentences == [domesticComprehensive])
            let geography = BreakdownExtractor.extractGeographyInfo(xbrlDir: dir)
            #expect(geography.tables.count == 1)
            #expect(geography.tables[0].period == "前期")
            #expect(geography.tables[0].markdown.contains("112974"))
        }
    }

    @Test func noneOfThesePlusSingleSegmentOmitsBusiness() async {
        let decider = FakeSegmentNoteDecider(
            selection: .noneOfThese,
            omissionsBySnippet: ["単一セグメント": .singleSegment, "本邦": .domesticExternalSalesOver90])
        let tables = [relatedCustomerTable()]
        let business = await SegmentNoteDecision.decide(
            axis: .business, tables: tables,
            sentences: [
                "当社グループは、ソフトフロントジャパン事業の単一セグメントであるため、記載を省略しております。",
                domesticNinety,
            ],
            hasCleanDeterministicSnapshot: false, decider: decider)
        #expect(business == .omitBusiness)
        let geography = await SegmentNoteDecision.decide(
            axis: .geography, tables: tables, sentences: [domesticComprehensive],
            hasCleanDeterministicSnapshot: false, decider: decider)
        #expect(geography == .omitGeography)
        #expect(await decider.tableCalls == 2)
    }

    @Test func productNinetyOmitsBusinessAndDuplicateDisclosureDoesNot() async {
        let product = FakeSegmentNoteDecider(
            selection: .noneOfThese,
            omissionsBySnippet: ["製品": .productOrServiceExternalSalesOver90])
        let omitted = await SegmentNoteDecision.decide(
            axis: .business, tables: [relatedCustomerTable()], sentences: [productNinety],
            hasCleanDeterministicSnapshot: false, decider: product)
        #expect(omitted == .omitBusiness)

        let duplicate = FakeSegmentNoteDecider(
            selection: .noneOfThese, omissionsBySnippet: ["同様の情報": .none])
        let kept = await SegmentNoteDecision.decide(
            axis: .business, tables: [relatedCustomerTable()], sentences: [duplicateDisclosure],
            hasCleanDeterministicSnapshot: false, decider: duplicate)
        #expect(kept == .unchanged)
    }

    @Test func chosenTableIsKeptAndCleanSnapshotSkipsJev() async {
        let decider = FakeSegmentNoteDecider(selection: .table(0), omissionsBySnippet: [:])
        let kept = await SegmentNoteDecision.decide(
            axis: .business, tables: [relatedCustomerTable()], sentences: [singleSegment],
            hasCleanDeterministicSnapshot: false, decider: decider)
        #expect(kept == .keepTable(0))

        let skipped = await SegmentNoteDecision.decide(
            axis: .business, tables: [relatedCustomerTable()], sentences: [singleSegment],
            hasCleanDeterministicSnapshot: true, decider: decider)
        #expect(skipped == .unchanged)
        #expect(await decider.tableCalls == 1)
    }

    @Test func missingKeyPathDoesNotCallWhenSentencesOrTablesAreEmpty() async {
        let decider = FakeSegmentNoteDecider(selection: .noneOfThese, omissionsBySnippet: [:])
        let noSentences = await SegmentNoteDecision.decide(
            axis: .business, tables: [relatedCustomerTable()], sentences: [],
            hasCleanDeterministicSnapshot: false, decider: decider)
        let noTables = await SegmentNoteDecision.decide(
            axis: .geography, tables: [], sentences: [domesticComprehensive],
            hasCleanDeterministicSnapshot: false, decider: decider)
        #expect(noSentences == .unchanged)
        #expect(noTables == .unchanged)
        #expect(await decider.tableCalls == 0)
    }

    @Test func requestUsesChoiceAndFailureFallsBack() async throws {
        let failure = OpenRouterSegmentNoteDecider(client: ThrowingDecisionsClient())
        let unavailable = await failure.selectBreakdownTable(
            tables: [SegmentNoteTableCandidate(index: 0, heading: "関連情報", period: "当期", markdown: "| 主要な顧客 |")],
            sentences: [singleSegment])
        #expect(unavailable == .unavailable)
        let action = await SegmentNoteDecision.decide(
            axis: .business, tables: [relatedCustomerTable()], sentences: [singleSegment],
            hasCleanDeterministicSnapshot: false, decider: failure)
        #expect(action == .unchanged)

        let noneBody = choiceBody(question: "breakdown_table", selected: "none_of_these")
        let omissionBody = choiceBody(
            question: "omission", selected: "domestic_external_sales_over_90")
        let script = ScriptedDecisionsClient(responses: [noneBody, omissionBody])
        let decider = OpenRouterSegmentNoteDecider(client: script)
        let selection = await decider.selectBreakdownTable(
            tables: [SegmentNoteTableCandidate(
                index: 0, heading: "地域ごとの情報", period: "前期", markdown: "| 日本 | 112974 |")],
            sentences: [domesticComprehensive])
        #expect(selection == .noneOfThese)
        let omission = await decider.classifyOmission(sentence: domesticComprehensive)
        #expect(omission == .domesticExternalSalesOver90)

        let requests = await script.recordedRequests()
        let tableRequest = try #require(jsonObject(requests[0]))
        #expect(tableRequest["model"] as? String == "typesafe/jev-1.13")
        let questions = try #require(tableRequest["questions"] as? [String: Any])
        let tableQuestion = try #require(questions["breakdown_table"] as? [String: Any])
        #expect(tableQuestion["type"] as? String == "choice")
        let criteria = try #require(tableQuestion["criteria"] as? [String: String])
        #expect(criteria["none_of_these"]?.contains("関連情報") == true)
        #expect(criteria["0"]?.contains("前期") == true)

        let omissionRequest = try #require(jsonObject(requests[1]))
        let omissionQuestions = try #require(omissionRequest["questions"] as? [String: Any])
        let omissionQuestion = try #require(omissionQuestions["omission"] as? [String: Any])
        #expect(omissionQuestion["type"] as? String == "choice")
        let omissionCriteria = try #require(omissionQuestion["criteria"] as? [String: String])
        #expect(omissionCriteria["single_segment"]?.contains("単一セグメント") == true)
        #expect(omissionCriteria["product_or_service_external_sales_over_90"]?.contains("90％") == true)
        #expect(omissionCriteria["domestic_external_sales_over_90"]?.contains("連結損益及び包括利益計算書") == true)
        #expect(omissionCriteria["none"]?.contains("同様の情報") == true)
        let state = try #require(omissionRequest["state"] as? [String: Any])
        #expect(state["sentence"] as? String == domesticComprehensive)
    }

    private func relatedCustomerTable() -> BreakdownTable {
        BreakdownTable(heading: "セグメント情報", markdown: "| 主要な顧客 | 売上高 |\n| A社 | 100 |", period: "当期")
    }

    private func choiceBody(question: String, selected: String) -> Data {
        let json = """
        {"answers":{"\(question)":{"type":"choice","choice":"\(selected)","confidence":0.9,"probabilities":{"\(selected)":0.9}}},"model":"typesafe/jev-1.13","usage":{"input_tokens":1,"output_tokens":1}}
        """
        return Data(json.utf8)
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private actor FakeSegmentNoteDecider: SegmentNoteDeciding {
    private(set) var tableCalls = 0
    let selection: SegmentNoteTableSelection
    let omissionsBySnippet: [String: SegmentNoteOmission]

    init(selection: SegmentNoteTableSelection, omissionsBySnippet: [String: SegmentNoteOmission]) {
        self.selection = selection
        self.omissionsBySnippet = omissionsBySnippet
    }

    func selectBreakdownTable(
        tables: [SegmentNoteTableCandidate], sentences: [String]
    ) async -> SegmentNoteTableSelection {
        tableCalls += 1
        return selection
    }

    func classifyOmission(sentence: String) async -> SegmentNoteOmission {
        for (snippet, omission) in omissionsBySnippet where sentence.contains(snippet) {
            return omission
        }
        return .none
    }
}

private struct ThrowingDecisionsClient: DecisionsCompleting {
    func decide(requestJSON: Data) async throws -> Data {
        throw ChatCompletionError.invalidURL
    }
}

private actor ScriptedDecisionsClient: DecisionsCompleting {
    private var responses: [Data]
    private var requests: [Data] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func decide(requestJSON: Data) async throws -> Data {
        requests.append(requestJSON)
        guard !responses.isEmpty else { throw ChatCompletionError.emptyContent }
        return responses.removeFirst()
    }

    func recordedRequests() -> [Data] { requests }
}
