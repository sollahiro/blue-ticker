// blt-server / ingest CLI 共通のログ初期化と、機械可読な完了サマリ出力。

import Foundation
import Logging
import Vapor

/// Vapor 既定の ConsoleLogger の代わりに JSON 1 行ログを有効化する。
/// `LOG_LEVEL` / `--log` の検出は Vapor と同じ（`Logger.Level.detect`）。
func bootstrapBltLogging(from environment: inout Environment) throws {
    let level = try Logger.Level.detect(from: &environment)
    LoggingSystem.bootstrap { label in
        let handler = JsonLogHandler.standardError(label: label)
        handler.logLevel = level
        return handler
    }
}

/// ingest ステージ完了を JSON metadata 付きで 1 行出す。
/// `failed > 0` のときは warning（成功のみ notice）。
func logIngestSummary(
    _ logger: Logger,
    stage: String,
    attempted: Int,
    stored: Int,
    failed: Int,
    skipped: Int
) {
    let metadata: Logger.Metadata = [
        "event": "ingest_summary",
        "stage": .string(stage),
        "attempted": .stringConvertible(attempted),
        "stored": .stringConvertible(stored),
        "failed": .stringConvertible(failed),
        "skipped": .stringConvertible(skipped),
    ]
    if failed > 0 {
        logger.warning("ingest summary", metadata: metadata)
    } else {
        logger.notice("ingest summary", metadata: metadata)
    }
}
