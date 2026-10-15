// Shared Jev runner: consensus, fail-closed status, transport retry.
// No live Decisions API.

import Foundation
import Testing
@testable import BlueTickerCore

@Suite("JevDecision")
struct JevDecisionTests {
    private let policy = JevDecisionPolicy(
        question: "pick",
        noneOfTheseKey: JevDecision.noneOfThese,
        confidenceThreshold: nil,
        auditThreshold: 0.5)

    private let gated = JevDecisionPolicy(
        question: "pick",
        noneOfTheseKey: JevDecision.noneOfThese,
        confidenceThreshold: 0.9)

    private let options = ["r0", "r1", JevDecision.noneOfThese]

    private func sample(_ selected: String?, _ probability: Double?) -> JevChoiceAggregate.Sample {
        JevChoiceAggregate.Sample(
            selected: selected, probability: probability, options: options, model: "typesafe/jev-1.13")
    }

    @Test("unanimous selected is accepted and uses the median")
    func unanimousAccepted() {
        let result = JevDecision.evaluate(
            policy: policy,
            samples: [sample("r0", 0.27), sample("r0", 0.49), sample("r0", 0.44)],
            options: options)
        #expect(result.status == .accepted("r0"))
        #expect(result.selectedKey == "r0")
        #expect(result.aggregate.outcome == .agreed)
        #expect(result.aggregate.probability == 0.44)
        #expect(result.aggregate.isConfident)
        #expect(result.calls.count == 3)
        #expect(result.calls.allSatisfy { $0.applied && $0.selected == "r0" })
        #expect(result.warnings.isEmpty)
    }

    @Test("2-vs-1 disagreement is rejected")
    func twoVersusOneIsRejected() {
        let result = JevDecision.evaluate(
            policy: policy,
            samples: [sample("r0", 0.9), sample("r1", 0.9), sample("r0", 0.8)],
            options: options)
        #expect(result.status == .rejected)
        #expect(result.selectedKey == nil)
        #expect(result.aggregate.outcome == .disagreement)
        #expect(result.aggregate.selected == "r0")
        #expect(!result.aggregate.isConfident)
        #expect(result.warnings.contains(JevDecision.warningSampleDisagreement))
        #expect(result.calls.allSatisfy { !$0.applied })
    }

    @Test("one successful sample is insufficient")
    func oneSuccessIsRejected() {
        let result = JevDecision.evaluate(
            policy: policy,
            samples: [sample(nil, nil), sample("r0", 0.95), sample(nil, nil)],
            options: options)
        #expect(result.status == .rejected)
        #expect(result.aggregate.outcome == .insufficient)
        #expect(result.aggregate.successfulCount == 1)
        #expect(result.warnings.contains(JevDecision.warningSampleInsufficient))
        #expect(result.calls.allSatisfy { !$0.applied })
    }

    @Test("all transport / empty samples are empty (retryable)")
    func allFailedIsEmpty() {
        let result = JevDecision.evaluate(
            policy: policy,
            samples: [sample(nil, nil), sample("", 0.9), sample("   ", 0.4)],
            options: options)
        #expect(result.status == .empty)
        #expect(result.isEmpty)
        #expect(result.aggregate.outcome == .allFailed)
        #expect(result.aggregate.selected == nil)
        #expect(result.calls.allSatisfy { !$0.applied })
    }

    @Test("unanimous none_of_these is noneOfThese, not accepted")
    func unanimousNoneOfThese() {
        let result = JevDecision.evaluate(
            policy: policy,
            samples: [
                sample(JevDecision.noneOfThese, 0.92),
                sample(JevDecision.noneOfThese, 0.88),
                sample(JevDecision.noneOfThese, 0.90),
            ],
            options: options)
        #expect(result.status == .noneOfThese)
        #expect(result.selectedKey == nil)
        #expect(result.aggregate.selected == JevDecision.noneOfThese)
        #expect(result.calls.allSatisfy { $0.applied })
    }

    @Test("threshold on median rejects an otherwise unanimous pick")
    func belowThresholdIsRejected() {
        let result = JevDecision.evaluate(
            policy: gated,
            samples: [sample("r0", 0.7), sample("r0", 0.8), sample("r0", 0.6)],
            options: options)
        #expect(result.status == .rejected)
        #expect(result.aggregate.outcome == .agreed)
        #expect(result.aggregate.probability == 0.7)
        #expect(result.warnings.contains(JevDecision.warningBelowThreshold))
        #expect(result.calls.allSatisfy { !$0.applied })
    }

    @Test("unknown selected key is rejected")
    func unknownKeyIsRejected() {
        let result = JevDecision.evaluate(
            policy: policy,
            samples: [sample("r99", 0.99), sample("r99", 0.99), sample("r99", 0.99)],
            options: options)
        #expect(result.status == .rejected)
    }

    @Test("sampler runs N tasks and evaluate accepts a unanimous fake")
    func samplerUnanimous() async {
        let result = await JevDecisionSampler.decide(
            policy: policy, options: options
        ) {
            JevChoiceAggregate.Sample(
                selected: "r1", probability: 0.95, options: options, model: "typesafe/jev-1.13")
        }
        #expect(result.status == .accepted("r1"))
        #expect(result.calls.count == JevChoiceAggregate.sampleCount)
    }
}

@Suite("JevDecisionTransport")
struct JevDecisionTransportTests {
    @Test("transport failure retries then returns nil")
    func retriesThenFailsClosed() async {
        let client = CountingThrowingClient(failures: 10)
        let body = Data("{}".utf8)
        let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body, retries: 1, onFailure: "JevDecisionTests")
        #expect(data == nil)
        #expect(await client.attempts() == 2)
    }

    @Test("first success does not retry")
    func firstSuccessStops() async {
        let client = ScriptedSuccessClient(bodies: [Data("{\"ok\":1}".utf8)])
        let data = await JevDecisionTransport.decide(
            client: client, requestJSON: Data("{}".utf8), retries: 2, onFailure: "JevDecisionTests")
        #expect(data == Data("{\"ok\":1}".utf8))
        #expect(await client.attempts() == 1)
    }

    @Test("retry recovers a later success")
    func retryRecovers() async {
        let client = FailThenSucceedClient(failCount: 1, body: Data("{\"ok\":2}".utf8))
        let data = await JevDecisionTransport.decide(
            client: client, requestJSON: Data("{}".utf8), retries: 1, onFailure: "JevDecisionTests")
        #expect(data == Data("{\"ok\":2}".utf8))
        #expect(await client.attempts() == 2)
    }
}

private actor CountingThrowingClient: DecisionsCompleting {
    private var hits = 0

    init(failures: Int) { _ = failures }

    func decide(requestJSON: Data) async throws -> Data {
        hits += 1
        throw ChatCompletionError.invalidURL
    }

    func attempts() -> Int { hits }
}

private actor ScriptedSuccessClient: DecisionsCompleting {
    var bodies: [Data]
    private var hits = 0

    init(bodies: [Data]) { self.bodies = bodies }

    func decide(requestJSON: Data) async throws -> Data {
        hits += 1
        guard !bodies.isEmpty else { throw ChatCompletionError.emptyContent }
        return bodies.removeFirst()
    }

    func attempts() -> Int { hits }
}

private actor FailThenSucceedClient: DecisionsCompleting {
    var failCount: Int
    var body: Data
    private var hits = 0

    init(failCount: Int, body: Data) {
        self.failCount = failCount
        self.body = body
    }

    func decide(requestJSON: Data) async throws -> Data {
        hits += 1
        if hits <= failCount { throw ChatCompletionError.httpError(503, "") }
        return body
    }

    func attempts() -> Int { hits }
}
