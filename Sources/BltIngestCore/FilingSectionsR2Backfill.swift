// 既存の company_filing_sections 行の本文（payload 列）を R2 へ移す。
// `blt-ingest filing-sections-to-r2 [--limit N] [--dry-run]`。冪等・再開可能:
// r2_key が NULL の行だけを対象にし、R2 へ PUT → 読み戻して一致を確認 → payload を空にして r2_key を設定する。
// 失敗した行は触らず次へ進む。DB の空き領域は `VACUUM FULL company_filing_sections` で別途回収する。

import BlueTickerCore
import BltStoreCore
import FluentKit
import Foundation
import Logging
import SQLKit

public struct FilingSectionsR2BackfillSummary: Sendable, Equatable {
    public var moved = 0
    public var failed = 0
    public var remaining = 0
}

public enum FilingSectionsR2BackfillError: Error, Sendable {
    case databaseUnavailable
    case r2NotConfigured
}

/// 本体。`store` と `db` を注入できる（テストはメモリ実装）。`limit` は移す件数の上限、`dryRun` は書かない。
func backfillFilingSectionsToR2(
    db: Database, store: any FilingSectionsObjectStoring, limit: Int?, dryRun: Bool,
    batchSize: Int = 100, logger: Logger? = nil
) async throws -> FilingSectionsR2BackfillSummary {
    var summary = FilingSectionsR2BackfillSummary()
    var skipIDs: Set<String> = []  // 失敗した行を同じ実行で繰り返し選ばない
    while true {
        if let limit, summary.moved >= limit { break }
        let want = min(batchSize, limit.map { $0 - summary.moved } ?? batchSize)
        let ids = try await CompanyFilingSectionsR2KeyOnly.query(on: db)
            .filter(\.$r2Key == nil)
            .sort(\.$id)
            .limit(want + skipIDs.count)
            .all()
            .compactMap(\.id)
            .filter { !skipIDs.contains($0) }
            .prefix(want)
        if ids.isEmpty { break }
        if dryRun {
            summary.remaining = try await CompanyFilingSectionsR2KeyOnly.query(on: db)
                .filter(\.$r2Key == nil).count()
            logger?.notice("dry-run: R2 へ移す対象 \(summary.remaining) 件")
            return summary
        }
        for docID in ids {
            guard let key = filingSectionsObjectKey(docID: docID),
                let row = try await CompanyFilingSections.find(docID, on: db), row.r2Key == nil
            else {
                skipIDs.insert(docID)
                summary.failed += 1
                continue
            }
            do {
                try await store.put(row.payload, key: key)
                guard let back = try await store.get(key: key), back == row.payload else {
                    throw FilingSectionsObjectStoreError.unavailable("読み戻し不一致 key=\(key)")
                }
            } catch {
                skipIDs.insert(docID)
                summary.failed += 1
                logger?.warning("R2 移行失敗: docID=\(docID) \(error)")
                continue
            }
            // r2_key と空 payload を 1 文で切り替える。更新時刻は変えず、版は触らない。
            let sql = try requireSQLDatabase(db)
            try await sql.update(CompanyFilingSections.schema)
                .set("payload", to: FilingSectionsPayload(texts: [:], specials: [:]))
                .set("r2_key", to: key)
                .where("doc_id", .equal, docID)
                .where("r2_key", .is, SQLLiteral.null)
                .run()
            summary.moved += 1
        }
        logger?.notice("R2 移行 \(summary.moved) 件（失敗 \(summary.failed)）")
    }
    summary.remaining = try await CompanyFilingSectionsR2KeyOnly.query(on: db)
        .filter(\.$r2Key == nil).count()
    return summary
}

/// r2_key 列だけの軽量射影（フィルタ用）。
final class CompanyFilingSectionsR2KeyOnly: Model, @unchecked Sendable {
    static let schema = CompanyFilingSections.schema

    @ID(custom: "doc_id", generatedBy: .user)
    var id: String?

    @OptionalField(key: "r2_key")
    var r2Key: String?

    init() {}
}

public func runFilingSectionsR2BackfillCommand(limit: Int?, dryRun: Bool) async throws {
    guard let urlString = bltEnvironmentValue("DATABASE_URL"), !urlString.isEmpty else {
        throw FilingSectionsR2BackfillError.databaseUnavailable
    }
    guard let store = R2FilingSectionsStore.resolveFromEnvironment() else {
        throw FilingSectionsR2BackfillError.r2NotConfigured
    }
    let app = try BltCommandDatabase.connect(urlString: urlString, label: "blt-ingest")
    do {
        try await migrateBltSchema(app)
        let summary = try await backfillFilingSectionsToR2(
            db: app.db, store: store, limit: limit, dryRun: dryRun, logger: app.logger)
        app.logger.notice(
            "filing-sections-to-r2: moved=\(summary.moved) failed=\(summary.failed) remaining=\(summary.remaining)")
    } catch {
        await app.asyncShutdown()
        throw error
    }
    await app.asyncShutdown()
}
