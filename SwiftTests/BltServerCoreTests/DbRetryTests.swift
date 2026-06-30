// withDbRetry の再試行挙動（一過性失敗から回復・規定回数で打ち切り）を検証する。
// backoff は maxBackoffSeconds: 0 で無効化し、待ち時間なしで回す。

import Testing

@testable import BltServerCore

private struct RetryTestError: Error {}

/// 連続失敗回数を数える非並行カウンタ（順次 await されるため lock 不要）。
private final class Counter: @unchecked Sendable {
    var calls = 0
}

@Suite struct DbRetryTests {
    @Test func returnsImmediatelyWhenOperationSucceedsFirstTry() async throws {
        let counter = Counter()
        let value = try await withDbRetry(maxBackoffSeconds: 0) {
            counter.calls += 1
            return 42
        }
        #expect(value == 42)
        #expect(counter.calls == 1)
    }

    @Test func recoversAfterTransientFailures() async throws {
        let counter = Counter()
        let value = try await withDbRetry(maxAttempts: 5, maxBackoffSeconds: 0) {
            counter.calls += 1
            if counter.calls < 3 { throw RetryTestError() }  // 1,2 回目は失敗、3 回目で成功
            return "ok"
        }
        #expect(value == "ok")
        #expect(counter.calls == 3)
    }

    @Test func rethrowsAfterExhaustingAttempts() async {
        let counter = Counter()
        await #expect(throws: RetryTestError.self) {
            try await withDbRetry(maxAttempts: 4, maxBackoffSeconds: 0) {
                counter.calls += 1
                throw RetryTestError()
            }
        }
        #expect(counter.calls == 4)  // maxAttempts 回試して打ち切り
    }
}
