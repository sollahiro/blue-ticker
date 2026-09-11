import Foundation
import Testing

@testable import HAPISConsumer

@Suite
struct HAPISOriginGateTests {
    @Test func prefetchSpacesRequestsInteractiveDoesNot() async throws {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
        let sleeps = SleepLog()
        let gate = HAPISOriginGate(
            now: { clock.now },
            sleep: { seconds in
                sleeps.append(seconds)
                clock.advance(seconds)
            }
        )

        try await gate.waitTurn(.interactive)
        try await gate.waitTurn(.interactive)
        #expect(sleeps.values.isEmpty)

        try await gate.waitTurn(.prefetch)
        try await gate.waitTurn(.prefetch)
        #expect(sleeps.values.count == 1)
        #expect(sleeps.values[0] == HAPISOriginGate.prefetchSpacing)
    }

    @Test func rateLimitBlocksInteractiveAndPrefetch() async throws {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
        let sleeps = SleepLog()
        let gate = HAPISOriginGate(
            now: { clock.now },
            sleep: { seconds in
                sleeps.append(seconds)
                clock.advance(seconds)
            }
        )

        await gate.noteRateLimited(retryAfterSeconds: 30)
        #expect(await gate.isCoolingDown())

        try await gate.waitTurn(.interactive)
        #expect(sleeps.values == [30])
        #expect(await gate.isCoolingDown() == false)
    }

    @Test func waitTurnRechecksCooldownSetDuringSleep() async throws {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
        let pause = FirstSleepPause()
        let gate = HAPISOriginGate(
            now: { clock.now },
            sleep: { seconds in
                await pause.sleep(seconds, clock: clock)
            }
        )

        try await gate.waitTurn(.prefetch)
        let waiting = Task {
            try await gate.waitTurn(.prefetch)
        }
        let firstDelay = await pause.waitUntilPaused()
        #expect(firstDelay == HAPISOriginGate.prefetchSpacing)

        await gate.noteRateLimited(retryAfterSeconds: 30)
        await pause.resume()
        try await waiting.value

        #expect(pause.sleeps == [HAPISOriginGate.prefetchSpacing, 26])
    }

    @Test func waitTurnPropagatesCancellation() async {
        let gate = HAPISOriginGate(
            now: { Date(timeIntervalSince1970: 1_000) },
            sleep: { _ in throw CancellationError() }
        )
        await gate.noteRateLimited(retryAfterSeconds: 30)
        await #expect(throws: CancellationError.self) {
            try await gate.waitTurn(.interactive)
        }
    }

    @Test func retryAfterIsCappedForClientUX() async throws {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
        let sleeps = SleepLog()
        let gate = HAPISOriginGate(
            now: { clock.now },
            sleep: { seconds in
                sleeps.append(seconds)
                clock.advance(seconds)
            }
        )

        await gate.noteRateLimited(retryAfterSeconds: 300)
        try await gate.waitTurn(.interactive)
        #expect(sleeps.values == [HAPISOriginGate.maxCooldown])
    }

    @Test func retryAfterParsesDeltaSeconds() {
        #expect(HAPISRetryAfter.seconds(from: "15") == 15)
        #expect(HAPISRetryAfter.seconds(from: " 8 ") == 8)
        #expect(HAPISRetryAfter.seconds(from: nil) == nil)
        #expect(HAPISRetryAfter.seconds(from: "") == nil)
    }

    @Test func retryAfterParsesHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let future = formatter.string(from: Date(timeIntervalSince1970: 1_030))
        #expect(HAPISRetryAfter.seconds(from: future, now: now) == 30)

        let expired = formatter.string(from: Date(timeIntervalSince1970: 900))
        #expect(HAPISRetryAfter.seconds(from: expired, now: now) == -100)
    }
}

private final class TestClock: @unchecked Sendable {
    var now: Date

    init(start: Date) {
        now = start
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

private final class SleepLog: @unchecked Sendable {
    private(set) var values: [TimeInterval] = []

    func append(_ seconds: TimeInterval) {
        values.append(seconds)
    }
}

/// 最初の sleep だけ止め、その間に `noteRateLimited` を差し込める。
private final class FirstSleepPause: @unchecked Sendable {
    private(set) var sleeps: [TimeInterval] = []
    private var paused: CheckedContinuation<TimeInterval, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?
    private var didPause = false

    func sleep(_ seconds: TimeInterval, clock: TestClock) async {
        sleeps.append(seconds)
        if !didPause {
            didPause = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                resumeWaiter = continuation
                paused?.resume(returning: seconds)
                paused = nil
            }
        }
        clock.advance(seconds)
    }

    func waitUntilPaused() async -> TimeInterval {
        await withCheckedContinuation { continuation in
            if didPause, let last = sleeps.last, resumeWaiter != nil {
                continuation.resume(returning: last)
            } else {
                paused = continuation
            }
        }
    }

    func resume() async {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}
