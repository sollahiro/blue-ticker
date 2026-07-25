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
/// `servable`/`unservable` は read 床（`*MinServableVersion`）で見た DB 全体のカバレッジ
/// （今回の ingest 件数ではなくテーブル全件の集計）。床のあるステージ（4 / 4-half / 5）で付与し、
/// 床の概念が無いステージは nil で省略する。
/// `notApplicable` は計算対象外（例: 半期報告書未提出）でスキップした件数。区別しないステージは nil で省略する
/// （issue #73 フォローアップ。failed に混入させず設計通りの挙動と区別する）。
/// `notApplicableGeographyOnly`/`notApplicableSingleSegmentDisclosed`/`notApplicableUnknown` は
/// Stage 6 の notApplicable 内訳（issue #130、E/F判定の検知結果明示化）。区別しないステージは nil で省略する。
/// `purged` は保持窓を超えたため削除した既存行数（Stage 5 retention）。区別しないステージは nil で省略する。
func logIngestSummary(
    _ logger: Logger,
    stage: String,
    attempted: Int,
    stored: Int,
    failed: Int,
    skipped: Int,
    servable: Int? = nil,
    unservable: Int? = nil,
    notApplicable: Int? = nil,
    notApplicableGeographyOnly: Int? = nil,
    notApplicableSingleSegmentDisclosed: Int? = nil,
    notApplicableUnknown: Int? = nil,
    purged: Int? = nil
) {
    var metadata: Logger.Metadata = [
        "event": "ingest_summary",
        "stage": .string(stage),
        "attempted": .stringConvertible(attempted),
        "stored": .stringConvertible(stored),
        "failed": .stringConvertible(failed),
        "skipped": .stringConvertible(skipped),
    ]
    if let servable { metadata["servable"] = .stringConvertible(servable) }
    if let unservable { metadata["unservable"] = .stringConvertible(unservable) }
    if let notApplicable { metadata["not_applicable"] = .stringConvertible(notApplicable) }
    if let notApplicableGeographyOnly {
        metadata["not_applicable_geography_only"] = .stringConvertible(notApplicableGeographyOnly)
    }
    if let notApplicableSingleSegmentDisclosed {
        metadata["not_applicable_single_segment_disclosed"] = .stringConvertible(notApplicableSingleSegmentDisclosed)
    }
    if let notApplicableUnknown {
        metadata["not_applicable_unknown"] = .stringConvertible(notApplicableUnknown)
    }
    if let purged { metadata["purged"] = .stringConvertible(purged) }
    if failed > 0 {
        logger.warning("ingest summary", metadata: metadata)
    } else {
        logger.notice("ingest summary", metadata: metadata)
    }
}
