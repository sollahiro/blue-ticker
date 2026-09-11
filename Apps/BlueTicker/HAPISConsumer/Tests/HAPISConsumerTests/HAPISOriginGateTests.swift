import Foundation
import Testing

@testable import HAPISConsumer

@Suite
struct HAPISOriginGateTests {
    @Test func prefetchSpacesRequestsInteractiveDoesNot() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
        let sleeps = SleepLog()
        let gate = HAPISOriginGate(
            now: { clock.now },
            sleep: { seconds in
                sleeps.append(seconds)
                clock.advance(seconds)
            }
        )

        await gate.waitTurn(.interactive)
        await gate.waitTurn(.interactive)
        #expect(sleeps.values.isEmpty)

        await gate.waitTurn(.prefetch)
        await gate.waitTurn(.prefetch)
        #expect(sleeps.values.count == 1)
        #expect(sleeps.values[0] == HAPISOriginGate.prefetchSpacing)
    }

    @Test func rateLimitBlocksInteractiveAndPrefetch() async {
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

        await gate.waitTurn(.interactive)
        #expect(sleeps.values == [30])
        #expect(await gate.isCoolingDown() == false)
    }

    @Test func retryAfterParsesDeltaSeconds() {
        #expect(HAPISRetryAfter.seconds(from: "15") == 15)
        #expect(HAPISRetryAfter.seconds(from: " 8 ") == 8)
        #expect(HAPISRetryAfter.seconds(from: nil) == nil)
        #expect(HAPISRetryAfter.seconds(from: "") == nil)
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
