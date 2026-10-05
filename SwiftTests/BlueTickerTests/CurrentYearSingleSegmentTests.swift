// 当期の報告セグメント売上 member が 2 以上なら専用タグを信じない（7063 / 1711 / 2321）。
// Prior* のタグは当期 member が 1 以下のときだけ省略に使う（9853）。フィクスチャのみ。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct CurrentYearSingleSegmentTests {
    private let tagText = "当社グループは単一セグメントであるため、記載を省略しております。"

    @Test func currentYearTagIsReturnedAndPriorTagIsIgnoredByDisclosureText() throws {
        let xml = operatingSegmentXml(
            tagContextRef: "Prior1YearDuration_NonConsolidatedMember",
            currentMembers: [("MXMember", "2078600000"), ("EXMember", "1289400000")])
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            #expect(BreakdownExtractor.dedicatedSingleSegmentDisclosureText(xbrlDir: dir) == nil)
            let texts = BreakdownExtractor.dedicatedSingleSegmentDisclosureTexts(xbrlDir: dir)
            #expect(texts.currentYear == nil)
            #expect(texts.any == tagText)
            #expect(BreakdownExtractor.hasDedicatedSingleSegmentDisclosureTag(xbrlDir: dir) == false)
        }
    }

    @Test func currentYearNonConsolidatedTagCountsAsCurrentYear() throws {
        let xml = operatingSegmentXml(
            tagContextRef: "CurrentYearDuration_NonConsolidatedMember",
            currentMembers: [])
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            #expect(BreakdownExtractor.dedicatedSingleSegmentDisclosureText(xbrlDir: dir) == tagText)
            #expect(BreakdownExtractor.currentYearReportableOperatingSegmentSalesMemberCount(xbrlDir: dir) == 0)
            #expect(BreakdownExtractor.dedicatedSingleSegmentTagTrustedForOmission(xbrlDir: dir) == tagText)
        }
    }

    @Test func twoCurrentYearReportableSalesMembersRefuseDedicatedTag() throws {
        let xml = operatingSegmentXml(
            tagContextRef: "CurrentYearDuration",
            currentMembers: [("MXMember", "2078600000"), ("EXMember", "1289400000")])
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let members = BreakdownExtractor.currentYearReportableOperatingSegmentSalesMembers(
                xbrlDir: dir)
            #expect(members == ["MXMember", "EXMember"])
            #expect(BreakdownExtractor.dedicatedSingleSegmentDisclosureText(xbrlDir: dir) == tagText)
            #expect(BreakdownExtractor.dedicatedSingleSegmentTagTrustedForOmission(xbrlDir: dir) == nil)
            #expect(
                BreakdownExtractor.dedicatedTagDisagreesWithCurrentYearReportableSegments(xbrlDir: dir))
            let extracted = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(extracted.method == "xbrl_facts")
            let snapshot = try #require(
                BreakdownNormalizer.normalize(extracted, consolidatedSales: 3_368_000_000))
            #expect(snapshot.axis == breakdownAxisProductService)
            let labels = Set(snapshot.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw))
            #expect(labels == ["MXMember", "EXMember"])
            let warned = BreakdownExtractor.applyingDedicatedTagDisagreementWarning(to: snapshot)
            #expect(warned.needsReview)
            #expect(
                warned.warnings.contains(
                    breakdownWarningSingleSegmentTagDisagreesWithCurrentYearReportableSegments))
        }
    }

    @Test func priorOnlyTagWithTwoCurrentMembersDoesNotWarnAndIsNotTrusted() throws {
        let xml = operatingSegmentXml(
            tagContextRef: "Prior1YearDuration",
            currentMembers: [("MXMember", "2078600000"), ("EXMember", "1289400000")])
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            #expect(BreakdownExtractor.dedicatedSingleSegmentDisclosureText(xbrlDir: dir) == nil)
            #expect(BreakdownExtractor.dedicatedSingleSegmentTagTrustedForOmission(xbrlDir: dir) == nil)
            #expect(
                !BreakdownExtractor.dedicatedTagDisagreesWithCurrentYearReportableSegments(xbrlDir: dir))
            #expect(
                BreakdownExtractor.currentYearReportableOperatingSegmentSalesMemberCount(xbrlDir: dir)
                    == 2)
        }
    }

    @Test func priorYearSalesMembersDoNotCountTowardCurrentYear() throws {
        let xml = operatingSegmentXml(
            tagContextRef: "CurrentYearDuration",
            currentMembers: [],
            priorMembers: [("MXMember", "1000000"), ("EXMember", "2000000")])
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            #expect(
                BreakdownExtractor.currentYearReportableOperatingSegmentSalesMemberCount(xbrlDir: dir)
                    == 0)
            #expect(BreakdownExtractor.dedicatedSingleSegmentTagTrustedForOmission(xbrlDir: dir) == tagText)
            #expect(
                !BreakdownExtractor.dedicatedTagDisagreesWithCurrentYearReportableSegments(xbrlDir: dir))
        }
    }

    @Test func reconcilingCorporateAndOtherMembersAreExcluded() throws {
        let xml = operatingSegmentXml(
            tagContextRef: "CurrentYearDuration",
            currentMembers: [
                ("ReconcilingItemsMember", "100"),
                ("CorporateSharedMember", "200"),
                ("OtherOperatingSegmentsAxisMember", "300"),
                ("ReportableSegmentsMember", "400"),
            ])
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            #expect(
                BreakdownExtractor.currentYearReportableOperatingSegmentSalesMemberCount(xbrlDir: dir)
                    == 0)
            #expect(BreakdownExtractor.dedicatedSingleSegmentTagTrustedForOmission(xbrlDir: dir) == tagText)
        }
    }

    @Test func priorOnlyTagWithZeroCurrentMembersIsTrustedForOmission() throws {
        let xml = operatingSegmentXml(
            tagContextRef: "Prior1YearDuration",
            currentMembers: [])
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            #expect(BreakdownExtractor.dedicatedSingleSegmentDisclosureText(xbrlDir: dir) == nil)
            #expect(BreakdownExtractor.dedicatedSingleSegmentTagTrustedForOmission(xbrlDir: dir) == tagText)
            #expect(
                BreakdownExtractor.currentYearReportableOperatingSegmentSalesMemberCount(xbrlDir: dir)
                    == 0)
        }
    }

    @Test func classifyNotApplicableReasonDoesNotUseTagWhenTwoCurrentMembersExist() throws {
        let xml = operatingSegmentXml(
            tagContextRef: "CurrentYearDuration",
            currentMembers: [("MXMember", "100"), ("EXMember", "200")])
        let segments = ExtractedBreakdown(method: "not_found", tables: [], facts: [])
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let reason = BreakdownExtractor.classifyNotApplicableReason(
                segments: segments, consolidatedSales: 300, xbrlDir: dir)
            #expect(reason != .singleSegmentDisclosed)
        }
    }

    @Test func fallbackRefusesTagWhenCurrentYearReportableCountIsTwoOrMore() {
        #expect(
            !BusinessBreakdownResolver.dedicatedSingleSegmentFallback(
                snapshot: nil, dedicatedTagText: tagText, currentYearReportableSalesMemberCount: 2))
        #expect(
            BusinessBreakdownResolver.dedicatedSingleSegmentFallback(
                snapshot: nil, dedicatedTagText: tagText, currentYearReportableSalesMemberCount: 0))
        #expect(
            BusinessBreakdownResolver.dedicatedSingleSegmentFallback(
                snapshot: nil, dedicatedTagText: tagText, currentYearReportableSalesMemberCount: 1))
    }

    @Test func gateKeepsExtractedWhenTwoCurrentYearMembersExistDespiteDedicatedTag() async throws {
        let xml = operatingSegmentXml(
            tagContextRef: "CurrentYearDuration",
            currentMembers: [("MXMember", "2078600000"), ("EXMember", "1289400000")])
        try await XBRLTestSupport.withXbrlDir(xml) { dir in
            let extracted = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
            let decider = FakeCurrentYearSegmentNoteDecider(
                selection: .noneOfThese, omissionsBySnippet: ["単一セグメント": .singleSegment])
            let business = await noteContext(decider: decider).segmentsAfterNoteDecision(
                axis: .business, docID: "S100P97P", extracted: extracted, xbrlDir: dir,
                consolidatedSales: 3_368_000_000, labelsByTag: [:])
            #expect(business.extracted != nil)
            #expect(business.outcome.omissionReason == nil)
            #expect(business.outcome.action == .unchanged)
            #expect(await decider.tableCalls == 0)
        }
    }

    @Test func gateOmitsWhenCurrentYearTagExistsAndCurrentMembersAreZero() async throws {
        let xml = operatingSegmentXml(
            tagContextRef: "CurrentYearDuration",
            currentMembers: [])
        try await XBRLTestSupport.withXbrlDir(xml) { dir in
            let extracted = ExtractedBreakdown(
                method: "html_table",
                tables: [
                    BreakdownTable(
                        heading: "セグメント情報", markdown: "| 主要な顧客 | 売上高 |\n| A社 | 100 |",
                        period: "当期")
                ],
                facts: [])
            let decider = FakeCurrentYearSegmentNoteDecider(
                selection: .noneOfThese, omissionsBySnippet: [:])
            let business = await noteContext(decider: decider).segmentsAfterNoteDecision(
                axis: .business, docID: "S100UGFD", extracted: extracted, xbrlDir: dir,
                consolidatedSales: 1_000, labelsByTag: [:])
            #expect(business.extracted == nil)
            #expect(business.outcome.omissionReason == breakdownNotApplicableSingleSegmentDisclosed)
            #expect(await decider.tableCalls == 0)
        }
    }

    @Test func gateOmitsWhenPriorOnlyTagExistsAndCurrentMembersAreZero() async throws {
        let xml = operatingSegmentXml(
            tagContextRef: "Prior1YearDuration",
            currentMembers: [])
        try await XBRLTestSupport.withXbrlDir(xml) { dir in
            let extracted = ExtractedBreakdown(
                method: "html_table",
                tables: [
                    BreakdownTable(
                        heading: "セグメント情報", markdown: "| 主要な顧客 | 売上高 |\n| A社 | 100 |",
                        period: "当期")
                ],
                facts: [])
            let business = await noteContext(decider: nil).segmentsAfterNoteDecision(
                axis: .business, docID: "S100LST1", extracted: extracted, xbrlDir: dir,
                consolidatedSales: 1_000, labelsByTag: [:])
            #expect(business.extracted == nil)
            #expect(business.outcome.omissionReason == breakdownNotApplicableSingleSegmentDisclosed)
        }
    }

    @Test func jevOmitBusinessIsOverriddenWhenTwoCurrentYearMembersExist() async throws {
        let xml = operatingSegmentXml(
            tagContextRef: nil,
            currentMembers: [("AlphaMember", "100"), ("BetaMember", "200")],
            includeOmissionSentence: true)
        try await XBRLTestSupport.withXbrlDir(xml) { dir in
            let extracted = ExtractedBreakdown(
                method: "html_table",
                tables: [
                    BreakdownTable(
                        heading: "セグメント情報", markdown: "| 主要な顧客 | 売上高 |\n| A社 | 100 |",
                        period: "当期")
                ],
                facts: [])
            let decider = FakeCurrentYearSegmentNoteDecider(
                selection: .noneOfThese, omissionsBySnippet: ["単一セグメント": .singleSegment])
            // Jev に省略文を渡すため、決定は tables 非空で走る。XBRL 側の当期 member が 2 なら取り消す。
            let business = await noteContext(decider: decider).segmentsAfterNoteDecision(
                axis: .business, docID: "S-jev", extracted: extracted, xbrlDir: dir,
                consolidatedSales: 300, labelsByTag: [:])
            #expect(business.extracted != nil)
            #expect(business.outcome.action == .unchanged)
            #expect(business.outcome.omissionReason == nil)
            #expect(business.outcome.needsReview == true)
        }
    }

    @Test func cacheVersionStartsProductServiceV1() {
        #expect(productServiceBreakdownCacheVersion == "breakdown-product_service-v1")
        #expect(
            breakdownWarningSingleSegmentTagDisagreesWithCurrentYearReportableSegments
                == "single_segment_tag_disagrees_with_current_year_reportable_segments")
    }

    private func noteContext(decider: (any SegmentNoteDeciding)?) -> BltServerContext {
        BltServerContext(
            apiKey: "test", cacheDir: URL(fileURLWithPath: NSTemporaryDirectory()),
            businessChatClient: UnavailableChatClient(),
            geographyChatClient: UnavailableChatClient(),
            segmentNoteDecider: decider)
    }

    private func operatingSegmentXml(
        tagContextRef: String?,
        currentMembers: [(String, String)],
        priorMembers: [(String, String)] = [],
        includeOmissionSentence: Bool = false
    ) -> String {
        func context(id: String, member: String?, prior: Bool) -> String {
            let dates = prior
                ? "<xbrli:startDate>2022-04-01</xbrli:startDate><xbrli:endDate>2023-03-31</xbrli:endDate>"
                : "<xbrli:startDate>2023-04-01</xbrli:startDate><xbrli:endDate>2024-03-31</xbrli:endDate>"
            let scenario: String
            if let member {
                scenario = """
                      <xbrli:scenario>
                        <xbrldi:explicitMember dimension="jppfs_cor:OperatingSegmentsAxis">jppfs_cor:\(member)</xbrldi:explicitMember>
                      </xbrli:scenario>
                    """
            } else {
                scenario = ""
            }
            return """
                  <xbrli:context id="\(id)">
                    <xbrli:entity>
                      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
                    </xbrli:entity>
                    <xbrli:period>\(dates)</xbrli:period>
                    \(scenario)
                  </xbrli:context>
                """
        }
        var contexts = [
            context(id: "CurrentYearDuration", member: nil, prior: false),
            context(id: "Prior1YearDuration", member: nil, prior: true),
            context(id: "CurrentYearDuration_NonConsolidatedMember", member: nil, prior: false),
            context(id: "Prior1YearDuration_NonConsolidatedMember", member: nil, prior: true),
        ]
        var facts: [String] = []
        if let tagContextRef {
            facts.append(
                "<jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment contextRef=\"\(tagContextRef)\">\(tagText)</jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment>"
            )
        }
        if includeOmissionSentence {
            facts.append(
                "<jpcrp_cor:SegmentInformationTextBlock contextRef=\"CurrentYearDuration\">\(tagText)</jpcrp_cor:SegmentInformationTextBlock>"
            )
        }
        for (member, amount) in currentMembers {
            let id = "CurrentYearDuration_\(member)"
            contexts.append(context(id: id, member: member, prior: false))
            facts.append(
                "<jppfs_cor:NetSales contextRef=\"\(id)\" unitRef=\"JPY\" decimals=\"-6\">\(amount)</jppfs_cor:NetSales>"
            )
        }
        for (member, amount) in priorMembers {
            let id = "Prior1YearDuration_\(member)"
            contexts.append(context(id: id, member: member, prior: true))
            facts.append(
                "<jppfs_cor:NetSales contextRef=\"\(id)\" unitRef=\"JPY\" decimals=\"-6\">\(amount)</jppfs_cor:NetSales>"
            )
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrli:xbrl
            xmlns:xbrli="\(XBRLTestSupport.nsXbrli)"
            xmlns:xbrldi="http://xbrl.org/2006/xbrldi"
            xmlns:jppfs_cor="\(XBRLTestSupport.nsJppfs)"
            xmlns:jpcrp_cor="\(XBRLTestSupport.nsJpcrp)">
        \(contexts.joined(separator: "\n"))
          <xbrli:unit id="JPY"><xbrli:measure>iso4217:JPY</xbrli:measure></xbrli:unit>
          \(facts.joined(separator: "\n"))
        </xbrli:xbrl>
        """
    }
}

private actor FakeCurrentYearSegmentNoteDecider: SegmentNoteDeciding {
    private(set) var tableCalls = 0
    let selection: SegmentNoteTableSelection
    let omissionsBySnippet: [String: SegmentNoteOmission]

    init(
        selection: SegmentNoteTableSelection,
        omissionsBySnippet: [String: SegmentNoteOmission]
    ) {
        self.selection = selection
        self.omissionsBySnippet = omissionsBySnippet
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
        var omission = SegmentNoteOmission.none
        for (snippet, value) in omissionsBySnippet where sentence.contains(snippet) {
            omission = value
            break
        }
        return SegmentNoteConsultedChoice(
            question: OpenRouterSegmentNoteDecider.omissionQuestion,
            selected: omission.choiceKey,
            probability: 1,
            options: OpenRouterSegmentNoteDecider.omissionOptionKeys,
            sentences: [sentence])
    }

    func reviewDecision(
        proposal: SegmentNoteReviewProposal,
        tables: [SegmentNoteTableCandidate],
        sentences: [String]
    ) async -> SegmentNoteConsultedChoice {
        SegmentNoteConsultedChoice(
            question: OpenRouterSegmentNoteDecider.reviewDecisionQuestion,
            selected: OpenRouterSegmentNoteDecider.reviewKeep,
            probability: 1,
            options: tables.map { "\($0.index)" } + [OpenRouterSegmentNoteDecider.reviewKeep],
            sentences: sentences)
    }
}
