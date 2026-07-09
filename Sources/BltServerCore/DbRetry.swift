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

import BlueTickerCore
import Foundation
import Logging

/// DB 操作を一過性エラー（接続断等）に対して指数 backoff で再試行する。
/// `maxAttempts` 回試して全て失敗したら ERROR ログを1行出してから最後のエラーを再 throw する。
/// backoff は 1, 2, 4, 8 ... 秒（上限 `maxBackoffSeconds`）。
///
/// - `context`: 呼び出し元が識別したい対象（例: `"code=7203"`）。省略可。
/// - `caller`: 既定で呼び出し元の関数名が自動で入る（呼び出し側の変更不要）。
/// - `onRetry`: リトライ発生のたびに呼ばれる。呼び出し側が「DB が不安定かどうか」を追跡し、
///   閾値超で早期中断する（サーキットブレーカー）用途に使う。
func withDbRetry<T>(
    maxAttempts: Int = 5,
    maxBackoffSeconds: Double = 16,
    logger: Logger? = nil,
    context: String? = nil,
    caller: String = #function,
    onRetry: (() -> Void)? = nil,
    operation: () async throws -> T
) async throws -> T {
    let label = context.map { "\(caller) \($0)" } ?? caller
    var attempt = 1
    while true {
        do {
            return try await operation()
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
