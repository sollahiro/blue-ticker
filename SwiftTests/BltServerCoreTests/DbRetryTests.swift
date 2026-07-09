// withDbRetry の再試行挙動（一過性失敗から回復・規定回数で打ち切り）を検証する。
// backoff は maxBackoffSeconds: 0 で無効化し、待ち時間なしで回す。

import Logging
import Testing

@testable import BltServerCore

private struct RetryTestError: Error, CustomDebugStringConvertible {
    var debugDescription: String { "RetryTestError詳細" }
}

/// 連続失敗回数を数える非並行カウンタ（順次 await されるため lock 不要）。
private final class Counter: @unchecked Sendable {
    var calls = 0
}

/// ログメッセージを蓄積するだけの非並行 LogHandler（順次 await されるため lock 不要）。
/// context/caller が metadata に載ること・失敗時ログレベルを検証するために使う。
private final class CapturingLogHandler: LogHandler, @unchecked Sendable {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    var messages: [(level: Logger.Level, message: String, metadata: Logger.Metadata)] = []

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        messages.append((event.level, event.message.description, event.metadata ?? [:]))
    }
}

private func makeCapturingLogger() -> (Logger, CapturingLogHandler) {
    let handler = CapturingLogHandler()
    return (Logger(label: "test") { _ in handler }, handler)
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

    // MARK: - onRetry（サーキットブレーカー用フック）

    @Test func onRetryFiresOncePerRetriedAttemptNotOnFinalSuccess() async throws {
        let counter = Counter()
        var retryCount = 0
        let value = try await withDbRetry(maxAttempts: 5, maxBackoffSeconds: 0, onRetry: { retryCount += 1 }) {
            counter.calls += 1
            if counter.calls < 3 { throw RetryTestError() }  // 1,2 回目失敗、3 回目成功
            return "ok"
        }
        #expect(value == "ok")
        #expect(retryCount == 2)  // 失敗した1,2回目のみ。3回目（成功）ではfireしない
    }

    @Test func onRetryDoesNotFireWhenFirstAttemptSucceeds() async throws {
        var retryCount = 0
        _ = try await withDbRetry(maxBackoffSeconds: 0, onRetry: { retryCount += 1 }) { 42 }
        #expect(retryCount == 0)
    }

    // MARK: - context/caller・ログ内容

    @Test func retryWarningLogIncludesContextAndCallerAndErrorDetail() async throws {
        let expectedCaller = #function  // withDbRetry の caller 既定値（#function）と同じ解決になる
        let (logger, handler) = makeCapturingLogger()
        let counter = Counter()
        _ = try await withDbRetry(
            maxAttempts: 3, maxBackoffSeconds: 0, logger: logger, context: "code=7203"
        ) {
            counter.calls += 1
            if counter.calls < 2 { throw RetryTestError() }
            return "ok"
        }
        let warning = try #require(handler.messages.first { $0.level == .warning })
        #expect(warning.message == "DB retry")
        #expect(warning.metadata["event"] == .string("db_retry"))
        #expect(warning.metadata["label"] == .string("\(expectedCaller) code=7203"))
        #expect(warning.metadata["error"]?.description.contains("RetryTestError詳細") == true)
    }

    @Test func exhaustionLogsErrorLevelWithContextBeforeRethrowing() async throws {
        let expectedCaller = #function
        let (logger, handler) = makeCapturingLogger()
        await #expect(throws: RetryTestError.self) {
            try await withDbRetry(
                maxAttempts: 2, maxBackoffSeconds: 0, logger: logger, context: "docID=S1"
            ) {
                throw RetryTestError()
            }
        }
        let errorLog = try #require(handler.messages.first { $0.level == .error })
        #expect(errorLog.message == "DB retry exhausted")
        #expect(errorLog.metadata["event"] == .string("db_retry_exhausted"))
        #expect(errorLog.metadata["label"] == .string("\(expectedCaller) docID=S1"))
        #expect(errorLog.metadata["error"]?.description.contains("RetryTestError詳細") == true)
    }
}
