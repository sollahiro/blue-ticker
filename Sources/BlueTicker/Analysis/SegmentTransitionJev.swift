// 年をまたぐセグメントつなぎの残り判断。閉じた Choice {connect, break, needs_review}。
// 低確信は needs_review。connect は閾値を満たした合意だけ。値は発明しない。

import Foundation

protocol SegmentTransitionDeciding: Sendable {
    func chooseTransition(
        oldLabel: String, newLabel: String, oldAmount: Double?, newPriorAmount: Double?,
        fyEnd: String
    ) async -> JevChoiceAggregate.Sample
}

enum SegmentTransitionJev {
    static let question = "segment_transition"
    static let options = [
        segmentTransitionDecisionConnect,
        segmentTransitionDecisionBreak,
        segmentTransitionDecisionNeedsReview,
    ]
    static let jevPolicy = JevDecisionPolicy(
        kind: .classify,
        question: question,
        noneOfTheseKey: nil,
        confidenceThreshold: SegmentNoteDecision.applyProbabilityThreshold)

    static func decide(
        oldLabel: String, newLabel: String, oldAmount: Double?, newPriorAmount: Double?,
        fyEnd: String, decider: any SegmentTransitionDeciding
    ) async -> (decision: String, confident: Bool) {
        let result = await JevDecisionSampler.decide(policy: jevPolicy, options: options) {
            await decider.chooseTransition(
                oldLabel: oldLabel, newLabel: newLabel, oldAmount: oldAmount,
                newPriorAmount: newPriorAmount, fyEnd: fyEnd)
        }
        switch result.status {
        case .accepted(let key) where options.contains(key):
            return (key, true)
        default:
            return (segmentTransitionDecisionNeedsReview, false)
        }
    }
}

struct OpenRouterSegmentTransitionDecider: SegmentTransitionDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    func chooseTransition(
        oldLabel: String, newLabel: String, oldAmount: Double?, newPriorAmount: Double?,
        fyEnd: String
    ) async -> JevChoiceAggregate.Sample {
        let unavailable = JevChoiceAggregate.Sample(
            selected: nil, probability: nil, options: SegmentTransitionJev.options, model: model)
        let presented = SegmentTransitionJev.options.map {
            JevPresentedCandidate(key: $0, criterion: $0)
        }
        let state: [String: Any] = [
            "fy_end": fyEnd,
            "old_label": oldLabel,
            "new_label": newLabel,
            "old_amount_yen": oldAmount.map(breakdownJSONAmount) ?? NSNull(),
            "new_prior_amount_yen": newPriorAmount.map(breakdownJSONAmount) ?? NSNull(),
        ]
        let instructions = """
            Two adjacent-year reportable segments in a Japanese annual report may be the same \
            line (connect), a reorganization (break), or undecidable (needs_review). \
            Closed set only: connect, break, needs_review. Do not invent amounts. \
            If the labels differ and only the amounts match, prefer needs_review unless the \
            prior-year restatement clearly shows a rename.
            """
        guard let body = JevDecisionRequest.json(
            model: model, question: SegmentTransitionJev.question,
            instructions: instructions, candidates: presented, state: state)
        else { return unavailable }
        guard let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body,
            retries: SegmentTransitionJev.jevPolicy.transportRetries,
            onFailure: "SegmentTransitionJev: Jev呼び出し失敗")
        else { return unavailable }
        guard let choice = OpenRouterDecisionsCodec.answers(from: data)[
            SegmentTransitionJev.question]?.choice
        else { return unavailable }
        return JevChoiceAggregate.Sample(
            selected: choice.selected,
            probability: OpenRouterSegmentNoteDecider.selectedProbability(
                selected: choice.selected, probabilities: choice.probabilities),
            probabilities: choice.probabilities, options: SegmentTransitionJev.options, model: model)
    }
}
