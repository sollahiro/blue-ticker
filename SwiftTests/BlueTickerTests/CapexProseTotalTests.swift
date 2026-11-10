// SPEC_ORACLE: 設備投資本文総額。金額はコードが円へ換算し、Jev は文の分類だけ。
// ライブの Decisions API は呼ばない。セグメント別セルは埋めない。

import Foundation
import Testing

@testable import BlueTickerCore

private struct ScriptedCapexDecider: CapexProseDeciding {
    var selected: [String: (String, Double)]
    var remainder: (String, Double)?
    var exclusion: (String, Double)?
    var unavailable = false

    func classify(sentence: String) async -> CapexProseChoice {
        if unavailable {
            return CapexProseChoice(sentence: sentence, selected: nil, probability: nil)
        }
        let match = selected.first { sentence.contains($0.key) }
        return CapexProseChoice(
            sentence: sentence, selected: match?.value.0, probability: match?.value.1)
    }

    func classifyRemainder(sentence: String) async -> CapexProseChoice {
        if unavailable {
            return CapexProseChoice(sentence: sentence, selected: nil, probability: nil)
        }
        guard let remainder else {
            return CapexProseChoice(sentence: sentence, selected: CapexRemainderRole.unrelated, probability: 0.99)
        }
        return CapexProseChoice(sentence: sentence, selected: remainder.0, probability: remainder.1)
    }

    func classifyExclusion(sentence: String) async -> CapexProseChoice {
        if unavailable {
            return CapexProseChoice(sentence: sentence, selected: nil, probability: nil)
        }
        guard let exclusion else {
            return CapexProseChoice(sentence: sentence, selected: CapexExclusionRole.unrelated, probability: 0.99)
        }
        return CapexProseChoice(sentence: sentence, selected: exclusion.0, probability: exclusion.1)
    }
}

@Suite struct CapexProseTotalTests {
    @Test func convertsOkuAndDropsPartialAndMultiAmount() {
        let oku = CapexProseTotalDecision.candidates(
            in: "当連結会計年度の設備投資は1,234億円であります。")
        #expect(oku.map(\.yen) == [123_400_000_000])
        #expect(
            CapexProseTotalDecision.candidates(
                in: "ヘルスケア事業の設備投資は10百万円、イメージングは20百万円であります。").isEmpty)
    }

    /// 総額判定の基準文が、「総額」の語が無い取得文(「…を取得いたしました」)と、一部を示す語(「うち」「主な」
    /// 「〜事業において」)の両方を、Jev に明示している。8928 S100WQZC の確信度は旧文面で 0.84〜0.87(しきい値
    /// 0.9 未満で採用されない)、新文面で 0.99 だった。実際の判定は Jev なので、ここでは文面だけを固定する。
    @Test func totalCriteriaNamesAcquisitionSentencesAndPartialMarkers() throws {
        let body = try #require(
            OpenRouterCapexProseDecider.requestJSON(model: "m", sentence: "文"))
        let json = try #require(String(data: body, encoding: .utf8))
        #expect(json.contains("取得いたしました"))
        #expect(json.contains("総額」の語が無くても"))
        #expect(json.contains("うち"))
        #expect(json.contains("特定の事業"))
    }

    @Test func appliesCompanyTotalToOverviewCellOnly() async throws {
        let text = "当連結会計年度の設備投資は4,409百万円であります。"
        let applied = await CapexProseTotalDecision.decide(
            plainText: text,
            decider: ScriptedCapexDecider(selected: [
                text.trimmingCharacters(in: CharacterSet(charactersIn: "。")): (
                    CapexProseRole.currentCompanyTotal, 0.95)
            ]))
        guard case .applied(let total) = applied else {
            Issue.record("expected an applied total")
            return
        }
        #expect(total.yen == 4_409_000_000)
        let snapshot = CapexProseTotalDecision.snapshotFromCompanyTotal(total)
        #expect(snapshot.axis == breakdownAxisCapex)
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.segmentAssets == nil)
        #expect(snapshot.flow == nil)
        #expect(snapshot.capitalExpendituresOverview?.denominator == 4_409_000_000)
        #expect(snapshot.sourceKind == breakdownSourceCapexProse)
        let json = snapshot.jsonObject()
        #expect(json["amount"] == nil)
        #expect(json[capexCellSegmentAssets] is NSNull)
        let overview = try #require(json[capexCellCapitalExpendituresOverview] as? [String: Any])
        #expect(overview["denominator"] as? Double == 4_409_000_000)
    }

    @Test func fillsReconcilingRemainderAndLeavesSegmentCellsUntouched() async {
        let payload = BreakdownSnapshotPayload(
            axis: breakdownAxisCapex, denominator: 0, denominatorTag: "",
            rows: [
                BreakdownRowPayload(
                    labelRaw: "SegAMember", label: "A", amount: 0, profit: nil, rowKind: "segment",
                    flow: 80_000_000)
            ],
            sourceKind: breakdownSourceXbrlFacts, needsReview: true, warnings: [
                "capex_flow_segment_sum_far_from_total"
            ],
            flowMetric: capexFlowMetricCapitalExpenditures, segmentAssets: nil,
            flow: CapexMetricTotalsPayload(
                denominator: 100_000_000, denominatorTag: "CapitalExpendituresIFRS"),
            capitalExpendituresOverview: nil)
        let text = "全社資産への設備投資は20百万円であります。"
        let filled = await CapexProseTotalDecision.fillShortfall(
            payload: payload, cell: .flow, plainText: text,
            decider: ScriptedCapexDecider(
                selected: [:],
                remainder: (CapexRemainderRole.unallocatedRemainder, 0.95)))
        #expect(filled.payload.rows.contains { $0.rowKind == "reconciling" && $0.flow == 20_000_000 })
        #expect(filled.payload.rows.first { $0.rowKind == "segment" }?.flow == 80_000_000)
        #expect(filled.payload.warnings.contains(breakdownWarningCapexProseRemainder))
        #expect(filled.payload.sourceKind == breakdownSourceXbrlFacts)
        #expect(filled.audit?.applied == true)
    }

    @Test func doesNotFillWhenResponseIsMissing() async {
        let decided = await CapexProseTotalDecision.decide(
            plainText: "設備投資は4,409百万円であります。",
            decider: ScriptedCapexDecider(selected: [:], unavailable: true))
        #expect(decided == .unavailable)
    }

    /// 穴吹興産 S100WQZC: 取得いたしましたの1文は Jev 不達でも総額。
    /// source: code=8928 fy_end=2025-06-30 doc_id=S100WQZC page=31 field=capex
    @Test func soleAcquisitionSentenceIsCompanyTotalWithoutJev() async {
        let decided = await CapexProseTotalDecision.decide(
            plainText: "太陽光発電設備、倉庫及び高圧受電設備等、2,180,870千円を取得いたしました。",
            decider: ScriptedCapexDecider(selected: [:], unavailable: true))
        guard case .applied(let total) = decided else {
            Issue.record("sole acquisition sentence should apply without Jev")
            return
        }
        #expect(total.yen == 2_180_870_000)
        let snapshot = CapexProseTotalDecision.snapshotFromCompanyTotal(total)
        #expect(snapshot.capitalExpendituresOverview?.denominator == 2_180_870_000)
        #expect(snapshot.sourceKind == breakdownSourceCapexProse)
    }

    /// キングジム: 万円の総額文が工場の一部と並んでも総額を採る。Jev は呼ばない。
    /// source: code=7962 fy_end=2026-06-20 doc_id=S100Z29T page=23 field=capex
    @Test func uniqueSogakuOkuManIsCompanyTotalWithoutJev() async {
        let text = """
            当連結会計年度において、総額６億8,006万円の設備投資を実施いたしました。\
            その主なものは、工場生産設備の３億5,256万円であります。
            """
        let decided = await CapexProseTotalDecision.decide(
            plainText: text,
            decider: ScriptedCapexDecider(selected: [:], unavailable: true))
        guard case .applied(let total) = decided else {
            Issue.record("unique 総額 sentence should apply without Jev")
            return
        }
        #expect(total.yen == 680_060_000)
    }

    /// 7050: 金額が無い「設備投資はありません」から 0 円は作らない（0 と null は未確定）。
    @Test func noCapitalExpendituresSentenceDoesNotInventZero() async {
        let text = "当連結会計年度における設備投資はありません。"
        #expect(CapexProseTotalDecision.mentionsNoCurrentCapitalExpenditures(text))
        let decided = await CapexProseTotalDecision.decide(
            plainText: text,
            decider: ScriptedCapexDecider(selected: [:], unavailable: true))
        #expect(decided == .notApplied)
    }

    @Test func discardsPartialAmountAndSegmentAmount() async {
        let partial = await CapexProseTotalDecision.decide(
            plainText: "ヘルスケアの設備投資は10百万円であります。",
            decider: ScriptedCapexDecider(selected: [
                "ヘルスケアの設備投資は10百万円であります": (CapexProseRole.partialAmount, 0.99)
            ]))
        #expect(partial == .notApplied)

        let payload = BreakdownSnapshotPayload(
            axis: breakdownAxisCapex, denominator: 0, denominatorTag: "",
            rows: [
                BreakdownRowPayload(
                    labelRaw: "SegAMember", label: "A", amount: 0, profit: nil, rowKind: "segment",
                    flow: 80_000_000)
            ],
            sourceKind: breakdownSourceXbrlFacts, needsReview: true, warnings: [],
            flowMetric: capexFlowMetricCapitalExpenditures,
            flow: CapexMetricTotalsPayload(denominator: 100_000_000, denominatorTag: "CapitalExpendituresIFRS"))
        let skipped = await CapexProseTotalDecision.fillShortfall(
            payload: payload, cell: .flow, plainText: "ヘルスケアの設備投資は20百万円であります。",
            decider: ScriptedCapexDecider(
                selected: [:], remainder: (CapexRemainderRole.segmentAmount, 0.99)))
        #expect(skipped.payload.rows.count == 1)
        #expect(skipped.audit == nil)
    }

    @Test func doesNotInventInstantAssetsFromOverviewCompanyTotal() {
        let payload = BreakdownSnapshotPayload(
            axis: breakdownAxisCapex, denominator: 0, denominatorTag: "",
            rows: [], sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [],
            flowMetric: capexFlowMetricCapitalExpenditures, segmentAssets: nil,
            flow: CapexMetricTotalsPayload(
                denominator: 10_000_000, denominatorTag: "CapitalExpendituresIFRS"),
            capitalExpendituresOverview: nil)
        let filled = CapexProseTotalDecision.applyCompanyTotal(
            to: payload,
            total: CapexProseTotal(
                yen: 50_000_000, warnings: [],
                audit: SegmentNoteJevAuditPayload(
                    code: "", docID: "", axis: breakdownAxisCapex, model: "test",
                    threshold: 0.9, applied: true, needsReview: false, sentences: [],
                    calls: [])))
        #expect(filled.segmentAssets == nil)
        #expect(filled.flow?.denominator == 10_000_000)
        #expect(filled.capitalExpendituresOverview?.denominator == 50_000_000)
        #expect(filled.sourceKind == breakdownSourceXbrlFacts)
    }

    @Test func fillsNegativeReconcilingExclusionOnOverview() async {
        let payload = BreakdownSnapshotPayload(
            axis: breakdownAxisCapex, denominator: 0, denominatorTag: "",
            rows: [
                BreakdownRowPayload(
                    labelRaw: "SegAMember", label: "A", amount: 0, profit: nil,
                    rowKind: "segment", capitalExpendituresOverview: 120_000_000)
            ],
            sourceKind: breakdownSourceXbrlFacts, needsReview: true, warnings: [
                "capital_expenditures_overview_subtotal_differs_from_segment_sum"
            ],
            capitalExpendituresOverview: CapexMetricTotalsPayload(
                denominator: 100_000_000,
                denominatorTag: "CapitalExpendituresOverviewOfCapitalExpendituresEtc"))
        let text = "設備投資は100百万円であり、このほか20百万円の研究開発用設備を取得しております。"
        let filled = await CapexProseTotalDecision.fillExclusion(
            payload: payload, cell: .overview, plainText: text,
            decider: ScriptedCapexDecider(
                selected: [:],
                exclusion: (CapexExclusionRole.excludedFromTotal, 0.95)))
        #expect(
            filled.payload.rows.contains {
                $0.rowKind == "reconciling" && $0.capitalExpendituresOverview == -20_000_000
            })
        #expect(filled.payload.rows.first { $0.rowKind == "segment" }?.capitalExpendituresOverview
            == 120_000_000)
        #expect(filled.payload.warnings.contains(breakdownWarningCapexProseExclusion))
        #expect(filled.audit?.applied == true)
    }
}
