// 実 Postgres（Neon / ローカル Apple container）に対する統合テスト。
// 既存テストはインメモリ SQLite までのため、SQLite では現れない Postgres 固有の振る舞い
// （.json → JSONB カラム型・索引作成・String PK・@Timestamp・JSONB round-trip）を実 DB で検証する。
//
// BLT_TEST_POSTGRES_URL が設定されたときのみ実行する（未設定なら skip）。CI の
// unit-tests ジョブでは常に設定される。EDINET ネットワークは不要。
//
//   container run -d --name blt-pg -e POSTGRES_PASSWORD=blt -e POSTGRES_DB=blt -p 55432:5432 postgres:16-alpine
//   BLT_TEST_POSTGRES_URL='postgres://postgres:blt@localhost:55432/blt?sslmode=disable' \
//     swift test --filter PostgresIntegrationTests

import BlueTickerCore
import Fluent
import FluentPostgresDriver
import SQLKit
import Testing
import Vapor

@testable import BltServerCore
@testable import BltStoreCore
@testable import BltIngestCore

// 単一の実 Postgres DB を共有するため直列実行する（並列だと autoMigrate/autoRevert が競合する）。
@Suite(.serialized) struct PostgresIntegrationTests {
    private static let postgresURL = ProcessInfo.processInfo.environment["BLT_TEST_POSTGRES_URL"]

    /// 実 Postgres に対象マイグレーションを適用し、テスト後に revert する。
    private func withPostgresApp(_ body: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            let config = try SQLPostgresConfiguration(url: Self.postgresURL!)
            app.databases.use(.postgres(configuration: config), as: .psql)
            app.migrations.add(CreateEdinetDocument())
            app.migrations.add(AddParentDocIDToEdinetDocuments())
            app.migrations.add(CreateEdinetSyncState())
            app.migrations.add(CreateEdinetXbrlFacts())
            app.migrations.add(DropEdinetXbrlFacts())
            app.migrations.add(CreateCompanyFilingSections())
            app.migrations.add(AddFeedQueryIndexesToEdinetDocuments())
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
    func migrationsCreateJsonbColumnAndIndexesAndDropClosedFactsTable() async throws {
        try await withPostgresApp { app in
            let db = try self.sql(app)

            // 有報セクション payload は Postgres では JSONB（SQLite では TEXT）。
            let sectionsType = try await db.raw(
                """
                SELECT data_type FROM information_schema.columns
                WHERE table_name = 'company_filing_sections' AND column_name = 'payload'
                """
            ).first(decodingColumn: "data_type", as: String.self)
            #expect(sectionsType == "jsonb")

            // 閉じた数値 fact 投影は Create のあと Drop され、テーブルが残らない。
            let factsTable = try await db.raw(
                """
                SELECT 1 AS n FROM information_schema.tables
                WHERE table_schema = 'public' AND table_name = 'edinet_xbrl_facts'
                """
            ).first(decodingColumn: "n", as: Int.self)
            #expect(factsTable == nil)

            // DROP TABLE IF EXISTS なので、既に無い状態でも再実行できる。
            try await DropEdinetXbrlFacts().prepare(on: app.db)

            // edinet_documents の検索ホットパス用索引が張られていること。
            let indexRows = try await db.raw(
                "SELECT indexname FROM pg_indexes WHERE tablename = 'edinet_documents'"
            ).all()
            let indexNames = try indexRows.map { try $0.decode(column: "indexname", as: String.self) }
            #expect(indexNames.contains("idx_edinet_documents_edinet_code"))
            #expect(indexNames.contains("idx_edinet_documents_sec_code"))
            #expect(indexNames.contains("idx_edinet_documents_doc_type_submit"))
        }
    }

    @Test(.enabled(if: postgresURL != nil, "BLT_TEST_POSTGRES_URL not set"))
    func documentWriteAndReadBackOnPostgres() async throws {
        try await withPostgresApp { app in
            // 書類同期: upsert 冪等性（同 docID 再投入で重複行を作らない）。
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
        }
    }
}
