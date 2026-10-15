// Shared Jev Decisions framework.
// Deterministic tag extraction first. For what has no tag, Jev only SELECTS an
// existing candidate (row / column / sentence / table) or CLASSIFIES an existing
// row / sentence. It never generates a value and never derives one as
// "disclosed total minus extracted sum".
// Shared: candidate presentation, OpenRouter Decisions (`typesafe/jev-1.13`),
// N-sample consensus (`JevChoiceAggregate`), fail-closed result, audit calls,
// transport-failure retry.
// Per-axis policy (hard-coded, passed in): prompt text, candidate builder,
// deterministic gates (caller), confidence threshold, sample count / consensus.

import Foundation

struct JevSamplingRule: Equatable, Sendable {
    var sampleCount: Int
    var minSuccessfulSamples: Int
    /// Every successful sample must share the same `selected`.
    var requireUnanimousSuccessful: Bool

    /// Matches `JevChoiceAggregate`: 3 samples, ≥2 successful, all agree.
    static let consensus3 = JevSamplingRule(
        sampleCount: JevChoiceAggregate.sampleCount,
        minSuccessfulSamples: JevChoiceAggregate.minSuccessfulSamples,
        requireUnanimousSuccessful: true)
}

/// Per-axis / feature knobs. Prompt text and candidate lists are built by the
/// site and passed into `JevDecisionRequest` / the sampler; gates after Jev
/// stay in the site and Jev cannot override them.
struct JevDecisionPolicy: Equatable, Sendable {
    var kind: JevDecisionKind
    var question: String
    var model: String
    /// Extra SELECT option (`none_of_these`). Nil for a closed classify set.
    var noneOfTheseKey: String?
    /// Gate on the median probability of agreeing samples. Nil = consensus only.
    var confidenceThreshold: Double?
    /// Written to `SegmentNoteJevAuditPayload.threshold` even when the public
    /// gate is consensus-only.
    var auditThreshold: Double
    var sampling: JevSamplingRule
    /// Extra attempts after the first transport failure of one sample.
    var transportRetries: Int

    static let defaultTransportRetries = 1

    init(
        kind: JevDecisionKind = .select,
        question: String,
        model: String = Api.openrouterDecisionsModel,
        noneOfTheseKey: String? = JevDecision.noneOfThese,
        confidenceThreshold: Double?,
        auditThreshold: Double? = nil,
        sampling: JevSamplingRule = .consensus3,
        transportRetries: Int = defaultTransportRetries
    ) {
        self.kind = kind
        self.question = question
        self.model = model
        self.noneOfTheseKey = noneOfTheseKey
        self.confidenceThreshold = confidenceThreshold
        self.auditThreshold = auditThreshold
            ?? confidenceThreshold
            ?? SegmentNoteDecision.applyProbabilityThreshold
        self.sampling = sampling
        self.transportRetries = transportRetries
    }
}

/// One existing label presented to Jev. The value itself is never in the key.
struct JevPresentedCandidate: Equatable, Sendable {
    var key: String
    var criterion: String
}

enum JevDecisionKind: String, Equatable, Sendable {
    /// Pick one existing candidate key (column / row / table / sentence).
    case select
    /// Label an existing row or sentence with a closed set of roles.
    case classify
}

enum JevDecisionStatus: Equatable, Sendable {
    case accepted(String)
    case noneOfThese
    case rejected
    case empty
}

struct JevDecisionResult: Equatable, Sendable {
    var status: JevDecisionStatus
    var aggregate: JevChoiceAggregate.Result
    var warnings: [String]
    var calls: [SegmentNoteJevCallPayload]

    var selectedKey: String? {
        if case .accepted(let key) = status { return key }
        return nil
    }

    var isEmpty: Bool { status == .empty }
}

enum JevDecision {
    static let noneOfThese = "none_of_these"
    static let warningSampleDisagreement = "jev_column_sample_disagreement"
    static let warningSampleInsufficient = "jev_column_sample_insufficient"
    static let warningBelowThreshold = "jev_confidence_below_threshold"

    /// Map samples + policy to a fail-closed status. Unknown keys, disagreement,
    /// insufficient success, missing probability (when a threshold is set), and
    /// `none_of_these` (when that is not an accepted classify role) do not yield
    /// `.accepted`.
    static func evaluate(
        policy: JevDecisionPolicy,
        samples: [JevChoiceAggregate.Sample],
        options: [String],
        sentences: [String] = []
    ) -> JevDecisionResult {
        let aggregate = JevChoiceAggregate.combine(samples)
        var warnings: [String] = []
        switch aggregate.outcome {
        case .disagreement:
            warnings.append(warningSampleDisagreement)
        case .insufficient:
            warnings.append(warningSampleInsufficient)
        case .allFailed, .agreed:
            break
        }

        let status: JevDecisionStatus
        if aggregate.outcome == .allFailed {
            status = .empty
        } else if !aggregate.isConfident {
            status = .rejected
        } else if let selected = aggregate.selected {
            if !meetsThreshold(policy.confidenceThreshold, aggregate.probability) {
                warnings.append(warningBelowThreshold)
                status = .rejected
            } else if let none = policy.noneOfTheseKey, selected == none {
                status = .noneOfThese
            } else if options.contains(selected) {
                status = .accepted(selected)
            } else {
                status = .rejected
            }
        } else {
            status = .rejected
        }

        let appliedKey: String?
        switch status {
        case .accepted(let key):
            appliedKey = key
        case .noneOfThese:
            appliedKey = policy.noneOfTheseKey
        case .rejected, .empty:
            appliedKey = nil
        }
        let calls = auditCalls(
            question: policy.question, samples: samples, options: options,
            sentences: sentences, appliedSelected: appliedKey)
        return JevDecisionResult(
            status: status, aggregate: aggregate, warnings: warnings, calls: calls)
    }

    static func meetsThreshold(_ threshold: Double?, _ probability: Double?) -> Bool {
        guard let threshold else { return true }
        guard let probability, probability.isFinite, (0.0...1.0).contains(probability) else {
            return false
        }
        return probability >= threshold
    }

    static func auditCalls(
        question: String,
        samples: [JevChoiceAggregate.Sample],
        options: [String],
        sentences: [String] = [],
        appliedSelected: String? = nil
    ) -> [SegmentNoteJevCallPayload] {
        samples.map { sample in
            let sampleOptions = sample.options.isEmpty ? options : sample.options
            let sampleSentences = sample.sentences.isEmpty ? sentences : sample.sentences
            return SegmentNoteJevCallPayload(
                question: question,
                options: sampleOptions,
                selected: sample.selected,
                probability: sample.probability,
                sentences: sampleSentences,
                applied: appliedSelected != nil && sample.selected == appliedSelected)
        }
    }
}

enum JevDecisionSampler {
    static func collect<T: Sendable>(
        count: Int = JevChoiceAggregate.sampleCount,
        _ body: @Sendable @escaping () async -> T
    ) async -> [T] {
        await collect(count: count) { _ in await body() }
    }

    static func collect<T: Sendable>(
        count: Int = JevChoiceAggregate.sampleCount,
        _ body: @Sendable @escaping (Int) async -> T
    ) async -> [T] {
        await withTaskGroup(of: (Int, T).self) { group in
            for index in 0..<count {
                group.addTask { (index, await body(index)) }
            }
            var slots: [T?] = Array(repeating: nil, count: count)
            for await (index, sample) in group { slots[index] = sample }
            return slots.map { $0! }
        }
    }

    static func decide(
        policy: JevDecisionPolicy,
        options: [String],
        sentences: [String] = [],
        sample: @Sendable @escaping () async -> JevChoiceAggregate.Sample
    ) async -> JevDecisionResult {
        let samples = await collect(count: policy.sampling.sampleCount, sample)
        return JevDecision.evaluate(
            policy: policy, samples: samples, options: options, sentences: sentences)
    }
}

/// POST Decisions with a bounded retry on thrown transport errors. Parse
/// failures are not retried here — the caller treats a missing Choice as a
/// failed sample.
enum JevDecisionTransport {
    static func decide(
        client: any DecisionsCompleting,
        requestJSON: Data,
        retries: Int = JevDecisionPolicy.defaultTransportRetries,
        onFailure: String
    ) async -> Data? {
        var lastError: (any Error)?
        for _ in 0...max(retries, 0) {
            do {
                return try await client.decide(requestJSON: requestJSON)
            } catch {
                lastError = error
            }
        }
        if let lastError {
            printError("\(onFailure): \(lastError)\n")
        }
        return nil
    }
}

enum JevDecisionRequest {
    static func json(
        model: String,
        question: String,
        instructions: String,
        candidates: [JevPresentedCandidate],
        state: [String: Any]
    ) -> Data? {
        var criteria: [String: String] = [:]
        for candidate in candidates {
            criteria[candidate.key] = candidate.criterion
        }
        let questions: [String: Any] = [
            question: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: instructions, criteria: criteria),
        ]
        return OpenRouterDecisionsCodec.requestJSON(
            model: model, state: state, questions: questions)
    }

    static func json(
        policy: JevDecisionPolicy,
        instructions: String,
        candidates: [JevPresentedCandidate],
        state: [String: Any]
    ) -> Data? {
        json(
            model: policy.model, question: policy.question,
            instructions: instructions, candidates: candidates, state: state)
    }
}
