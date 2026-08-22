// Feed Update / Trend の DB 読み取り。REST と MCP が共有する。
// ライブ EDINET へは落とさない。未接続は 503。0 件は 200（空 items）。

import BlueTickerCore
import Fluent
import Foundation
import Logging

/// `GET /v1/feed/updates` の DB 読み取り。
func serveFeedUpdates(
    limit: Int, days: Int, docTypes: [String], db: Database?, logger: Logger,
    now: Date = Date()
) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    let cutoff = feedCutoffDateString(days: days, now: now)
    do {
        let records = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadFeedRecords(
                db: db, docTypes: docTypes, since: cutoff, limit: Api.feedTrendScanLimit)
        }
        return .ok(assembleFeedUpdates(
            from: records, limit: limit, days: days, docTypes: docTypes))
    } catch {
        logger.warning("Feed updates の DB 読み取りに失敗: \(error)")
        return .dbUnavailable
    }
}

/// `GET /v1/feed/trend` の DB 読み取り。
func serveFeedTrend(
    limit: Int, days: Int, docTypes: [String], db: Database?, logger: Logger,
    now: Date = Date()
) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    let cutoff = feedCutoffDateString(days: days, now: now)
    do {
        let records = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadFeedRecords(
                db: db, docTypes: docTypes, since: cutoff, limit: Api.feedTrendScanLimit)
        }
        return .ok(assembleFeedTrend(from: records, limit: limit, days: days, docTypes: docTypes))
    } catch {
        logger.warning("Feed trend の DB 読み取りに失敗: \(error)")
        return .dbUnavailable
    }
}

/// 提出日時降順で書類を読む。`since` は `submit_date_time` の辞書順下限（YYYY-MM-DD）。
func loadFeedRecords(
    db: Database, docTypes: [String], since: String?, limit: Int
) async throws -> [EdinetDocumentRecord] {
    guard limit > 0, !docTypes.isEmpty else { return [] }
    var query = EdinetDocument.query(on: db)
    if docTypes.count == 1, let only = docTypes.first {
        query = query.filter(\.$docTypeCode == only)
    } else {
        query = query.group(.or) { group in
            for docType in docTypes {
                group.filter(\.$docTypeCode == docType)
            }
        }
    }
    if let since {
        query = query.filter(\.$submitDateTime >= since)
    }
    let rows = try await query
        .sort(\.$submitDateTime, .descending)
        .limit(limit)
        .all()
    return rows.map { $0.toRecord() }
}
