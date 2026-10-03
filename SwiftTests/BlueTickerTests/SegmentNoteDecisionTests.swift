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
            ],
            hasCleanDeterministicSnapshot: false, decider: decider)
        #expect(business.action == .omitBusiness)
        #expect(business.needsReview == false)
        let geography = await SegmentNoteDecision.decide(
            axis: .geography, tables: tables, sentences: [domesticComprehensive],
            hasCleanDeterministicSnapshot: false, decider: decider)
        #expect(geography.action == .omitGeography)
        #expect(await decider.tableCalls == 2)
    }

    @Test func productNinetyOmitsBusinessAndDuplicateDisclosureDoesNot() async {
        let product = FakeSegmentNoteDecider(
            selection: .noneOfThese,
            omissionsBySnippet: ["製品": .productOrServiceExternalSalesOver90])
        let omitted = await SegmentNoteDecision.decide(
            axis: .business, tables: [relatedCustomerTable()], sentences: [productNinety],
            hasCleanDeterministicSnapshot: false, decider: product)
        #expect(omitted.action == .omitBusiness)

        let duplicate = FakeSegmentNoteDecider(
            selection: .noneOfThese, omissionsBySnippet: ["同様の情報": .none])
        let kept = await SegmentNoteDecision.decide(
            axis: .business, tables: [relatedCustomerTable()], sentences: [duplicateDisclosure],
            hasCleanDeterministicSnapshot: false, decider: duplicate)
        #expect(kept.action == .unchanged)
        #expect(kept.needsReview == false)
    }

    @Test func chosenTableIsKeptAndCleanSnapshotSkipsJev() async {
        let decider = FakeSegmentNoteDecider(selection: .table(0), omissionsBySnippet: [:])
        let kept = await SegmentNoteDecision.decide(
            axis: .business, tables: [relatedCustomerTable()], sentences: [singleSegment],
            hasCleanDeterministicSnapshot: false, decider: decider)
        #expect(kept.action == .keepTable(0))

        let skipped = await SegmentNoteDecision.decide(
            axis: .business, tables: [relatedCustomerTable()], sentences: [singleSegment],
            hasCleanDeterministicSnapshot: true, decider: decider)
        #expect(skipped.action == .unchanged)
        #expect(skipped.audit == nil)
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
        #expect(noSentences.action == .unchanged)
        #expect(noTables.action == .unchanged)
        #expect(await decider.tableCalls == 0)
    }

    @Test func requestUsesChoiceAndFailureFallsBack() async throws {
        let failure = OpenRouterSegmentNoteDecider(client: ThrowingDecisionsClient())
        let unavailable = await failure.selectBreakdownTable(
            tables: [SegmentNoteTableCandidate(index: 0, heading: "関連情報", period: "当期", markdown: "| 主要な顧客 |")],
            sentences: [singleSegment])
        #expect(unavailable.selected == nil)
        let action = await SegmentNoteDecision.decide(
            axis: .business, tables: [relatedCustomerTable()], sentences: [singleSegment],
            hasCleanDeterministicSnapshot: false, decider: failure)
        #expect(action.action == .unchanged)
        #expect(action.needsReview == false)
        #expect(action.audit == nil)

        let noneBody = choiceBody(question: "breakdown_table", selected: "none_of_these")
        let omissionBody = choiceBody(
            question: "omission", selected: "domestic_external_sales_over_90")
        let script = ScriptedDecisionsClient(responses: [noneBody, omissionBody])
        let decider = OpenRouterSegmentNoteDecider(client: script)
        let selection = await decider.selectBreakdownTable(
            tables: [SegmentNoteTableCandidate(
                index: 0, heading: "地域ごとの情報", period: "前期", markdown: "| 日本 | 112974 |")],
            sentences: [domesticComprehensive])
        #expect(selection.selected == "none_of_these")
        #expect(selection.probability == 0.9)
        let omission = await decider.classifyOmission(sentence: domesticComprehensive)
        #expect(omission.selected == "domestic_external_sales_over_90")
        #expect(omission.probability == 0.9)

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

    @Test func belowThresholdLeavesDeterministicResultAndNeedsReview() async throws {
        let low = SegmentNoteDecision.applyProbabilityThreshold - 0.01
        let decider = FakeSegmentNoteDecider(
            selection: .noneOfThese, omissionsBySnippet: ["単一セグメント": .singleSegment],
            omissionProbability: low)
        let outcome = await SegmentNoteDecision.decide(
            axis: .business, code: "2321", docID: "S100LS0U",
            tables: [relatedCustomerTable()], sentences: [singleSegment],
            hasCleanDeterministicSnapshot: false, decider: decider)
        #expect(outcome.action == .unchanged)
        #expect(outcome.needsReview == true)
        let audit = try #require(outcome.audit)
        #expect(audit.applied == false)
        #expect(audit.needsReview == true)
        #expect(audit.calls.contains { $0.selected == "single_segment" && $0.probability == low && !$0.applied })
    }

    @Test func missingProbabilityDoesNotApply() async throws {
        let decider = FakeSegmentNoteDecider(
            selection: .noneOfThese, omissionsBySnippet: ["単一セグメント": .singleSegment],
            omissionProbability: nil)
        let outcome = await SegmentNoteDecision.decide(
            axis: .business, docID: "S-missing", tables: [relatedCustomerTable()],
            sentences: [singleSegment], hasCleanDeterministicSnapshot: false, decider: decider)
        #expect(outcome.action == .unchanged)
        #expect(outcome.needsReview == true)
        let sentence = try #require(outcome.audit?.calls.last)
        #expect(sentence.selected == "single_segment")
        #expect(sentence.probability == nil)
        #expect(sentence.applied == false)

        #expect(OpenRouterSegmentNoteDecider.selectedProbability(
            selected: "single_segment", probabilities: [:]) == nil)
        #expect(OpenRouterSegmentNoteDecider.selectedProbability(
            selected: "single_segment", probabilities: ["none": 0.99]) == nil)
        #expect(OpenRouterSegmentNoteDecider.selectedProbability(
            selected: "single_segment", probabilities: ["single_segment": 1.4]) == nil)
    }

    @Test func conflictingSentenceClassesDoNotOmit() async {
        let decider = FakeSegmentNoteDecider(
            selection: .noneOfThese,
            omissionsBySnippet: ["単一セグメント": .singleSegment, "本邦": .domesticExternalSalesOver90])
        let outcome = await SegmentNoteDecision.decide(
            axis: .business, docID: "S-conflict", tables: [relatedCustomerTable()],
            sentences: [singleSegment, domesticNinety],
            hasCleanDeterministicSnapshot: false, decider: decider)
        #expect(outcome.action == .unchanged)
        #expect(outcome.needsReview == true)
        #expect(outcome.audit?.applied == false)
        #expect(outcome.audit?.calls.allSatisfy { !$0.applied } == true)
    }

    @Test func auditRecordsConsultedDecision() async throws {
        let decider = FakeSegmentNoteDecider(
            selection: .noneOfThese, omissionsBySnippet: ["製品": .productOrServiceExternalSalesOver90])
        let outcome = await SegmentNoteDecision.decide(
            axis: .business, code: "2321", docID: "S100LS0U",
            tables: [relatedCustomerTable()], sentences: [productNinety],
            hasCleanDeterministicSnapshot: false, decider: decider)
        let audit = try #require(outcome.audit)
        #expect(audit.code == "2321")
        #expect(audit.docID == "S100LS0U")
        #expect(audit.axis == "business")
        #expect(audit.model == "typesafe/jev-1.13")
        #expect(audit.threshold == SegmentNoteDecision.applyProbabilityThreshold)
        #expect(audit.sentences == [productNinety])
        #expect(audit.applied == true)
        #expect(audit.needsReview == false)
        let table = try #require(audit.calls.first)
        #expect(table.question == "breakdown_table")
        #expect(table.options.contains("none_of_these"))
        #expect(table.options.contains("0"))
        #expect(table.selected == "none_of_these")
        #expect(table.probability == 1)
        #expect(table.applied == true)
        let sentence = try #require(audit.calls.last)
        #expect(sentence.question == "omission")
        #expect(sentence.options == OpenRouterSegmentNoteDecider.omissionOptionKeys)
        #expect(sentence.selected == "product_or_service_external_sales_over_90")
        #expect(sentence.probability == 1)
        #expect(sentence.sentences == [productNinety])
        #expect(sentence.applied == true)

        let stored = LLMBreakdownAuditPayload.segmentNoteJev(audit)
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(LLMBreakdownAuditPayload.self, from: data)
        #expect(decoded.jev == audit)
        let withColumn = LLMBreakdownAuditPayload(
            sourceTableIndex: 0, periodColumn: "t1_c1", unit: "million_yen", profitDisclosed: false,
            notes: "n", jev: audit, columnJev: audit)
        #expect(withColumn.replacingJev(audit).columnJev == audit)
        let legacy = """
        {"sourceTableIndex":0,"periodColumn":"当期","unit":"million_yen","profitDisclosed":false,"notes":"n"}
        """.data(using: .utf8)!
        let old = try JSONDecoder().decode(LLMBreakdownAuditPayload.self, from: legacy)
        #expect(old.jev == nil)
        #expect(old.unit == "million_yen")
        let json = stored.jsonObject()
        let jev = try #require(json["jev"] as? [String: Any])
        #expect(jev["doc_id"] as? String == "S100LS0U")
        #expect(jev["model"] as? String == "typesafe/jev-1.13")
        #expect(jev["applied"] as? Bool == true)
        let bare = LLMBreakdownAuditPayload(
            sourceTableIndex: 0, periodColumn: "当期", unit: "million_yen",
            profitDisclosed: false, notes: "n")
        #expect(bare.jsonObject()["jev"] == nil)
    }

    @Test func productNinetyWithGeographicSegmentsUsesGeographyOnly() async throws {
        let outcome = SegmentNoteDecision.resolveBusinessOmissionReason(
            await productNinetyOmission(),
            reportedSegmentsAreGeographic: true)
        #expect(outcome.action == .omitBusiness)
        #expect(outcome.omissionReason == breakdownNotApplicableGeographyOnly)
        #expect(outcome.needsReview == false)
        #expect(outcome.audit?.applied == true)
        #expect(outcome.audit?.withheldReason == nil)
    }

    @Test func jevSingleSegmentClassUsesSingleSegmentDisclosed() async throws {
        let fromSentence = SegmentNoteDecision.resolveBusinessOmissionReason(
            await singleSegmentOmission(),
            reportedSegmentsAreGeographic: true)
        #expect(fromSentence.action == .omitBusiness)
        #expect(fromSentence.omissionReason == breakdownNotApplicableSingleSegmentDisclosed)
        #expect(fromSentence.audit?.decisionSource == nil)
        #expect(fromSentence.audit?.calls.isEmpty == false)
    }

    @Test func dedicatedTagPublishesSingleSegmentWithoutJev() async throws {
        let tagText = "当社グループは、信用保証事業のみであるため、記載を省略しております。"
        let customer = """
        &lt;p&gt;\(productNinety)&lt;/p&gt;
        &lt;p&gt;関連情報&lt;/p&gt;
        &lt;table&gt;&lt;tr&gt;&lt;td&gt;主要な顧客&lt;/td&gt;&lt;td&gt;売上高&lt;/td&gt;&lt;/tr&gt;
        &lt;tr&gt;&lt;td&gt;A社&lt;/td&gt;&lt;td&gt;100&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;
        &lt;p&gt;\(domesticNinety)&lt;/p&gt;
        """
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment contextRef="CurrentYearDuration">\(tagText)</jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment>
            <jpcrp_cor:SegmentInformationTextBlock contextRef="CurrentYearDuration">\(customer)</jpcrp_cor:SegmentInformationTextBlock>
            """)
        let decider = FakeSegmentNoteDecider(
            selection: .table(0), omissionsBySnippet: ["製品": .productOrServiceExternalSalesOver90],
            tableProbability: 0.5)
        try await XBRLTestSupport.withXbrlDir(xml) { dir in
            let sentences = BreakdownExtractor.segmentNoteOmissionSentences(xbrlDir: dir)
            #expect(sentences.contains(productNinety))
            #expect(sentences.contains(domesticNinety))
            #expect(BreakdownExtractor.dedicatedSingleSegmentDisclosureText(xbrlDir: dir) == tagText)
            let extracted = businessFactsWithCustomerTable()
            let snapshot = try #require(
                BreakdownNormalizer.normalize(extracted, consolidatedSales: 1_000))
            #expect(snapshot.axis == "business")
            #expect(snapshot.needsReview == false)
            let context = noteContext(decider: decider)
            let business = await context.segmentsAfterNoteDecision(
                axis: .business, docID: "S100LS0U", extracted: extracted, xbrlDir: dir,
                consolidatedSales: 1_000, labelsByTag: [:])
            #expect(business.extracted == nil)
            #expect(business.outcome.action == .omitBusiness)
            #expect(business.outcome.needsReview == false)
            #expect(business.outcome.omissionReason == breakdownNotApplicableSingleSegmentDisclosed)
            let audit = try #require(business.outcome.audit)
            #expect(audit.calls.isEmpty)
            #expect(audit.model == "")
            #expect(audit.applied == true)
            #expect(audit.decisionSource == SegmentNoteDecision.dedicatedTagDecisionSource)
            #expect(audit.sentences == [tagText])
            let json = LLMBreakdownAuditPayload.segmentNoteJev(audit).jsonObject()
            let jev = try #require(json["jev"] as? [String: Any])
            #expect(jev["decision_source"] as? String == SegmentNoteDecision.dedicatedTagDecisionSource)
            #expect((jev["calls"] as? [Any])?.isEmpty == true)
            #expect(await decider.tableCalls == 0)

            let withoutKey = await noteContext(decider: nil).segmentsAfterNoteDecision(
                axis: .business, docID: "S100LS0U", extracted: extracted, xbrlDir: dir,
                consolidatedSales: 1_000, labelsByTag: [:])
            #expect(withoutKey.extracted == nil)
            #expect(withoutKey.outcome.omissionReason == breakdownNotApplicableSingleSegmentDisclosed)
            #expect(withoutKey.outcome.needsReview == false)

            let geography = await context.segmentsAfterNoteDecision(
                axis: .geography, docID: "S100LS0U", extracted: extracted, xbrlDir: dir,
                consolidatedSales: 1_000, labelsByTag: [:])
            #expect(geography.outcome.audit?.axis == "geography")
            #expect(geography.outcome.audit?.decisionSource == nil)
            #expect(geography.outcome.omissionReason == nil)
            #expect(await decider.tableCalls == 1)

            let geographyWithoutKey = await noteContext(decider: nil).segmentsAfterNoteDecision(
                axis: .geography, docID: "S100LS0U", extracted: extracted, xbrlDir: dir,
                consolidatedSales: 1_000, labelsByTag: [:])
            #expect(geographyWithoutKey.extracted == extracted)
            #expect(geographyWithoutKey.outcome == .unchanged)
        }
    }

    @Test func ifrsDedicatedTagPublishesSingleSegmentWithoutJev() async throws {
        let tagText = "当社グループは、単一の事業セグメントであるため、記載を省略しております。"
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegmentIFRS contextRef="CurrentYearDuration">\(tagText)</jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegmentIFRS>
            """)
        let decider = FakeSegmentNoteDecider(selection: .noneOfThese, omissionsBySnippet: [:])
        try await XBRLTestSupport.withXbrlDir(xml) { dir in
            let business = await noteContext(decider: decider).segmentsAfterNoteDecision(
                axis: .business, docID: "S-ifrs", extracted: businessFactsWithCustomerTable(),
                xbrlDir: dir, consolidatedSales: 1_000, labelsByTag: [:])
            #expect(business.extracted == nil)
            #expect(business.outcome.omissionReason == breakdownNotApplicableSingleSegmentDisclosed)
            #expect(business.outcome.audit?.decisionSource == SegmentNoteDecision.dedicatedTagDecisionSource)
            #expect(await decider.tableCalls == 0)
        }
    }

    @Test func emptyDedicatedTagDoesNotShortcut() async throws {
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment contextRef="CurrentYearDuration">   </jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment>
            <jpcrp_cor:SegmentInformationTextBlock contextRef="CurrentYearDuration">\(singleSegment)</jpcrp_cor:SegmentInformationTextBlock>
            """)
        let decider = FakeSegmentNoteDecider(
            selection: .noneOfThese, omissionsBySnippet: ["単一セグメント": .singleSegment])
        try await XBRLTestSupport.withXbrlDir(xml) { dir in
            #expect(BreakdownExtractor.dedicatedSingleSegmentDisclosureText(xbrlDir: dir) == nil)
            #expect(BreakdownExtractor.hasDedicatedSingleSegmentDisclosureTag(xbrlDir: dir) == false)
            let business = await noteContext(decider: decider).segmentsAfterNoteDecision(
                axis: .business, docID: "S-empty", extracted: customerTableOnly(),
                xbrlDir: dir, consolidatedSales: 1_000, labelsByTag: [:])
            #expect(business.extracted == nil)
            #expect(business.outcome.omissionReason == breakdownNotApplicableSingleSegmentDisclosed)
            #expect(business.outcome.audit?.decisionSource == nil)
            #expect(await decider.tableCalls == 1)
        }
    }

    @Test func concentrationProseDoesNotBecomeSingleSegmentDisclosed() async throws {
        let prose = "化粧品事業の外部顧客への売上高が連結損益計算書上の売上高のほとんどを占めているため、記載を省略します。"
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jpcrp_cor:InformationForEachProductOrServiceTextBlock contextRef="CurrentYearDuration">\(prose)</jpcrp_cor:InformationForEachProductOrServiceTextBlock>
            """)
        let decider = FakeSegmentNoteDecider(
            selection: .noneOfThese,
            omissionsBySnippet: ["ほとんど": .productOrServiceExternalSalesOver90, "製品": .productOrServiceExternalSalesOver90])
        try await XBRLTestSupport.withXbrlDir(xml) { dir in
            #expect(BreakdownExtractor.detectSingleSegmentDisclosure(xbrlDir: dir) == prose)
            #expect(BreakdownExtractor.dedicatedSingleSegmentDisclosureText(xbrlDir: dir) == nil)
            let business = await noteContext(decider: decider).segmentsAfterNoteDecision(
                axis: .business, docID: "S-prose", extracted: customerTableOnly(),
                xbrlDir: dir, consolidatedSales: 1_000, labelsByTag: [:])
            #expect(business.extracted != nil)
            #expect(business.outcome.action == .unchanged)
            #expect(business.outcome.omissionReason == nil)
            #expect(business.outcome.needsReview == true)
            #expect(await decider.tableCalls == 1)
        }
    }

    @Test func missingKeyWithoutDedicatedTagKeepsDeterministicResult() async throws {
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jpcrp_cor:SegmentInformationTextBlock contextRef="CurrentYearDuration">\(productNinety)</jpcrp_cor:SegmentInformationTextBlock>
            """)
        try await XBRLTestSupport.withXbrlDir(xml) { dir in
            let extracted = customerTableOnly()
            let business = await noteContext(decider: nil).segmentsAfterNoteDecision(
                axis: .business, docID: "S-nokey", extracted: extracted, xbrlDir: dir,
                consolidatedSales: 1_000, labelsByTag: [:])
            #expect(business.extracted == extracted)
            #expect(business.outcome == .unchanged)
            let failure = OpenRouterSegmentNoteDecider(client: ThrowingDecisionsClient())
            let failed = await noteContext(decider: failure).segmentsAfterNoteDecision(
                axis: .business, docID: "S-fail", extracted: extracted, xbrlDir: dir,
                consolidatedSales: 1_000, labelsByTag: [:])
            #expect(failed.extracted == extracted)
            #expect(failed.outcome.action == .unchanged)
            #expect(failed.outcome.needsReview == false)
            #expect(failed.outcome.audit == nil)
        }
    }

    @Test func productNinetyWithoutEvidenceIsNotApplied() async throws {
        let outcome = SegmentNoteDecision.resolveBusinessOmissionReason(
            await productNinetyOmission(),
            reportedSegmentsAreGeographic: false)
        #expect(outcome.action == .unchanged)
        #expect(outcome.needsReview == true)
        #expect(outcome.omissionReason == nil)
        let audit = try #require(outcome.audit)
        #expect(audit.applied == false)
        #expect(audit.needsReview == true)
        #expect(audit.withheldReason == SegmentNoteDecision.withheldProductOmissionReason)
        #expect(audit.calls.allSatisfy { !$0.applied })
        let json = LLMBreakdownAuditPayload.segmentNoteJev(audit).jsonObject()
        let jev = try #require(json["jev"] as? [String: Any])
        #expect(jev["withheld_reason"] as? String == SegmentNoteDecision.withheldProductOmissionReason)
        #expect(jev["applied"] as? Bool == false)
    }

    private func noteContext(decider: (any SegmentNoteDeciding)?) -> BltServerContext {
        BltServerContext(
            apiKey: "test", cacheDir: URL(fileURLWithPath: NSTemporaryDirectory()),
            businessChatClient: UnavailableChatClient(),
            geographyChatClient: UnavailableChatClient(),
            segmentNoteDecider: decider)
    }

    /// 2321 型: セグメント情報の下の主要顧客表と、きれいな事業 member fact。
    private func businessFactsWithCustomerTable() -> ExtractedBreakdown {
        ExtractedBreakdown(
            method: "xbrl_facts",
            tables: [relatedCustomerTable()],
            facts: [
                BreakdownFact(
                    tag: "RevenuesFromExternalCustomers",
                    contextRef: "CurrentYearDuration_CreditGuaranteeBusinessMember",
                    dimensions: ["OperatingSegmentsAxis": "CreditGuaranteeBusinessMember"],
                    value: 1_000, label: nil, unitRef: "JPY", decimals: "0"),
            ])
    }

    private func customerTableOnly() -> ExtractedBreakdown {
        ExtractedBreakdown(method: "html_table", tables: [relatedCustomerTable()], facts: [])
    }

    private func productNinetyOmission() async -> SegmentNoteDecisionOutcome {
        let decider = FakeSegmentNoteDecider(
            selection: .noneOfThese, omissionsBySnippet: ["製品": .productOrServiceExternalSalesOver90])
        return await SegmentNoteDecision.decide(
            axis: .business, docID: "S-product", tables: [relatedCustomerTable()], sentences: [productNinety],
            hasCleanDeterministicSnapshot: false, decider: decider)
    }

    private func singleSegmentOmission() async -> SegmentNoteDecisionOutcome {
        let decider = FakeSegmentNoteDecider(
            selection: .noneOfThese, omissionsBySnippet: ["単一セグメント": .singleSegment])
        return await SegmentNoteDecision.decide(
            axis: .business, docID: "S-single", tables: [relatedCustomerTable()], sentences: [singleSegment],
            hasCleanDeterministicSnapshot: false, decider: decider)
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
    let tableProbability: Double?
    let omissionsBySnippet: [String: SegmentNoteOmission]
    let omissionProbability: Double?

    init(
        selection: SegmentNoteTableSelection, omissionsBySnippet: [String: SegmentNoteOmission],
        tableProbability: Double? = 1, omissionProbability: Double? = 1
    ) {
        self.selection = selection
        self.tableProbability = tableProbability
        self.omissionsBySnippet = omissionsBySnippet
        self.omissionProbability = omissionProbability
    }

    func selectBreakdownTable(
        tables: [SegmentNoteTableCandidate], sentences: [String]
    ) async -> SegmentNoteConsultedChoice {
        tableCalls += 1
        return SegmentNoteConsultedChoice(
            question: OpenRouterSegmentNoteDecider.breakdownTableQuestion,
            selected: selection.choiceKey,
            probability: tableProbability,
            options: tables.map { "\($0.index)" } + [OpenRouterSegmentNoteDecider.noneOfThese],
            sentences: sentences)
    }

    func classifyOmission(sentence: String) async -> SegmentNoteConsultedChoice {
        var omission = SegmentNoteOmission.none
        for (snippet, value) in omissionsBySnippet where sentence.contains(snippet) {
            omission = value
            break
        }
        return SegmentNoteConsultedChoice(
            question: OpenRouterSegmentNoteDecider.omissionQuestion,
            selected: omission.choiceKey,
            probability: omissionProbability,
            options: OpenRouterSegmentNoteDecider.omissionOptionKeys,
            sentences: [sentence])
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
