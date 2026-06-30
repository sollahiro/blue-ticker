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

import Foundation
import Logging

/// DB 操作を一過性エラー（接続断等）に対して指数 backoff で再試行する。
/// `maxAttempts` 回試して全て失敗したら最後のエラーを再 throw する。
/// backoff は 1, 2, 4, 8 ... 秒（上限 `maxBackoffSeconds`）。
func withDbRetry<T>(
    maxAttempts: Int = 5,
    maxBackoffSeconds: Double = 16,
    logger: Logger? = nil,
    operation: () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await operation()
        } catch {
            guard attempt < maxAttempts else { throw error }
            let backoff = min(pow(2.0, Double(attempt - 1)), maxBackoffSeconds)
            logger?.warning(
                "DB操作に失敗、\(Int(backoff))s後に再試行します (試行 \(attempt)/\(maxAttempts)): \(error)")
            try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            attempt += 1
        }
    }
}
