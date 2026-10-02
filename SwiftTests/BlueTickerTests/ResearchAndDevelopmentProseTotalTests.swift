// SPEC_ORACLE: 研究開発費の本文総額。金額はコードが円へ換算し、Jev は文の分類だけ。
// ライブの Decisions API は呼ばない。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct ResearchAndDevelopmentProseTotalTests {
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
        let text = ResearchAndDevelopmentProseTotalDecision.plainText(from: html)
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

    @Test func appliesOnlyOneCurrentTotalAtOrAboveTheThreshold() async {
        let text = """
            各報告セグメントに配分することが困難であります。
            当連結会計年度の研究開発費は4,409百万円であります。
            前連結会計年度の研究開発費は3,800百万円であります。
            """
        let current = "当連結会計年度の研究開発費は4,409百万円であります"
        let prior = "前連結会計年度の研究開発費は3,800百万円であります"
        let applied = await ResearchAndDevelopmentProseTotalDecision.decide(
            plainText: text, docID: "S100W043",
            decider: ScriptedProseDecider(selected: [
                current: (ResearchAndDevelopmentProseRole.currentCompanyTotal, 0.95),
                prior: (ResearchAndDevelopmentProseRole.priorPeriod, 0.99),
            ]))
        guard case .applied(let total) = applied else {
            Issue.record("expected an applied total")
            return
        }
        #expect(total.yen == 4_409_000_000)
        #expect(total.warnings == [breakdownWarningNotAllocatableToSegments])
        #expect(total.audit.applied == true)
        #expect(total.audit.needsReview == false)
        #expect(total.audit.axis == breakdownAxisResearchAndDevelopment)
        #expect(total.audit.threshold == SegmentNoteDecision.applyProbabilityThreshold)
        #expect(total.audit.calls.filter(\.applied).map(\.sentences) == [[current]])
        let snapshot = ResearchAndDevelopmentProseTotalDecision.snapshot(
            axis: breakdownAxisResearchAndDevelopment, total: total)
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.denominator == 4_409_000_000)
        #expect(snapshot.denominatorTag == breakdownDenominatorTagResearchAndDevelopmentProse)
        #expect(snapshot.sourceKind == breakdownSourceResearchAndDevelopmentProse)
        #expect(snapshot.needsReview == false)

        let boundary = await ResearchAndDevelopmentProseTotalDecision.decide(
            plainText: "研究開発費は4,409百万円であります。",
            decider: ScriptedProseDecider(selected: [
                "研究開発費は4,409百万円であります": (
                    ResearchAndDevelopmentProseRole.currentCompanyTotal, 0.9)
            ]))
        guard case .applied(let boundaryTotal) = boundary else {
            Issue.record("0.9 should apply")
            return
        }
        #expect(boundaryTotal.yen == 4_409_000_000)
        #expect(boundaryTotal.warnings.isEmpty)
    }

    @Test func withholdsLowProbabilityPriorAndTwoCurrentTotals() async {
        let low = await ResearchAndDevelopmentProseTotalDecision.decide(
            plainText: "研究開発費は4,409百万円であります。",
            decider: ScriptedProseDecider(selected: [
                "研究開発費は4,409百万円であります": (
                    ResearchAndDevelopmentProseRole.currentCompanyTotal, 0.5)
            ]))
        #expect(low == .notApplied)

        let priorOnly = await ResearchAndDevelopmentProseTotalDecision.decide(
            plainText: "前連結会計年度の研究開発費は3,800百万円であります。",
            decider: ScriptedProseDecider(selected: [
                "前連結会計年度の研究開発費は3,800百万円であります": (
                    ResearchAndDevelopmentProseRole.priorPeriod, 0.99)
            ]))
        #expect(priorOnly == .notApplied)

        let text = "研究開発費は4,409百万円であります。研究開発費は5,000百万円であります。"
        let first = "研究開発費は4,409百万円であります"
        let second = "研究開発費は5,000百万円であります"
        let two = await ResearchAndDevelopmentProseTotalDecision.decide(
            plainText: text,
            decider: ScriptedProseDecider(selected: [
                first: (ResearchAndDevelopmentProseRole.currentCompanyTotal, 0.95),
                second: (ResearchAndDevelopmentProseRole.currentCompanyTotal, 0.95),
            ]))
        #expect(two == .notApplied)

        let singleSegment = await ResearchAndDevelopmentProseTotalDecision.decide(
            plainText: "単一セグメントであるため記載を省略しております。研究開発費は4,409百万円であります。",
            decider: ScriptedProseDecider(selected: [
                "研究開発費は4,409百万円であります": (
                    ResearchAndDevelopmentProseRole.currentCompanyTotal, 0.95)
            ]))
        guard case .applied(let total) = singleSegment else {
            Issue.record("single-segment wording should still keep the total")
            return
        }
        #expect(total.warnings.isEmpty)
    }

    @Test func missingChoiceDoesNotLockATotal() async {
        let sentence = "研究開発費は4,409百万円であります"
        let missing = await ResearchAndDevelopmentProseTotalDecision.decide(
            plainText: sentence + "。",
            decider: ScriptedProseDecider(selected: [:], unavailableSentences: [sentence]))
        #expect(missing == .unavailable)

        let mixed = await ResearchAndDevelopmentProseTotalDecision.decide(
            plainText: "研究開発費は4,409百万円であります。前連結会計年度の研究開発費は3,800百万円であります。",
            decider: ScriptedProseDecider(
                selected: [
                    "研究開発費は4,409百万円であります": (
                        ResearchAndDevelopmentProseRole.currentCompanyTotal, 0.95)
                ],
                unavailableSentences: ["前連結会計年度の研究開発費は3,800百万円であります"]))
        #expect(mixed == .unavailable)
    }

    @Test func emptyTextDoesNotCallTheDecider() async {
        let counter = CountingProseDecider()
        let decision = await ResearchAndDevelopmentProseTotalDecision.decide(
            plainText: "割合だけの記載です。", decider: counter)
        #expect(decision == .notApplied)
        #expect(await counter.calls == 0)
    }

    @Test func choiceUsesSelectedProbabilityNotConfidence() async throws {
        let json = """
            {
              "answers": {
                "research_and_development_total": {
                  "type": "choice",
                  "choice": "current_company_total",
                  "probabilities": { "current_company_total": 0.95 },
                  "confidence": 0.1
                }
              }
            }
            """.data(using: .utf8)!
        let choice = await OpenRouterResearchAndDevelopmentProseDecider(
            client: FixedProseDecisionClient(body: json)
        ).classify(sentence: "研究開発費は4,409百万円であります")
        #expect(choice.selected == ResearchAndDevelopmentProseRole.currentCompanyTotal)
        #expect(choice.probability == 0.95)

        let confidenceOnly = """
            {
              "answers": {
                "research_and_development_total": {
                  "type": "choice",
                  "choice": "current_company_total",
                  "confidence": 0.99
                }
              }
            }
            """.data(using: .utf8)!
        let ignored = await OpenRouterResearchAndDevelopmentProseDecider(
            client: FixedProseDecisionClient(body: confidenceOnly)
        ).classify(sentence: "研究開発費は4,409百万円であります")
        #expect(ignored.selected == ResearchAndDevelopmentProseRole.currentCompanyTotal)
        #expect(ignored.probability == nil)
    }

    /// SPEC_ORACLE: 数値タグがある書類は本文経路に入らない。本文の単一金額は同じ円になる。
    /// S100W043 4,409百万円、S100W07G 7,302億円、S100W17I 4,360億円。
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

    /// SPEC_ORACLE: 日産化学 S100W4NI。数値タグは無い。
    /// グループ全体 17,578百万円と、セグメント別の5文（合計が同じ17,578百万円）が別文。
    /// 当期総額が1文だけのとき、採用するのはその総額で、セグメント文は行にしない。
    @Test func nissanChemicalProseKeepsOnlyTheCompanyTotal() async throws {
        let docID = "S100W4NI"
        await SmokeCacheSupport.ensureCached([docID])
        let dir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: dir)
        #expect(rd.value == nil)
        let text = try #require(ResearchAndDevelopmentProseTotalDecision.activityPlainText(in: dir))
        let found = ResearchAndDevelopmentProseTotalDecision.candidates(in: text)
        #expect(found.map(\.yen) == [
            17_578_000_000, 273_000_000, 8_303_000_000, 4_472_000_000, 589_000_000, 3_941_000_000,
        ])
        let partials = found.dropFirst().map(\.yen).reduce(0, +)
        #expect(partials == found.first?.yen)
        #expect(ResearchAndDevelopmentProseTotalDecision.mentionsNotAllocatableToSegments(text) == false)

        var selected: [String: (String, Double)] = [:]
        for candidate in found {
            let role = candidate.sentence.contains("グループ全体の研究開発費の総額")
                ? ResearchAndDevelopmentProseRole.currentCompanyTotal
                : ResearchAndDevelopmentProseRole.partialAmount
            selected[candidate.sentence] = (role, 0.95)
        }
        let decision = await ResearchAndDevelopmentProseTotalDecision.decide(
            plainText: text, docID: docID, decider: ScriptedProseDecider(selected: selected))
        guard case .applied(let total) = decision else {
            Issue.record("expected the company total")
            return
        }
        #expect(total.yen == 17_578_000_000)
        #expect(total.warnings.isEmpty)
        let snapshot = ResearchAndDevelopmentProseTotalDecision.snapshot(
            axis: breakdownAxisResearchAndDevelopment, total: total)
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.sourceKind == breakdownSourceResearchAndDevelopmentProse)
    }

    @Test func fillsAShortfallWhenOneSentenceMatchesAndJevCallsItUnallocated() async {
        let denominator = 339_288_000_000.0
        let tagged = 286_317_000_000.0
        let snapshot = shortfallSnapshot(denominator: denominator, tagged: tagged)
        let sentence = "基礎研究等のその他及び全社に係る研究開発費は52,971百万円であります"
        let text = """
            研究開発費の総額は339,288百万円であります。
            \(sentence)。
            イメージングは112,298百万円であります。
            """
        let filled = await ResearchAndDevelopmentProseTotalDecision.fillShortfall(
            snapshot: snapshot, plainText: text, docID: "S100XTLJ",
            decider: ScriptedProseDecider(
                selected: [:],
                remainder: [sentence: (ResearchAndDevelopmentRemainderRole.unallocatedRemainder, 0.97)]))
        #expect(filled.snapshot.rows.count == 2)
        let added = filled.snapshot.rows[1]
        #expect(added.amount == 52_971_000_000)
        #expect(added.rowKind == "reconciling")
        #expect(added.label == "基礎研究等のその他及び全社に係る研究開発費")
        #expect(filled.snapshot.needsReview == false)
        #expect(filled.snapshot.warnings == [breakdownWarningResearchAndDevelopmentProseRemainder])
        #expect(filled.snapshot.sourceKind == breakdownSourceXbrlFacts)
        #expect(filled.snapshot.denominatorTag == snapshot.denominatorTag)
        #expect(filled.audit?.applied == true)
        #expect(filled.audit?.calls.filter(\.applied).count == 1)
    }

    @Test func keepsTheTaggedSnapshotWhenTheRemainderSentenceDoesNotQualify() async {
        let snapshot = shortfallSnapshot(denominator: 339_288_000_000, tagged: 286_317_000_000)
        let sentence = "基礎研究等のその他及び全社に係る研究開発費は52,971百万円であります"
        let low = await ResearchAndDevelopmentProseTotalDecision.fillShortfall(
            snapshot: snapshot, plainText: sentence + "。",
            decider: ScriptedProseDecider(
                selected: [:],
                remainder: [sentence: (ResearchAndDevelopmentRemainderRole.unallocatedRemainder, 0.5)]))
        #expect(low.snapshot.rows.count == 1)
        #expect(low.audit == nil)

        let segment = await ResearchAndDevelopmentProseTotalDecision.fillShortfall(
            snapshot: snapshot, plainText: sentence + "。",
            decider: ScriptedProseDecider(
                selected: [:],
                remainder: [sentence: (ResearchAndDevelopmentRemainderRole.segmentAmount, 0.99)]))
        #expect(segment.snapshot.rows.count == 1)

        let two = """
            基礎研究は52,971百万円であります。
            全社共通は52,971百万円であります。
            """
        let counter = CountingProseDecider()
        let ambiguous = await ResearchAndDevelopmentProseTotalDecision.fillShortfall(
            snapshot: snapshot, plainText: two, decider: counter)
        #expect(ambiguous.snapshot.rows.count == 1)
        #expect(await counter.calls == 0)

        let balanced = shortfallSnapshot(denominator: 100, tagged: 100)
        let untouched = await ResearchAndDevelopmentProseTotalDecision.fillShortfall(
            snapshot: balanced, plainText: "残りは52,971百万円であります。", decider: counter)
        #expect(untouched.snapshot.rows.count == 1)
        #expect(await counter.calls == 0)

        let totalOnly = BreakdownSnapshot(
            axis: breakdownAxisResearchAndDevelopment, denominator: 52_971_000_000,
            denominatorTag: "ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities",
            rows: [], sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
        let notDoubled = await ResearchAndDevelopmentProseTotalDecision.fillShortfall(
            snapshot: totalOnly, plainText: sentence + "。", decider: counter)
        #expect(notDoubled.snapshot.rows.isEmpty)
        #expect(await counter.calls == 0)
    }

    @Test func matchesAShortfallWithinMillionYenRounding() {
        #expect(
            ResearchAndDevelopmentProseTotalDecision.matchesShortfall(
                2_096_000_000, gap: 2_098_000_000))
        #expect(
            ResearchAndDevelopmentProseTotalDecision.matchesShortfall(
                934_000_000, gap: 937_000_000))
        #expect(
            ResearchAndDevelopmentProseTotalDecision.matchesShortfall(
                40_000_000_000, gap: 52_971_000_000) == false)
        #expect(
            ResearchAndDevelopmentProseTotalDecision.matchesShortfall(
                52_639_000_000, gap: 52_589_000_000) == false)
        #expect(
            ResearchAndDevelopmentProseTotalDecision.matchesShortfall(
                16_602_000_000, gap: 16_589_000_000) == false)
        let label = ResearchAndDevelopmentProseTotalDecision.remainderLabel(
            in: "なお、各セグメントに帰属しない研究開発費の合計は138,353百万円です")
        #expect(label == "各セグメントに帰属しない研究開発費の合計")
    }

    /// SPEC_ORACLE: キヤノン S100XTLJ とエーザイ S100YB05。
    /// タグ付き行の不足額と一致する本文は1文。
    @Test func canonAndEisaiShortfallsMatchOneResearchSentence() async throws {
        let cases = ["S100XTLJ", "S100YB05"]
        await SmokeCacheSupport.ensureCached(cases)
        for docID in cases {
            let dir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
            let facts = BreakdownExtractor.extractFactsByDimension(
                xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
                contextMap: contextMap)
            let labels = XBRLUtils.breakdownMemberLabels(in: dir)
            let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: dir)
            let snapshot = try #require(
                BreakdownNormalizer.normalizeResearchAndDevelopment(
                    facts: facts, total: rd.value, totalTag: rd.tag,
                    axis: breakdownAxisResearchAndDevelopment, labelsByTag: labels))
            let gap = try #require(ResearchAndDevelopmentProseTotalDecision.shortfall(in: snapshot))
            let text = try #require(ResearchAndDevelopmentProseTotalDecision.activityPlainText(in: dir))
            let matches = ResearchAndDevelopmentProseTotalDecision.candidates(in: text, limit: nil)
                .filter { ResearchAndDevelopmentProseTotalDecision.matchesShortfall($0.yen, gap: gap) }
            #expect(matches.count == 1, "\(docID) gap \(gap) matches \(matches.map(\.yen))")
            #expect(matches.first?.sentence.contains("研究開発費") == true)
        }
    }

    @Test func requestAsksForAClassAndNotAnAmount() throws {
        let data = try #require(
            OpenRouterResearchAndDevelopmentProseDecider.requestJSON(
                model: Api.openrouterDecisionsModel,
                sentence: "研究開発費は4,409百万円であります"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["model"] as? String == "typesafe/jev-1.13")
        let questions = try #require(object["questions"] as? [String: Any])
        let question = try #require(
            questions[ResearchAndDevelopmentProseTotalDecision.question] as? [String: Any])
        #expect(question["type"] as? String == "choice")
        let instructions = try #require(question["instructions"] as? String)
        #expect(instructions.contains("金額の数値は選ばない"))
        let criteria = try #require(question["criteria"] as? [String: String])
        #expect(Set(criteria.keys) == Set(ResearchAndDevelopmentProseRole.optionKeys))

        let remainderData = try #require(
            OpenRouterResearchAndDevelopmentProseDecider.remainderRequestJSON(
                model: Api.openrouterDecisionsModel,
                sentence: "基礎研究等のその他及び全社に係る研究開発費は52,971百万円であります"))
        let remainderObject = try #require(JSONSerialization.jsonObject(with: remainderData) as? [String: Any])
        let remainderQuestions = try #require(remainderObject["questions"] as? [String: Any])
        let remainder = try #require(
            remainderQuestions[OpenRouterResearchAndDevelopmentProseDecider.remainderQuestion] as? [String: Any])
        #expect(remainder["type"] as? String == "choice")
        let remainderCriteria = try #require(remainder["criteria"] as? [String: String])
        #expect(Set(remainderCriteria.keys) == Set(ResearchAndDevelopmentRemainderRole.optionKeys))

        let exclusionData = try #require(
            OpenRouterResearchAndDevelopmentProseDecider.exclusionRequestJSON(
                model: Api.openrouterDecisionsModel,
                sentence: "グループ全体の研究開発費は、15,051百万円であり、このほか1,046百万円の探鉱費を支出いたしました"))
        let exclusionObject = try #require(JSONSerialization.jsonObject(with: exclusionData) as? [String: Any])
        let exclusionQuestions = try #require(exclusionObject["questions"] as? [String: Any])
        let exclusion = try #require(
            exclusionQuestions[OpenRouterResearchAndDevelopmentProseDecider.exclusionQuestion] as? [String: Any])
        #expect(exclusion["type"] as? String == "choice")
        let exclusionCriteria = try #require(exclusion["criteria"] as? [String: String])
        #expect(Set(exclusionCriteria.keys) == Set(ResearchAndDevelopmentExclusionRole.optionKeys))
    }

    /// SPEC_ORACLE: 神戸製鋼 S100OAOM。活動タグに全社合計が無く、本文の 332億円が
    /// 製造費用込みの注記 33,244百万円と 0.5億円以内で一致する。販管費 19,754百万円へは落ちない。
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
    @Test func unallocatedOkuSentenceFillsARoundedShortfall() async throws {
        let text = """
            当連結会計年度における当社グループの研究開発費は、332億円であります。\
            なお、本費用には、各事業区分に配分できない費用として計上する費用57億円が含まれております。\
            なお、当連結会計年度における研究開発費は、62億円であります。
            """
        let snapshot = shortfallSnapshot(denominator: 33_244_000_000, tagged: 27_000_000_000)
        let gap = try #require(ResearchAndDevelopmentProseTotalDecision.shortfall(in: snapshot))
        #expect(gap == 6_244_000_000)
        let exact = ResearchAndDevelopmentProseTotalDecision.candidates(in: text, limit: nil)
            .filter { ResearchAndDevelopmentProseTotalDecision.matchesShortfall($0.yen, gap: gap) }
        #expect(exact.isEmpty)
        let sentence = "なお、本費用には、各事業区分に配分できない費用として計上する費用57億円が含まれております"
        let filled = await ResearchAndDevelopmentProseTotalDecision.fillShortfall(
            snapshot: snapshot, plainText: text,
            decider: ScriptedProseDecider(
                selected: [:],
                remainder: [sentence: (ResearchAndDevelopmentRemainderRole.unallocatedRemainder, 0.95)]))
        #expect(filled.audit != nil)
        #expect(filled.snapshot.needsReview == false)
        let added = try #require(
            filled.snapshot.rows.first { $0.rowKind == "reconciling" })
        #expect(added.amount == 5_700_000_000)
        #expect(added.label == "配分不能")
        #expect(filled.snapshot.warnings.contains(breakdownWarningResearchAndDevelopmentProseRemainder))
    }

    /// SPEC_ORACLE: 三井金属 S100YBQV。総額 15,051百万円と探鉱費 1,046百万円は同じ文。
    /// 超過分と一致する外の金額だけを負の行にし、既存行は残す。
    @Test func explorationOutsideTheTotalBecomesANegativeRow() async throws {
        let sentence = "当連結会計年度におけるグループ全体の研究開発費は、15,051百万円であり、このほか海外鉱山開発に向けた探鉱活動に取り組んでおり、1,046百万円の探鉱費を支出いたしました"
        let inside = "この結果、当部門に係る研究開発費は探鉱費を含めて1,169百万円であります"
        let text = sentence + "。" + inside
        let total = 15_051_000_000.0
        let tagged = 16_097_000_000.0
        let found = ResearchAndDevelopmentProseTotalDecision.exclusionCandidates(
            in: text, total: total, excess: 1_046_000_000)
        #expect(found.count == 1)
        #expect(found.first?.yen == 1_046_000_000)
        #expect(ResearchAndDevelopmentProseTotalDecision.exclusionLabel(in: sentence) == "探鉱費")
        let snapshot = shortfallSnapshot(denominator: total, tagged: tagged)
        let filled = await ResearchAndDevelopmentProseTotalDecision.fillExclusion(
            snapshot: snapshot, plainText: text,
            decider: ScriptedProseDecider(
                selected: [:],
                exclusion: [sentence: (ResearchAndDevelopmentExclusionRole.excludedFromTotal, 0.95)]))
        #expect(filled.snapshot.needsReview == false)
        let added = try #require(filled.snapshot.rows.first { $0.amount < 0 })
        #expect(added.amount == -1_046_000_000)
        #expect(added.label == "探鉱費")
        #expect(added.rowKind == "reconciling")
        #expect(filled.snapshot.rows.contains { $0.amount == tagged })
        #expect(filled.snapshot.warnings.contains(breakdownWarningResearchAndDevelopmentProseExclusion))
    }

    /// SPEC_ORACLE: 神戸製鋼 S100OAOM の分母は製造費用込みの注記。三井金属 S100YBQV は活動タグのまま。
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

private func shortfallSnapshot(denominator: Double, tagged: Double) -> BreakdownSnapshot {
    BreakdownSnapshot(
        axis: breakdownAxisResearchAndDevelopment, denominator: denominator,
        denominatorTag: "ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities",
        rows: [
            BreakdownRow(
                labelRaw: "Imaging", label: "イメージング", amount: tagged,
                share: tagged / denominator, profit: nil, rowKind: "segment")
        ],
        sourceKind: breakdownSourceXbrlFacts, needsReview: true,
        warnings: [ResearchAndDevelopmentProseTotalDecision.segmentSumFarWarning])
}

private struct ScriptedProseDecider: ResearchAndDevelopmentProseDeciding {
    var selected: [String: (String, Double)]
    var unavailableSentences: Set<String> = []
    var remainder: [String: (String, Double)] = [:]
    var exclusion: [String: (String, Double)] = [:]

    func classify(sentence: String) async -> ResearchAndDevelopmentProseChoice {
        if unavailableSentences.contains(sentence) {
            return ResearchAndDevelopmentProseChoice(sentence: sentence, selected: nil, probability: nil)
        }
        if let hit = selected[sentence] {
            return ResearchAndDevelopmentProseChoice(
                sentence: sentence, selected: hit.0, probability: hit.1)
        }
        return ResearchAndDevelopmentProseChoice(
            sentence: sentence, selected: ResearchAndDevelopmentProseRole.unrelated, probability: 0.99)
    }

    func classifyRemainder(sentence: String) async -> ResearchAndDevelopmentProseChoice {
        if let hit = remainder[sentence] {
            return ResearchAndDevelopmentProseChoice(
                sentence: sentence, selected: hit.0, probability: hit.1)
        }
        return ResearchAndDevelopmentProseChoice(
            sentence: sentence, selected: ResearchAndDevelopmentRemainderRole.unrelated, probability: 0.99)
    }

    func classifyExclusion(sentence: String) async -> ResearchAndDevelopmentProseChoice {
        if let hit = exclusion[sentence] {
            return ResearchAndDevelopmentProseChoice(
                sentence: sentence, selected: hit.0, probability: hit.1)
        }
        return ResearchAndDevelopmentProseChoice(
            sentence: sentence, selected: ResearchAndDevelopmentExclusionRole.unrelated, probability: 0.99)
    }
}

private actor CountingProseDecider: ResearchAndDevelopmentProseDeciding {
    private(set) var calls = 0

    func classify(sentence: String) async -> ResearchAndDevelopmentProseChoice {
        calls += 1
        return ResearchAndDevelopmentProseChoice(
            sentence: sentence, selected: ResearchAndDevelopmentProseRole.unrelated, probability: 0.99)
    }

    func classifyRemainder(sentence: String) async -> ResearchAndDevelopmentProseChoice {
        calls += 1
        return ResearchAndDevelopmentProseChoice(
            sentence: sentence, selected: ResearchAndDevelopmentRemainderRole.unrelated, probability: 0.99)
    }

    func classifyExclusion(sentence: String) async -> ResearchAndDevelopmentProseChoice {
        calls += 1
        return ResearchAndDevelopmentProseChoice(
            sentence: sentence, selected: ResearchAndDevelopmentExclusionRole.unrelated, probability: 0.99)
    }
}

private struct FixedProseDecisionClient: DecisionsCompleting {
    var body: Data

    func decide(requestJSON: Data) async throws -> Data { body }
}
