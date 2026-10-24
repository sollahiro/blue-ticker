import BlueTickerCore
import FluentKit
import Foundation
import Logging
import SQLKit

/// screen_index を AND フィルタ + 1 キーソート + LIMIT で検索する。
/// フィルタ・ソート対象が null の行は結果に載せない（0 扱いにしない）。
/// 索引が未生成（0 行）なら nil（呼び出し側は 404）。フィルタ 0 件は空配列。
package func loadScreen(query: ScreenQuery, db: Database) async throws -> [String: Any]? {
    guard try await ScreenIndex.query(on: db).limit(1).first() != nil else { return nil }
    func base() -> QueryBuilder<ScreenIndex> {
        var builder = ScreenIndex.query(on: db)
        if !query.sectors.isEmpty {
            builder = builder.filter(\.$sector ~~ query.sectors)
        }
        for metric in ScreenMetric.allCases {
            let field = ScreenIndex.field(metric)
            if let range = query.ranges[metric] {
                builder = builder.filter(field != nil)
                if let lo = range.min { builder = builder.filter(field >= lo) }
                if let hi = range.max { builder = builder.filter(field <= hi) }
            } else if metric == query.sort {
                builder = builder.filter(field != nil)
            }
        }
        return builder
    }
    let matched = try await base().count()
    let sortField = ScreenIndex.field(query.sort)
    let rows = try await base()
        .sort(sortField, query.order == .desc ? .descending : .ascending)
        .sort(\.$id)
        .limit(query.limit)
        .all()
    return screenResponseJSON(rows: rows.map { $0.toRow() }, matched: matched, query: query)
}

/// screen_index 全行をスナップショット形で読む。索引が未生成（0 行）なら nil（呼び出し側は 404）。
/// code 昇順の keyset ページで読む（1 クエリで全件 `.all()` しない）。
package func loadScreenSnapshot(db: Database, pageSize: Int = 1000) async throws -> [String: Any]? {
    var rows: [ScreenRow] = []
    var afterCode: String? = nil
    while true {
        var query = ScreenIndex.query(on: db).sort(\.$id)
        if let afterCode { query = query.filter(\.$id > afterCode) }
        let page = try await query.limit(pageSize).all()
        rows.append(contentsOf: page.map { $0.toRow() })
        afterCode = page.last?.id
        if page.count < pageSize { break }
    }
    guard !rows.isEmpty else { return nil }
    return screenSnapshotJSON(rows: rows)
}

/// `screen/snapshot` の DB 読み取り。`db` の扱いは `serveStoredFinancials` 参照。
package func serveScreenSnapshot(db: Database?, logger: Logger) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let body = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadScreenSnapshot(db: db)
        }
        guard let body else { return .notFound }
        return .ok(body)
    } catch {
        return .dbUnavailable
    }
}

/// `screen` の DB 読み取り共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
package func serveScreen(query: ScreenQuery, db: Database?, logger: Logger) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let body = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadScreen(query: query, db: db)
        }
        guard let body else { return .notFound }
        return .ok(body)
    } catch {
        return .dbUnavailable
    }
}
