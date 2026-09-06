// Screen（BLT-49）: company_financials → screen_index の派生更新と、REST `GET /v1/screen` の read 経路。
//
// - 財務取り込み が company_financials を UPSERT した直後に 1 社分を派生更新する（Screen 側の失敗で
//   ingest は落とさない。欠落は次回 ingest の skip 時に補完、残るずれは `screen-rebuild`）。
// - `blt-server screen-rebuild` は company_financials を code の keyset ページングで走査して全件再生成する
//   （offset は使わない。`.all()` で全 JSONB を一度に載せない）。
// - read は screen_index の型付き列に対する AND フィルタ + 1 キーソート + LIMIT のみ。
//   行が 1 件も無い（未生成）は 404。フィルタ 0 件は 200 で空配列。

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
            "screen_index 更新失敗（欠落は次回 ingest で再試行、残るずれは screen-rebuild）: code=\(code) \(redactSecrets(String(reflecting: error)))"
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

/// company_financials 全件から screen_index を再生成する。code 昇順の keyset ページングで走査する。
/// 既存 screen_index にあって company_financials に無い code は削除する（走査後に再確認し、
/// 同時 ingest で増えた行は孤児にしない）。
func rebuildScreenIndex(db: Database, pageSize: Int = 200, logger: Logger? = nil) async throws
    -> ScreenRebuildSummary
{
    var scanned = 0
    var indexed = 0
    var removed = 0
    var seen = Set<String>()
    var afterCode: String? = nil
    while true {
        let last = afterCode
        let page = try await withDbRetry(
            logger: logger, context: "screen-rebuild after=\(last ?? "")"
        ) {
            var query = CompanyFinancials.query(on: db).sort(\.$id)
            if let last { query = query.filter(\.$id > last) }
            return try await query.limit(pageSize).all()
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
        afterCode = page.last?.id
        if page.count < pageSize { break }
    }
    let candidates = try await ScreenIndexCodeOnly.query(on: db).all().compactMap(\.id).filter {
        !seen.contains($0)
    }
    if !candidates.isEmpty {
        let present = Set(
            try await CompanyFinancialsCacheVersionOnly.query(on: db).filter(\.$id ~~ candidates).all()
                .compactMap(\.id))
        let orphans = candidates.filter { !present.contains($0) }
        if !orphans.isEmpty {
            try await ScreenIndex.query(on: db).filter(\.$id ~~ orphans).delete()
            removed += orphans.count
        }
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
/// 索引が未生成（0 行）なら nil（呼び出し側は 404）。フィルタ 0 件は空配列。
func loadScreen(query: ScreenQuery, db: Database) async throws -> [String: Any]? {
    guard try await ScreenIndex.query(on: db).limit(1).first() != nil else { return nil }
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

/// 財務取り込みが current 判定で skip した社のうち、screen_index が無いものだけを格納済み JSON から補完する。
/// JSONB は欠落 code だけ読む。Screen 失敗で ingest は落とさない。
func backfillMissingScreenIndex(codes: [String], db: Database, logger: Logger?) async {
    guard !codes.isEmpty else { return }
    do {
        let indexed = Set(
            try await ScreenIndexCodeOnly.query(on: db).filter(\.$id ~~ codes).all().compactMap(\.id))
        for code in codes where !indexed.contains(code) {
            let fin = try await CompanyFinancials.find(code, on: db)
            guard let fin else { continue }
            await refreshScreenIndexAfterFinancials(
                code: code, response: fin.response, db: db, logger: logger)
        }
    } catch {
        logger?.warning(
            "screen_index 欠落補完失敗（screen-rebuild で再試行）: \(redactSecrets(String(reflecting: error)))"
        )
    }
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
        guard let body else { return .notFound }
        return .ok(body)
    } catch {
        return .dbUnavailable
    }
}
