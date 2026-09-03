// DB 操作の再接続リトライ。
//
// Neon の scale-to-zero（無料プランは5分固定・延長不可）が、長時間 ingest の XBRL ダウンロード
// 空白中にコンピュートを suspend し、確立済みの接続を切断することがある（PSQLError）。
// Fluent のコネクションプールは次回要求で新規接続を張り直す＝suspend したコンピュートを resume
// するため、短い backoff を挟んで再試行すると回復する。
//
// 失敗モードは「DL の空白（アイドル）中に suspend → 直後の DB 操作が死んだ接続で即時失敗」であり、
// 当該操作はサーバー側で未実行。かつ ingest の DB 操作はいずれも冪等（find は読み取り、store は
// 主キー upsert）なため、一過性エラーを安全に再試行できる。規定回数を超えたら元のエラーを再 throw する。
//
// もう一つの失敗モードとして、接続が TCP 的に無応答のまま死ぬ（FIN/RST が来ない。Mac のスリープ中の
// ネットワーク一時停止等で発生）ケースがある。この場合クエリの await は例外を投げずに無期限へ待ち続け、
// 上記のリトライは（catch に入れないため）一切発動しない。`withOperationTimeout` で1試行あたりの
// 応答待ちに上限を設け、超過時は強制的にタイムアウト例外を投げて通常のリトライ経路に載せる。

import BlueTickerCore
import Fluent
import Foundation
import Logging

/// `withOperationTimeout` が上限超過時に投げるエラー。DB 以外（MCP ルートの HTTP タイムアウト等）
/// からも再利用するため、対象を表す `label` を持たせている。
struct OperationTimeoutError: Error, CustomStringConvertible {
    let label: String
    let seconds: Double
    var description: String { "\(label)が\(Int(seconds))秒応答なしのためタイムアウト" }
}

/// 継続を高々1回だけ resume することを保証する箱。
/// タイムアウト・操作完了のどちらが先着しても、後着側は無視する。
/// 先着側は相手 Task を `cancel()` する（待ち合わせはしない）。
private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var peers: [Task<Void, Never>] = []

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// resume より後に呼ばれた場合は、すでに勝者が決まっているので渡された Task をすぐ cancel する。
    func attachPeers(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        let alreadyResumed = continuation == nil
        if alreadyResumed {
            lock.unlock()
            for task in tasks { task.cancel() }
            return
        }
        peers.append(contentsOf: tasks)
        lock.unlock()
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let toCancel = peers
        peers = []
        lock.unlock()
        pending?.resume(with: result)
        for task in toCancel { task.cancel() }
    }
}

/// `T` を Sendable 制約なしで継続の外へ運ぶための箱。DB read 経路は `[String: Any]`（JSON 境界の
/// 動的型、`.agents/rules/data-handling.md` で許容）を返すため `T: Sendable` を要求できない。実際には呼び出し元の
/// タスク1つが値を生成し、それを継続経由で1回だけ受け渡すだけ（複数タスクからの同時アクセスはない）
/// なので `@unchecked Sendable` は安全。
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// `operation` の応答待ちに上限を設ける。超過時は `OperationTimeoutError` を投げて先に返る。
///
/// TaskGroup による構造化並行処理は使わない: グループのスコープを抜ける際に未完了の子タスクを
/// 暗黙に待ち合わせる仕様のため、キャンセルに応答しない無応答タスク（本関数が対処したい対象）を
/// 待ち続けてしまい、タイムアウトの意味がなくなる。
///
/// 操作 Task とタイマー Task は unstructured のまま走らせ、先着側が相手を `cancel()` する
/// （待ち合わせはしない）。タイマーは操作完了後に `Task.sleep` が `CancellationError` で終わる。
/// 操作側は協調的キャンセルに応答する処理（`Task.sleep` / URLSession 等）なら打ち切れる。
/// Fluent の TCP 無応答のようにキャンセルを見ない待ちは、従来どおり呼び出し元を先に返して裏に残る。
/// 呼び出し元はリトライ試行ごとに新しい Fluent インスタンスを使うこと（同一インスタンスの再利用は
/// 遅延完了との競合窓になる）。
///
/// `withDbRetry` 専用ではなく、単発の操作に上限を設けたい他の呼び出し元（MCP ルートの HTTP
/// タイムアウト等）からも再利用する。`label` はタイムアウト時のエラーメッセージに使う対象名。
func withOperationTimeout<T>(
    label: String,
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let box: UncheckedSendableBox<T> = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<UncheckedSendableBox<T>, Error>) in
        let resultBox = ContinuationBox(continuation)
        let work = Task {
            do {
                let result = try await operation()
                resultBox.resume(with: .success(UncheckedSendableBox(value: result)))
            } catch {
                resultBox.resume(with: .failure(error))
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                resultBox.resume(with: .failure(OperationTimeoutError(label: label, seconds: seconds)))
            } catch {
                // 操作完了側が先着したのでタイマーは不要。
            }
        }
        resultBox.attachPeers([work, timer])
    }
    return box.value
}

/// DB 操作を一過性エラー（接続断等）に対して指数 backoff で再試行する。
/// `maxAttempts` 回試して全て失敗したら ERROR ログを1行出してから最後のエラーを再 throw する。
/// backoff は 1, 2, 4, 8 ... 秒（上限 `maxBackoffSeconds`）。
///
/// 1試行あたりの応答待ちには `operationTimeoutSeconds`（既定 `Api.dbOperationTimeoutSeconds`）の
/// 上限がある（`withOperationTimeout`）。無応答のまま死んだ接続で操作が永久に待ち続けることを防ぎ、
/// タイムアウトも通常のリトライ経路に載せる。
///
/// - `context`: 呼び出し元が識別したい対象（例: `"code=7203"`）。省略可。
/// - `caller`: 既定で呼び出し元の関数名が自動で入る（呼び出し側の変更不要）。
/// - `onRetry`: リトライ発生のたびに呼ばれる。呼び出し側が「DB が不安定かどうか」を追跡し、
///   閾値超で早期中断する（サーキットブレーカー）用途に使う。
func withDbRetry<T>(
    maxAttempts: Int = 5,
    maxBackoffSeconds: Double = 16,
    operationTimeoutSeconds: Double = Api.dbOperationTimeoutSeconds,
    logger: Logger? = nil,
    context: String? = nil,
    caller: String = #function,
    onRetry: (() -> Void)? = nil,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let label = context.map { "\(caller) \($0)" } ?? caller
    var attempt = 1
    while true {
        do {
            return try await withOperationTimeout(
                label: "DB操作", seconds: operationTimeoutSeconds, operation: operation)
        } catch {
            guard attempt < maxAttempts else {
                if let logger {
                    let detail = String(reflecting: error).prefix(Api.dbRetryErrorLogMaxLength)
                    logger.error(
                        "DB retry exhausted",
                        metadata: [
                            "event": "db_retry_exhausted",
                            "label": .string(label),
                            "attempt": .stringConvertible(maxAttempts),
                            "max_attempts": .stringConvertible(maxAttempts),
                            "error": .string(String(detail)),
                        ])
                }
                throw error
            }
            onRetry?()
            let backoff = min(pow(2.0, Double(attempt - 1)), maxBackoffSeconds)
            if let logger {
                let detail = String(reflecting: error).prefix(Api.dbRetryErrorLogMaxLength)
                logger.warning(
                    "DB retry",
                    metadata: [
                        "event": "db_retry",
                        "label": .string(label),
                        "attempt": .stringConvertible(attempt),
                        "max_attempts": .stringConvertible(maxAttempts),
                        "backoff_seconds": .stringConvertible(Int(backoff)),
                        "error": .string(String(detail)),
                    ])
            }
            try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            attempt += 1
        }
    }
}

/// Postgres の整合性制約違反（一意制約違反を含む）かどうかを判定する。
/// `create` の二重送信検出に使う（`createIdempotently` 参照）。対象テーブルはいずれも主キー以外の
/// 一意制約を持たないため、実質的に主キー重複の検出として機能する。
/// `FluentPostgresDriver` の `PSQLError: DatabaseError` 適合（`isConstraintFailure`）を使う。
/// エラー文字列表現（`debugDescription` 等）への依存はドライバの内部実装詳細でありバージョン間で
/// 変わりうるため避ける。
func isPrimaryKeyConflict(_ error: Error) -> Bool {
    (error as? DatabaseError)?.isConstraintFailure ?? false
}

/// `create`（非冪等な INSERT）を、主キー重複時は `recover` にフォールバックさせることで
/// 実質的に冪等化する。
///
/// `withOperationTimeout`（本ファイル上部）の既知のトレードオフにより、クライアント側が
/// タイムアウトと判定して `withDbRetry` がリトライを発行した後も、元の `create` はサーバー側で
/// 実際には成功していることがある。この場合、リトライの 2 回目以降の `create` は主キー重複
/// （sqlState 23505）で失敗する。これを「既に create 済み」とみなし、find し直して update に
/// 切り替える。
///
/// `isPrimaryKeyConflict` は NOT NULL・FK・CHECK 違反等、一意制約違反以外の整合性制約違反にも
/// true を返すため、`recover` が対象行を見つけられないケース（真に別要因で `create` が失敗した
/// 場合）がありうる。この場合 `recover` は `false` を返し、`createIdempotently` は元のエラーを
/// 再 throw する（黙って成功扱いにしない＝呼び出し元が `stored`/`created` を誤って加算するのを防ぐ）。
func createIdempotently(
    create: () async throws -> Void,
    recover: () async throws -> Bool
) async throws {
    do {
        try await create()
    } catch {
        guard isPrimaryKeyConflict(error) else { throw error }
        guard try await recover() else { throw error }
    }
}
