// SPEC_ORACLE: /financials の rd の分母を製造費用込みの注記へ替える判定（本文の1文と注記の金額の一致）。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct ResearchAndDevelopmentNoteMatchTests {
    @Test func convertsOkuAndMillionAndThousandYen() {
        let oku = ResearchAndDevelopmentProseTotalDecision.candidates(
            in: "当連結会計年度の研究開発費は7,302億円であります。")
        #expect(oku.map(\.yen) == [730_200_000_000])

        let million = ResearchAndDevelopmentProseTotalDecision.candidates(
            in: "当連結会計年度における研究開発費の総額は4,409百万円であります。")
        #expect(million.map(\.yen) == [4_409_000_000])

        let thousand = ResearchAndDevelopmentProseTotalDecision.candidates(
            in: "研究開発費は1,234千円であります。")
        #expect(thousand.map(\.yen) == [1_234_000])

        let spaced = ResearchAndDevelopmentProseTotalDecision.candidates(
            in: "研究開発費は4,409 百万円であります。")
        #expect(spaced.map(\.yen) == [4_409_000_000])
    }

    @Test func convertsFullwidthDigitsAndKeepsPercentSentenceOut() {
        let fullwidth = ResearchAndDevelopmentProseTotalDecision.candidates(
            in: "研究開発費は４，４０９百万円であります。")
        #expect(fullwidth.map(\.yen) == [4_409_000_000])

        let ideographicComma = ResearchAndDevelopmentProseTotalDecision.candidates(
            in: "研究開発費は４、４０９百万円であります。")
        #expect(ideographicComma.map(\.yen) == [4_409_000_000])

        let percentOnly = ResearchAndDevelopmentProseTotalDecision.candidates(
            in: "繊維事業に約10%であります。約１０％であります。")
        #expect(percentOnly.isEmpty)

        let percentBesideTotal = ResearchAndDevelopmentProseTotalDecision.candidates(
            in: "繊維事業に約10%であります。研究開発費は744億円であります。")
        #expect(percentBesideTotal.map(\.yen) == [74_400_000_000])
    }

    @Test func dropsZeroNegativeAndMultiAmountSentences() {
        #expect(
            ResearchAndDevelopmentProseTotalDecision.candidates(
                in: "研究開発費は0百万円であります。研究開発費は0千円であります。").isEmpty)
        #expect(
            ResearchAndDevelopmentProseTotalDecision.candidates(
                in: "研究開発費は△4,409百万円であります。").isEmpty)
        #expect(
            ResearchAndDevelopmentProseTotalDecision.candidates(
                in: "研究開発費は4,409百万円（前連結会計年度は3,800百万円）であります。").isEmpty)
        #expect(
            ResearchAndDevelopmentProseTotalDecision.candidates(
                in: "賃貸事業55百万円、マネジメント113百万円であります。").isEmpty)
    }

    @Test func readsAmountsFromHtmlAndPrefersResearchSentencesPastTheCap() {
        let html = """
            <p>研究開発費は４，４０９百万円であります。</p>
            <p>前連結会計年度は3,800百万円であります。</p>
            """
        let text = BreakdownProseToolkit.plainText(from: html)
        let found = ResearchAndDevelopmentProseTotalDecision.candidates(in: text)
        #expect(found.map(\.yen) == [4_409_000_000, 3_800_000_000])

        var lines: [String] = []
        for index in 1...13 {
            lines.append("項目\(index)は\(index)百万円である")
        }
        lines.append("研究開発費は99百万円である")
        let capped = ResearchAndDevelopmentProseTotalDecision.candidates(in: lines.joined(separator: "。") + "。")
        #expect(capped.count == 12)
        #expect(capped.contains { $0.yen == 99_000_000 })
    }

    @Test func proseYenMatchesTheNumericTag() async throws {
        let cases: [(docID: String, yen: Double)] = [
            ("S100W043", 4_409_000_000),
            ("S100W07G", 730_200_000_000),
            ("S100W17I", 436_000_000_000),
        ]
        await SmokeCacheSupport.ensureCached(cases.map(\.docID))
        for item in cases {
            let dir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(item.docID)_xbrl")
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: dir)
            #expect(rd.tag == "ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities")
            #expect(rd.value == item.yen)
            let text = try #require(ResearchAndDevelopmentProseTotalDecision.activityPlainText(in: dir))
            let found = ResearchAndDevelopmentProseTotalDecision.candidates(in: text)
            #expect(found.contains { $0.yen == item.yen })
        }
    }

    /// SPEC_ORACLE: 東レ S100W2HQ。総額744億円とこのうち526億円が同一文。候補にしない。
    /// 数値タグが 74,400,000,000 を持つので本文経路は使わない。
    @Test func torayParentheticalTotalIsNotACandidate() async throws {
        let docID = "S100W2HQ"
        await SmokeCacheSupport.ensureCached([docID])
        let dir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: dir)
        #expect(rd.value == 74_400_000_000)
        let text = try #require(ResearchAndDevelopmentProseTotalDecision.activityPlainText(in: dir))
        #expect(ResearchAndDevelopmentProseTotalDecision.candidates(in: text).isEmpty)
    }

    /// SPEC_ORACLE: ブシロード型。活動タグはセグメント member だけで、販管費は個別だけ。
    /// 連結の全社合計は製造費用込みの注記だけにある。Summary `rd` はその注記。
    @Test func segmentOnlyActivityTagFallsBackToManufacturingNoteTotal() throws {
        let noteTag = Xbrl.rdExpenseIncludedInGaAndManufacturingCostTag
        let xml = rdDurationXml(
            activity: [("CurrentYearDuration_EntertainmentBusinessReportableSegmentMember", "811709000")],
            noteCurrent: "811709000",
            sga: [("CurrentYearDuration_NonConsolidatedMember", "100")],
            extra: """
                <jppfs_cor:NetSales contextRef="CurrentYearDuration" unitRef="JPY" decimals="0">1</jppfs_cor:NetSales>
                <jppfs_cor:NetSales contextRef="CurrentYearDuration_NonConsolidatedMember" unitRef="JPY" decimals="0">1</jppfs_cor:NetSales>
                """)
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: dir)
            #expect(rd.value == 811_709_000)
            #expect(rd.tag == noteTag)
        }
    }

    /// SPEC_ORACLE: member の活動額が注記と違うときは注記へ落ちない。
    @Test func unmatchedActivityMemberDoesNotTakeTheManufacturingNote() throws {
        let xml = rdDurationXml(
            activity: [("CurrentYearDuration_EntertainmentBusinessReportableSegmentMember", "100")],
            noteCurrent: "811709000")
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: dir)
            #expect(rd.value == nil)
        }
    }

    /// SPEC_ORACLE: 個別 member だけが注記と同額でも、連結の全社合計にはしない。
    @Test func nonConsolidatedActivityMemberDoesNotConfirmTheManufacturingNote() throws {
        let xml = rdDurationXml(
            activity: [("CurrentYearDuration_NonConsolidatedMember", "811709000")],
            noteCurrent: "811709000",
            extra: """
                <jppfs_cor:NetSales contextRef="CurrentYearDuration" unitRef="JPY" decimals="0">1</jppfs_cor:NetSales>
                <jppfs_cor:NetSales contextRef="CurrentYearDuration_NonConsolidatedMember" unitRef="JPY" decimals="0">1</jppfs_cor:NetSales>
                """)
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: dir)
            #expect(rd.value == nil)
        }
    }

    /// SPEC_ORACLE: 前期 member が注記と同額でも当期の全社合計にはしない。
    @Test func priorActivityMemberDoesNotConfirmTheManufacturingNote() throws {
        let xml = rdDurationXml(
            activity: [("Prior1YearDuration_EntertainmentBusinessReportableSegmentMember", "811709000")],
            noteCurrent: "811709000")
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: dir)
            #expect(rd.value == nil)
        }
    }

    /// SPEC_ORACLE: 無 dimension の活動タグ全社合計がある書類は注記へ替えない。
    @Test func undimensionedActivityTotalKeepsTheActivityTag() throws {
        let xml = rdDurationXml(
            activity: [
                ("CurrentYearDuration", "74400000000"),
                ("CurrentYearDuration_ReportableSegmentsMember", "811709000"),
            ],
            noteCurrent: "811709000")
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: dir)
            #expect(rd.value == 74_400_000_000)
            #expect(rd.tag == "ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities")
        }
    }

    /// SPEC_ORACLE: ブシロード S100Z4J4。活動タグはセグメント member だけで、販管費タグは個別だけ。
    /// 連結の全社合計は製造費用込みの注記 811,709千円（有報 p.92）だけにある。
    @Test func bushiroadSegmentOnlyActivityTagFallsBackToManufacturingNote() async throws {
        let docID = "S100Z4J4"
        await SmokeCacheSupport.ensureCached([docID])
        let dir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: dir)
        #expect(rd.value == 811_709_000)
        #expect(rd.tag == Xbrl.rdExpenseIncludedInGaAndManufacturingCostTag)
    }

    /// SPEC_ORACLE: 日産化学 S100W4NI。数値タグは無い。
    /// グループ全体 17,578百万円と、セグメント別の5文（合計が同じ17,578百万円）が別文。
    /// 当期総額が1文だけのとき、採用するのはその総額で、セグメント文は行にしない。
    /// member 付き活動タグが無いので Summary `rd` は null のまま（本文総額は読まない）。
    @Test func manufacturingNoteMatchesOneActivityTotalSentence() {
        let text = """
            当連結会計年度における当社グループの研究開発費は、332億円であります。\
            なお、本費用には、各事業区分に配分できない費用として計上する費用57億円が含まれております。\
            なお、当連結会計年度における研究開発費は、62億円であります。
            """
        #expect(
            ResearchAndDevelopmentProseTotalDecision.confirmsManufacturingNote(
                extractedTag: "ResearchAndDevelopmentExpensesSGA",
                extractedYen: 19_754_000_000, noteYen: 33_244_000_000, plainText: text))
        #expect(
            ResearchAndDevelopmentProseTotalDecision.confirmsManufacturingNote(
                extractedTag: "ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities",
                extractedYen: 33_244_000_000, noteYen: 33_244_000_000, plainText: text) == false)
    }

    /// SPEC_ORACLE: 配分できない 57億円は差額 6,244百万円と 5百万円では一致しない。
    /// その1文だけを足すと 32,700百万円になり、分母 33,244百万円の 5% 以内に収まる。
    @Test func kobeNoteAndMitsuiActivityTotalStayOnTheirTags() async throws {
        let cases: [(docID: String, tag: String, yen: Double)] = [
            (
                "S100OAOM",
                Xbrl.rdExpenseIncludedInGaAndManufacturingCostTag,
                33_244_000_000
            ),
            (
                "S100YBQV",
                "ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities",
                15_051_000_000
            ),
        ]
        await SmokeCacheSupport.ensureCached(cases.map(\.docID))
        for item in cases {
            let dir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(item.docID)_xbrl")
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: dir)
            #expect(rd.tag == item.tag, "\(item.docID) tag \(String(describing: rd.tag))")
            #expect(rd.value == item.yen, "\(item.docID) value \(String(describing: rd.value))")
        }
    }
}

private func rdDurationXml(
    activity: [(String, String)] = [],
    noteCurrent: String? = nil,
    sga: [(String, String)] = [],
    extra: String = ""
) -> String {
    var elements: [String] = []
    for (ctx, value) in activity {
        elements.append(
            """
            <jppfs_cor:ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities \
            contextRef="\(ctx)" unitRef="JPY" decimals="0">\(value)\
            </jppfs_cor:ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities>
            """)
    }
    if let noteCurrent {
        let tag = Xbrl.rdExpenseIncludedInGaAndManufacturingCostTag
        elements.append(
            """
            <jppfs_cor:\(tag) contextRef="CurrentYearDuration" unitRef="JPY" decimals="0">\
            \(noteCurrent)</jppfs_cor:\(tag)>
            """)
    }
    for (ctx, value) in sga {
        elements.append(
            """
            <jppfs_cor:ResearchAndDevelopmentExpensesSGA contextRef="\(ctx)" \
            unitRef="JPY" decimals="0">\(value)</jppfs_cor:ResearchAndDevelopmentExpensesSGA>
            """)
    }
    if !extra.isEmpty { elements.append(extra) }
    return XBRLTestSupport.makeXbrlDuration(elements.joined(separator: "\n"))
}
