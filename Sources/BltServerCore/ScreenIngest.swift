// Screen（BLT-49）: company_financials → screen_index の派生更新と、REST `GET /v1/screen` の read 経路。
//
// - 財務取り込み が company_financials を UPSERT した直後に 1 社分を派生更新する（Screen 側の失敗で
//   ingest は落とさない。次回 ingest か `screen-rebuild` で追いつく）。
// - `blt-server screen-rebuild` は company_financials をページングで走査して全件再生成する
//   （`.all()` で全 JSONB を一度に載せない）。
// - read は screen_index の型付き列に対する AND フィルタ + 1 キーソート + LIMIT のみ。

import BlueTickerCore
import Fluent
import Foundation
import Logging
import Vapor

/// company_financials の 1 行から screen_index を派生更新する。
/// 投影できない（years 空・market 空＝notApplicable プレースホルダ）なら既存 Screen 行を削除する。
func upsertScreenIndex(code: String, response: FinancialsResponse, db: Database) async throws {
    let existing = try await ScreenIndex.find(code, on: db)
    guard let row = response.screenRow() else {
        try await existing?.delete(on: db)
        return
    }
    if let existing {
        existing.apply(row)
        try await existing.update(on: db)
        return
    }
    let model = ScreenIndex()
    model.apply(row)
    try await createIdempotently(
        create: { try await model.create(on: db) },
        recover: {
            guard let recovered = try await ScreenIndex.find(code, on: db) else { return false }
            recovered.apply(row)
            try await recovered.update(on: db)
            return true
        }
    )
}

/// 財務取り込み 直後の best-effort 派生更新。失敗は warning ログのみ（ingest 本体は継続）。
func refreshScreenIndexAfterFinancials(
    code: String, response: FinancialsResponse, db: Database, logger: Logger?
) async {
    do {
        try await upsertScreenIndex(code: code, response: response, db: db)
    } catch {
        logger?.warning(
            "screen_index 更新失敗（次回 ingest / screen-rebuild で再試行）: code=\(code) \(redactSecrets(String(reflecting: error)))"
        )
    }
}

/// `screen-rebuild` の結果。
public struct ScreenRebuildSummary: Sendable, Equatable {
    /// 走査した company_financials 行数。
    public let scanned: Int
    /// screen_index へ書いた行数（read 床以上・投影可能）。
    public let indexed: Int
    /// 投影不能（床未満・years 空・market 空）のため screen_index から外した行数。
    public let removed: Int
}

/// company_financials 全件から screen_index を再生成する。code 昇順にページングして走査する。
/// 既存 screen_index にあって company_financials に無い code は削除する。
func rebuildScreenIndex(db: Database, pageSize: Int = 200, logger: Logger? = nil) async throws
    -> ScreenRebuildSummary
{
    var scanned = 0
    var indexed = 0
    var removed = 0
    var seen = Set<String>()
    var offset = 0
    while true {
        let pageRange = offset..<(offset + pageSize)
        let page = try await withDbRetry(logger: logger, context: "screen-rebuild offset=\(offset)") {
            try await CompanyFinancials.query(on: db).sort(\.$id).range(pageRange).all()
        }
        if page.isEmpty { break }
        for fin in page {
            guard let code = fin.id else { continue }
            scanned += 1
            seen.insert(code)
            let row = isServableCompanyFinancialsCacheVersion(fin.cacheVersion) ? fin.response.screenRow() : nil
            try await withDbRetry(logger: logger, context: "screen-rebuild code=\(code)") {
                let existing = try await ScreenIndex.find(code, on: db)
                if let row {
                    let model = existing ?? ScreenIndex()
                    model.apply(row)
                    if existing != nil { try await model.update(on: db) } else { try await model.create(on: db) }
                } else {
                    try await existing?.delete(on: db)
                }
            }
            if row != nil { indexed += 1 } else { removed += 1 }
        }
        if page.count < pageSize { break }
        offset += pageSize
    }
    let orphans = try await ScreenIndexCodeOnly.query(on: db).all().compactMap(\.id).filter { !seen.contains($0) }
    if !orphans.isEmpty {
        try await ScreenIndex.query(on: db).filter(\.$id ~~ orphans).delete()
        removed += orphans.count
    }
    return ScreenRebuildSummary(scanned: scanned, indexed: indexed, removed: removed)
}

/// `blt-server screen-rebuild` エントリ。DATABASE_URL 未設定なら databaseUnavailable。
public func runScreenRebuildCommand() async throws {
    guard let urlString = Environment.get("DATABASE_URL"), !urlString.isEmpty else {
        throw DocumentSyncError.databaseUnavailable
    }
    var env = Environment(name: "production", arguments: ["blt-server"])
    try bootstrapBltLogging(from: &env)
    let app = try await Application.make(env)
    do {
        try await configureDatabase(app)
        let summary = try await rebuildScreenIndex(db: app.db, logger: app.logger)
        app.logger.notice(
            "screen_index rebuild completed",
            metadata: [
                "event": "screen_rebuild", "scanned": "\(summary.scanned)",
                "indexed": "\(summary.indexed)", "removed": "\(summary.removed)",
            ])
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

/// code 列だけの軽量射影（rebuild の孤児検出用）。
final class ScreenIndexCodeOnly: Model, @unchecked Sendable {
    static let schema = ScreenIndex.schema

    @ID(custom: "code", generatedBy: .user)
    var id: String?

    init() {}
}

// MARK: - read 経路（REST screen）

/// screen_index を AND フィルタ + 1 キーソート + LIMIT で検索する。
/// フィルタ・ソート対象が null の行は結果に載せない（0 扱いにしない）。
func loadScreen(query: ScreenQuery, db: Database) async throws -> [String: Any] {
    func base() -> QueryBuilder<ScreenIndex> {
        var builder = ScreenIndex.query(on: db)
        if let sector = query.sector {
            builder = builder.filter(\.$sector == sector)
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

/// `screen` の DB 読み取り共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
func serveScreen(query: ScreenQuery, db: Database?, logger: Logger) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let body = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadScreen(query: query, db: db)
        }
        return .ok(body)
    } catch {
        return .dbUnavailable
    }
}
