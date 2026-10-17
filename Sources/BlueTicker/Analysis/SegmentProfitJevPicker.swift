// 事業別内訳 profit の fail-closed Jev フォールバック。
// `BreakdownNormalizer.segmentProfitTag`（表の行名・差異調整・標準タグ一覧）で利益タグが
// 決まらないときだけ、セグメント表に当期のセグメント値が載っている既存タグの中から、
// 会社がセグメント利益（業績評価の利益）としている行を1つ選ばせる。会社拡張タグを
// 一覧に足していかない（9201 日本航空の財務・法人所得税前利益など）。
// 値はタグの開示値そのもの。3 回一致・0.9 に加え、報告セグメント計があれば和との整合（コード）を
// 求める。Jev は整合しない行を採らせられない。
// キーが無い・合意できない・整合しないときは profit を付けない（null のまま）。

import Foundation

struct SegmentProfitCandidate: Equatable, Sendable {
    var key: String
    var tag: String
    /// セグメント表の行名（無ければタクソノミの標準ラベル、それも無ければタグ名）。
    var label: String
    /// member の表示名 → 百万円。
    var memberValuesMillionYen: [String: Double]
    var reportableTotalMillionYen: Double?
    var entityTotalMillionYen: Double?
}

protocol SegmentProfitDeciding: Sendable {
    func chooseSegmentProfit(
        candidates: [SegmentProfitCandidate], salesLabel: String, docID: String
    ) async -> JevChoiceAggregate.Sample
}

enum SegmentProfitJevPicker {
    static let question = "segment_profit_row"
    static let axis = "product_service_profit"
    /// 3 回一致かつ中央値 0.9 以上（他の Jev 経路の公開閾値と同じ）。報告セグメント計との整合は
    /// その上の追加の確認（資産・減価償却費なども計と整合するので、整合だけでは採らない）。
    static let jevPolicy = JevDecisionPolicy(
        question: question,
        confidenceThreshold: SegmentNoteDecision.applyProbabilityThreshold)

    struct PickResult: Equatable, Sendable {
        var tag: String?
        var audit: SegmentNoteJevAuditPayload
    }

    /// 当期のセグメント member 値が1つでも 0 でないタグ（売上タグ自身は除く）。
    static func candidates(
        facts: [BreakdownFact], rowLabelsByTag: [String: Set<String>],
        memberLabels: [String: String], amountTag: String
    ) -> [SegmentProfitCandidate] {
        let standard = XBRLUtils.loadStandardTaxonomyLabels()
        let tags = Set(facts.map(\.tag)).subtracting([amountTag]).sorted()
        var out: [SegmentProfitCandidate] = []
        for tag in tags {
            let values = BreakdownNormalizer.currentSegmentMemberValues(facts: facts, tag: tag)
            guard values.values.contains(where: { $0 != 0 }) else { continue }
            let rowLabel = (rowLabelsByTag[tag] ?? []).sorted().first
            let label = rowLabel ?? standard[tag] ?? tag
            var shown: [String: Double] = [:]
            for (member, value) in values {
                shown[memberLabels[member] ?? member] = value / Financial.millionYen
            }
            out.append(SegmentProfitCandidate(
                key: "t\(out.count)", tag: tag, label: label,
                memberValuesMillionYen: shown,
                reportableTotalMillionYen: values["ReportableSegmentsMember"].map { $0 / Financial.millionYen },
                entityTotalMillionYen: BreakdownNormalizer.currentEntityTotalValue(facts: facts, tag: tag)
                    .map { $0 / Financial.millionYen }))
        }
        return out
    }

    /// 報告セグメントの和が「報告セグメント計」と一致するか（丸めはセグメント数 × 1百万円）。
    /// 計が無いときは nil（裏取りなし）。
    static func reportableTotalAgrees(facts: [BreakdownFact], tag: String) -> Bool? {
        let values = BreakdownNormalizer.currentSegmentMemberValues(facts: facts, tag: tag)
        guard let total = values["ReportableSegmentsMember"] else { return nil }
        let reportable = values.filter { member, _ in
            !Xbrl.segmentSubtotalMemberNames.contains(member)
                && !BreakdownMemberRoles.isReconciling(member)
                && !Xbrl.segmentOtherBusinessMemberNames.contains(member)
        }
        guard !reportable.isEmpty else { return nil }
        let sum = reportable.values.reduce(0, +)
        return abs(sum - total) <= Double(reportable.count) * Financial.millionYen
    }

    static func pick(
        candidates: [SegmentProfitCandidate], facts: [BreakdownFact], salesLabel: String,
        decider: any SegmentProfitDeciding, docID: String
    ) async -> PickResult {
        let options = candidates.map(\.key) + [JevDecision.noneOfThese]
        guard !candidates.isEmpty else {
            return PickResult(tag: nil, audit: audit(
                docID: docID, model: "", applied: false,
                sentences: ["segment_profit_jev=no_candidates"], calls: []))
        }
        let result = await JevDecisionSampler.decide(policy: jevPolicy, options: options) {
            await decider.chooseSegmentProfit(
                candidates: candidates, salesLabel: salesLabel, docID: docID)
        }
        var sentences = [
            "segment_profit_jev_samples=\(result.calls.count) \(result.aggregate.outcome.rawValue)",
        ]
        guard let key = result.selectedKey,
              let chosen = candidates.first(where: { $0.key == key })
        else {
            sentences.append(result.status == .noneOfThese
                ? "segment_profit_jev=none_of_these" : "segment_profit_jev=fail_closed")
            return PickResult(tag: nil, audit: audit(
                docID: docID, model: result.aggregate.model, applied: false,
                sentences: sentences, calls: result.calls))
        }
        if reportableTotalAgrees(facts: facts, tag: chosen.tag) == false {
            sentences.append("segment_profit_jev=reportable_total_mismatch tag=\(chosen.tag)")
            return PickResult(tag: nil, audit: audit(
                docID: docID, model: result.aggregate.model, applied: false,
                sentences: sentences, calls: result.calls))
        }
        sentences.append("segment_profit_jev=accepted tag=\(chosen.tag)")
        return PickResult(tag: chosen.tag, audit: audit(
            docID: docID, model: result.aggregate.model, applied: true,
            sentences: sentences, calls: result.calls))
    }

    private static func audit(
        docID: String, model: String, applied: Bool, sentences: [String],
        calls: [SegmentNoteJevCallPayload]
    ) -> SegmentNoteJevAuditPayload {
        SegmentNoteJevAuditPayload(
            code: "", docID: docID, axis: axis,
            model: model.isEmpty ? Api.openrouterDecisionsModel : model,
            threshold: jevPolicy.auditThreshold,
            applied: applied, needsReview: false, sentences: sentences,
            calls: calls, withheldReason: applied ? nil : sentences.last,
            decisionSource: applied ? "jev_segment_profit_row" : nil)
    }
}

struct OpenRouterSegmentProfitDecider: SegmentProfitDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    func chooseSegmentProfit(
        candidates: [SegmentProfitCandidate], salesLabel: String, docID: String
    ) async -> JevChoiceAggregate.Sample {
        let options = candidates.map(\.key) + [JevDecision.noneOfThese]
        let unavailable = JevChoiceAggregate.Sample(
            selected: nil, probability: nil, options: options, model: model)
        guard let body = Self.requestJSON(
            model: model, candidates: candidates, salesLabel: salesLabel, docID: docID)
        else { return unavailable }
        guard let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body,
            retries: SegmentProfitJevPicker.jevPolicy.transportRetries,
            onFailure: "SegmentProfitJevPicker: Jev呼び出し失敗")
        else { return unavailable }
        guard let choice = OpenRouterDecisionsCodec.answers(from: data)[
            SegmentProfitJevPicker.question]?.choice
        else { return unavailable }
        return JevChoiceAggregate.Sample(
            selected: choice.selected,
            probability: OpenRouterSegmentNoteDecider.selectedProbability(
                selected: choice.selected, probabilities: choice.probabilities),
            probabilities: choice.probabilities, options: options, model: model)
    }

    static func requestJSON(
        model: String, candidates: [SegmentProfitCandidate], salesLabel: String, docID: String
    ) -> Data? {
        var presented: [JevPresentedCandidate] = candidates.map { candidate in
            JevPresentedCandidate(
                key: candidate.key,
                criterion: "row=\(candidate.label); tag=\(candidate.tag)")
        }
        presented.append(JevPresentedCandidate(
            key: JevDecision.noneOfThese,
            criterion: """
                None of these rows is the profit measure the company reports per segment \
                (the segment note discloses no segment profit or loss).
                """))
        let state: [String: Any] = [
            "doc_id": docID,
            "segment_revenue_row": salesLabel,
            "rows": candidates.map { candidate -> [String: Any] in
                var row: [String: Any] = [
                    "key": candidate.key,
                    "row_label": candidate.label,
                    "tag": candidate.tag,
                    "segments_million_yen": candidate.memberValuesMillionYen,
                ]
                if let total = candidate.reportableTotalMillionYen {
                    row["reportable_segments_total_million_yen"] = total
                }
                if let total = candidate.entityTotalMillionYen {
                    row["consolidated_million_yen"] = total
                }
                return row
            },
        ]
        let instructions = """
            The state lists the rows of the segment information table (セグメント情報) of a \
            Japanese annual securities report (有価証券報告書, doc \(docID)) that carry \
            current-year values per reportable segment. Pick the ONE row that is the company's \
            segment profit or loss — the profit measure the chief operating decision maker uses \
            to assess segment performance (セグメント利益又は損失; it may be named 営業利益, \
            事業利益, 財務・法人所得税前利益 (EBIT), 経常利益, 税引前利益 or similar). Do not pick \
            revenue, inter-segment revenue, assets, depreciation, interest income or expense, \
            equity-method income, capital expenditure, or any other non-profit measure. Do not \
            add or compute amounts. If no row is the segment profit measure, choose none_of_these.
            """
        return JevDecisionRequest.json(
            model: model, question: SegmentProfitJevPicker.question,
            instructions: instructions, candidates: presented, state: state)
    }
}
