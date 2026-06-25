// 実 Postgres（Neon / ローカル Docker）に対する統合テスト。
// 既存テストはインメモリ SQLite までのため、SQLite では現れない Postgres 固有の振る舞い
// （.json → JSONB カラム型・索引作成・String PK・@Timestamp・JSONB round-trip）を実 DB で検証する。
//
// BLT_TEST_POSTGRES_URL が設定されたときのみ実行する（未設定なら skip）。EDINET ネットワークは不要で、
// Stage 3 取り込みは runStage3Ingest にフェイクパーサを注入して DB 書き込み経路だけを通す。
//
//   docker run -d --name blt-pg -e POSTGRES_PASSWORD=blt -e POSTGRES_DB=blt -p 55432:5432 postgres:16-alpine
//   BLT_TEST_POSTGRES_URL='postgres://postgres:blt@localhost:55432/blt?sslmode=disable' \
//     swift test --filter PostgresIntegrationTests

import BlueTickerCore
import Fluent
import FluentPostgresDriver
import SQLKit
import Testing
import Vapor

@testable import BltServerCore

// 単一の実 Postgres DB を共有するため直列実行する（並列だと autoMigrate/autoRevert が競合する）。
@Suite(.serialized) struct PostgresIntegrationTests {
    private static let postgresURL = ProcessInfo.processInfo.environment["BLT_TEST_POSTGRES_URL"]

    /// 実 Postgres に全マイグレーションを適用し、テスト後に revert する。
    private func withPostgresApp(_ body: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            let config = try SQLPostgresConfiguration(url: Self.postgresURL!)
            app.databases.use(.postgres(configuration: config), as: .psql)
            app.migrations.add(CreateEdinetDocument())
            app.migrations.add(CreateEdinetSyncState())
            app.migrations.add(CreateEdinetXbrlFacts())
            try? await app.autoRevert()  // 前回の残骸を掃除（初回は no-op）
            try await app.autoMigrate()
            try await body(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func sql(_ app: Application) throws -> any SQLDatabase {
        try #require(app.db as? any SQLDatabase)
    }

    @Test(.enabled(if: postgresURL != nil, "BLT_TEST_POSTGRES_URL not set"))
    func migrationsCreateJsonbColumnAndIndexes() async throws {
        try await withPostgresApp { app in
            let db = try self.sql(app)

            // facts は Postgres では JSONB（SQLite では TEXT のため SQLite テストでは検証できない）。
            let factsType = try await db.raw(
                """
                SELECT data_type FROM information_schema.columns
                WHERE table_name = 'edinet_xbrl_facts' AND column_name = 'facts'
                """
            ).first(decodingColumn: "data_type", as: String.self)
            #expect(factsType == "jsonb")

            // edinet_documents の検索ホットパス用索引が張られていること。
            let indexRows = try await db.raw(
                "SELECT indexname FROM pg_indexes WHERE tablename = 'edinet_documents'"
            ).all()
            let indexNames = try indexRows.map { try $0.decode(column: "indexname", as: String.self) }
            #expect(indexNames.contains("idx_edinet_documents_edinet_code"))
            #expect(indexNames.contains("idx_edinet_documents_sec_code"))
        }
    }

    @Test(.enabled(if: postgresURL != nil, "BLT_TEST_POSTGRES_URL not set"))
    func stage1And3WriteAndReadBackOnPostgres() async throws {
        try await withPostgresApp { app in
            // Stage 1: upsert 冪等性（同 docID 再投入で重複行を作らない）。
            let rec = EdinetDocumentRecord(
                docID: "S100E2E1", edinetCode: "E00001", secCode: "72030", filerName: "テスト株式会社",
                docTypeCode: "120", ordinanceCode: "010", formCode: "030000",
                periodStart: "2024-04-01", periodEnd: "2025-03-31",
                submitDateTime: "2025-06-20 09:00", docDescription: "有価証券報告書")
            _ = try await applyDocuments([rec], db: app.db)
            let again = try await applyDocuments([rec], db: app.db)
            #expect(again.updated == 1)
            #expect(try await EdinetDocument.query(on: app.db).count() == 1)

            try await upsertSyncState(syncedThrough: "2025-06-20", db: app.db)
            let state = try #require(
                try await EdinetSyncState.find(EdinetSyncState.singletonID, on: app.db))
            #expect(state.syncedThrough == "2025-06-20")

            // Stage 3: ingest（フェイクパーサ）で JSONB を書き、読み戻しで完全一致を確認。
            let payload: XbrlFactIndexPayload = [
                "NetSales": [
                    "CurrentYearDuration": XbrlFactRecord(
                        value: 148_129_000_000.0, consolidation: "non_consolidated", unitRef: "JPY",
                        decimals: "-6", role: nil, section: "PL",
                        roles: ["r1", "r2"], sections: ["PL"], label: "売上高", sourceFile: "f.xml"),
                ],
                "TotalAssets": [
                    "CurrentYearInstant": XbrlFactRecord(value: 9999, consolidation: "consolidated"),
                ],
            ]
            let summary = try await runStage3Ingest(db: app.db, limit: nil) { _ in payload }
            #expect(summary.stored == 1)
            #expect(summary.attempted == 1)

            let row = try #require(try await EdinetXbrlFacts.find("S100E2E1", on: app.db))
            #expect(row.facts == payload)  // JSONB ネストマップ・配列・nil まで完全一致
            #expect(row.cacheVersion == blueTickerVersion)

            // 再実行は現行バージョン済みのため skip（staleness 判定が Postgres でも効く）。
            let rerun = try await runStage3Ingest(db: app.db, limit: nil) { _ in
                Issue.record("fresh document must not be re-parsed")
                return payload
            }
            #expect(rerun.skipped == 1)
            #expect(rerun.attempted == 0)
            #expect(try await EdinetXbrlFacts.query(on: app.db).count() == 1)
        }
    }
}
