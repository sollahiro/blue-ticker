// withDbRetry の再試行挙動（一過性失敗から回復・規定回数で打ち切り）を検証する。
// backoff は maxBackoffSeconds: 0 で無効化し、待ち時間なしで回す。

import Fluent
import Foundation
import Logging
import Testing

@testable import BltServerCore

private struct RetryTestError: Error, CustomDebugStringConvertible {
    var debugDescription: String { "RetryTestError詳細" }
}

/// `DatabaseError` 適合の偽エラー。`isPrimaryKeyConflict`/`createIdempotently` のテスト用。
private struct FakeDatabaseError: Error, DatabaseError {
    var isConstraintFailure: Bool
    var isSyntaxError: Bool = false
    var isConnectionClosed: Bool = false
}

/// 呼び出し回数を数えるカウンタ。多くのテストでは順次 await されるため競合しないが、タイムアウト
/// テストでは「見捨てられた旧試行のタスク」と「新しい試行」が重なって存在しうるため lock で守る。
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0

    var calls: Int {
        get { lock.lock(); defer { lock.unlock() }; return _calls }
        set { lock.lock(); defer { lock.unlock() }; _calls = newValue }
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _calls += 1
        return _calls
    }
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
            counter.increment()
            return 42
        }
        #expect(value == 42)
        #expect(counter.calls == 1)
    }

    @Test func recoversAfterTransientFailures() async throws {
        let counter = Counter()
        let value = try await withDbRetry(maxAttempts: 5, maxBackoffSeconds: 0) {
            counter.increment()
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
                counter.increment()
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
            counter.increment()
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
            counter.increment()
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

    // MARK: - 応答なしタイムアウト（無応答のまま死んだ接続への対策）
    //
    // 「例外を投げずに無期限へ待ち続ける」ハングを Task.sleep で模擬する。実運用の時間感覚では
    // ないため operationTimeoutSeconds を短縮してテスト時間を抑える（0.2秒: CI の混雑したスケジューラ
    // でも最初の Task が起動して増分するまでの猶予を確保しつつ、テスト自体は高速に保つ）。

    @Test func operationTimeoutIsTreatedAsRetryableWhenOperationNeverReturns() async throws {
        let counter = Counter()
        let value = try await withDbRetry(
            maxAttempts: 2, maxBackoffSeconds: 0, operationTimeoutSeconds: 0.2
        ) {
            counter.increment()
            if counter.calls == 1 {
                try await Task.sleep(nanoseconds: 3_600_000_000_000)  // 応答なしハングの模擬
            }
            return "recovered"
        }
        #expect(value == "recovered")
        #expect(counter.calls == 2)  // 1回目はタイムアウトで見切り、2回目で成功
    }

    @Test func operationTimeoutExhaustsAttemptsAndThrowsTimeoutError() async {
        await #expect(throws: DbOperationTimeoutError.self) {
            try await withDbRetry(
                maxAttempts: 2, maxBackoffSeconds: 0, operationTimeoutSeconds: 0.2
            ) {
                try await Task.sleep(nanoseconds: 3_600_000_000_000)  // 応答なしハングの模擬
                return "unreachable"
            }
        }
    }

    // MARK: - isPrimaryKeyConflict / createIdempotently
    //
    // タイムアウト後リトライで INSERT が二重送信され、実際にはサーバー側で先行試行が成功していた
    // ケース（主キー重複として跳ね返る）を吸収する経路の検証。

    @Test func isPrimaryKeyConflictTrueForConstraintFailure() {
        #expect(isPrimaryKeyConflict(FakeDatabaseError(isConstraintFailure: true)) == true)
    }

    @Test func isPrimaryKeyConflictFalseForNonConstraintDatabaseError() {
        #expect(isPrimaryKeyConflict(FakeDatabaseError(isConstraintFailure: false)) == false)
    }

    @Test func isPrimaryKeyConflictFalseForNonDatabaseError() {
        #expect(isPrimaryKeyConflict(RetryTestError()) == false)
    }

    @Test func createIdempotentlySucceedsWithoutRecoverWhenCreateSucceeds() async throws {
        var recoverCalled = false
        try await createIdempotently(
            create: {},
            recover: { recoverCalled = true }
        )
        #expect(recoverCalled == false)
    }

    @Test func createIdempotentlyFallsBackToRecoverOnPrimaryKeyConflict() async throws {
        var recoverCalled = false
        try await createIdempotently(
            create: { throw FakeDatabaseError(isConstraintFailure: true) },
            recover: { recoverCalled = true }
        )
        #expect(recoverCalled == true)
    }

    @Test func createIdempotentlyRethrowsNonConflictErrorsWithoutCallingRecover() async {
        var recoverCalled = false
        await #expect(throws: RetryTestError.self) {
            try await createIdempotently(
                create: { throw RetryTestError() },
                recover: { recoverCalled = true }
            )
        }
        #expect(recoverCalled == false)
    }
}
