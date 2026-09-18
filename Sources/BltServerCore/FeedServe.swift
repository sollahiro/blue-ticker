// Feed Update の DB 読み取り。REST と MCP が共有する。
// ライブ EDINET へは落とさない。未接続は 503。0 件は 200（空 items）。
// items は listed だけ・必要件数だけ読む。total.day / total.week は COUNT。
// 同一 Fluent 接続へ並列に投げない（SQLite テストとリクエスト単位のプール接続）。

import BlueTickerCore
import Fluent
import FluentSQL
import Foundation
import Logging
import SQLKit

/// `GET /v1/feed/updates` の DB 読み取り。
func serveFeedUpdates(
    limit: Int, days: Int, docTypes: [String], db: Database?, logger: Logger,
    now: Date = Date()
) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    let itemsCutoff = feedInclusiveCutoffDateString(days: days, now: now)
    let weekCutoff = feedInclusiveCutoffDateString(days: Api.feedUpdateWeekDays, now: now)
    let today = feedDateString(now)
    let tomorrow = feedNextDateString(today) ?? today
    do {
        let snapshot = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            let totals = try await loadFeedListedTotals(
                db: db, docTypes: docTypes, today: today, tomorrow: tomorrow,
                weekCutoff: weekCutoff)
            let records = try await loadFeedListedItemRecords(
                db: db, docTypes: docTypes, since: itemsCutoff, limit: limit)
            return (totals, records)
        }
        return .ok(assembleFeedUpdates(
            from: snapshot.1, limit: limit, days: days, docTypes: docTypes, now: now,
            dayTotal: snapshot.0.day, weekTotal: snapshot.0.week))
    } catch {
        logger.warning("Feed updates の DB 読み取りに失敗: \(error)")
        return .dbUnavailable
    }
}

struct FeedListedTotals: Sendable {
    let day: Int
    let week: Int
}

/// listed（府令 010・5 桁 sec_code 末尾 0・00000 以外）の当日件数と直近 7 日件数。
/// `total.day` は提出日の接頭辞が今日と一致する件数（未来日は含めない）。
func loadFeedListedTotals(
    db: Database, docTypes: [String], today: String, tomorrow: String, weekCutoff: String
) async throws -> FeedListedTotals {
    guard !docTypes.isEmpty else { return FeedListedTotals(day: 0, week: 0) }
    var weekQuery = feedListedQuery(on: db, docTypes: docTypes)
    weekQuery = weekQuery.filter(\.$submitDateTime >= weekCutoff)
    let week = try await weekQuery.count()
    var dayQuery = feedListedQuery(on: db, docTypes: docTypes)
    dayQuery = dayQuery.filter(\.$submitDateTime >= today)
    dayQuery = dayQuery.filter(\.$submitDateTime < tomorrow)
    let day = try await dayQuery.count()
    return FeedListedTotals(day: day, week: week)
}

/// items 用。listed のみ、提出日時降順で `limit` 件。`limit` 件目が乗る暦日は全件そろえる。
/// 同日過多の安定サンプリング（`feedSelectItems`）はその日の listed を全部見ないと成り立たず、
/// 半期報告書（160）は 1 日 700 件近く出る日がある。
func loadFeedListedItemRecords(
    db: Database, docTypes: [String], since: String?, limit: Int
) async throws -> [EdinetDocumentRecord] {
    guard limit > 0, !docTypes.isEmpty else { return [] }
    let newest = try await loadFeedListedRows(
        db: db, docTypes: docTypes, since: since, before: nil, limit: limit)
    guard newest.count == limit, let last = newest.last else { return newest }
    let boundaryDate = feedSubmitDatePrefix(last.submitDateTime)
    guard let nextDate = feedNextDateString(boundaryDate) else { return newest }
    let boundaryDay = try await loadFeedListedRows(
        db: db, docTypes: docTypes, since: boundaryDate, before: nextDate,
        limit: Api.feedUpdateDayScanLimit)
    let newerDays = newest.filter { feedSubmitDatePrefix($0.submitDateTime) != boundaryDate }
    return newerDays + boundaryDay
}

/// listed 行を提出日時降順で `limit` 件。`since` は下限（含む）、`before` は上限（含まない）。
private func loadFeedListedRows(
    db: Database, docTypes: [String], since: String?, before: String?, limit: Int
) async throws -> [EdinetDocumentRecord] {
    var query = feedListedQuery(on: db, docTypes: docTypes)
    if let since {
        query = query.filter(\.$submitDateTime >= since)
    }
    if let before {
        query = query.filter(\.$submitDateTime < before)
    }
    applyFeedItemColumns(&query)
    let rows = try await query
        .sort(\.$submitDateTime, .descending)
        .limit(limit)
        .all()
    return rows.map { $0.toRecord() }
}

private func feedListedQuery(on db: Database, docTypes: [String]) -> QueryBuilder<EdinetDocument>
{
    var query = EdinetDocument.query(on: db)
    applyFeedDocTypeFilter(&query, docTypes: docTypes)
    query = query.filter(\.$ordinanceCode == Api.ordinanceCompanyDisclosure)
    // 5 桁・末尾 0。`listedTickerCode` と同じ。SQLite / Postgres 共通。
    query = query.filter(.sql(SQLRaw("sec_code LIKE '____0' AND sec_code <> '00000'")))
    return query
}

/// items が使う列だけ読む。必須列（`edinet_code`）も Fluent の decode に必要。
private func applyFeedItemColumns(_ query: inout QueryBuilder<EdinetDocument>) {
    query = query
        .field(\.$id)
        .field(\.$edinetCode)
        .field(\.$secCode)
        .field(\.$filerName)
        .field(\.$docTypeCode)
        .field(\.$ordinanceCode)
        .field(\.$periodEnd)
        .field(\.$submitDateTime)
        .field(\.$docDescription)
}

private func applyFeedDocTypeFilter(
    _ query: inout QueryBuilder<EdinetDocument>, docTypes: [String]
) {
    if docTypes.count == 1, let only = docTypes.first {
        query = query.filter(\.$docTypeCode == only)
    } else {
        query = query.group(.or) { group in
            for docType in docTypes {
                group.filter(\.$docTypeCode == docType)
            }
        }
    }
}
