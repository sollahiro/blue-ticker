// 配信サーバーが読み取り専用ロール（本番では blt_reader）だけで動くことの仕様。
// 書き込み側（スーパーユーザー）が全マイグレーションを適用したあと、SELECT だけを持つ
// `default_transaction_read_only = on` のロールで配信経路を通し、
// - DB を使う /v1 が 5xx（DDL・書き込み・GRANT 漏れ）にならない
// - そのロールでは書き込みも DDL も拒否される（テストの前提が成り立っている）
// を実 Postgres で確かめる。SQLite には権限が無いため検証できない。
//
// BLT_TEST_POSTGRES_URL が設定されたときのみ実行する（CI の unit-tests ジョブでは常に設定される）。
// PostgresIntegrationTests と同じサーバーを使うが、専用データベースを作って衝突を避ける。

import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import Testing
import Vapor

@testable import BlueTickerCore
@testable import BltServerCore
@testable import BltStoreCore
@testable import BltIngestCore

@Suite(.serialized) struct ReadOnlyRolePostgresTests {
    private static let postgresURL = ProcessInfo.processInfo.environment["BLT_TEST_POSTGRES_URL"]
    private static let databaseName = "blt_readonly_role_test"
    private static let readerRole = "blt_reader_test"
    private static let readerPassword = "reader"

    /// 接続 URL のユーザー・パスワード・データベース名を差し替える。
    private static func url(user: String? = nil, password: String? = nil, database: String) throws -> String {
        let base = try #require(postgresURL)
        var components = try #require(URLComponents(string: base))
        if let user { components.user = user }
        if let password { components.password = password }
        components.path = "/\(database)"
        return try #require(components.string)
    }

    private static func makeApp(url: String) async throws -> Application {
        let app = try await Application.make(.testing)
        app.databases.use(.postgres(configuration: try SQLPostgresConfiguration(url: url)), as: .psql)
        return app
    }

    private static func sql(_ app: Application) throws -> any SQLDatabase {
        try #require(app.db as? any SQLDatabase)
    }

    /// 専用 DB と読み取りロールを作り、owner で全マイグレーション・GRANT を済ませてから body に reader を渡す。
    private func withReaderApp(_ body: (Application) async throws -> Void) async throws {
        let admin = try await Self.makeApp(url: try #require(Self.postgresURL))
        do {
            let adminSQL = try Self.sql(admin)
            try await Self.dropFixtures(adminSQL)
            try await adminSQL.raw("CREATE DATABASE \(unsafeRaw: Self.databaseName)").run()
            try await adminSQL.raw(
                "CREATE ROLE \(unsafeRaw: Self.readerRole) LOGIN PASSWORD '\(unsafeRaw: Self.readerPassword)'"
            ).run()
            do {
                try await Self.migrateAndGrant()
                let reader = try await Self.makeApp(
                    url: try Self.url(
                        user: Self.readerRole, password: Self.readerPassword, database: Self.databaseName))
                do {
                    try await body(reader)
                } catch {
                    try? await reader.asyncShutdown()
                    throw error
                }
                try await reader.asyncShutdown()
            } catch {
                try? await Self.dropFixtures(adminSQL)
                throw error
            }
            try await Self.dropFixtures(adminSQL)
        } catch {
            try? await admin.asyncShutdown()
            throw error
        }
        try await admin.asyncShutdown()
    }

    private static func dropFixtures(_ adminSQL: any SQLDatabase) async throws {
        try await adminSQL.raw("DROP DATABASE IF EXISTS \(unsafeRaw: databaseName) WITH (FORCE)").run()
        try await adminSQL.raw("DROP ROLE IF EXISTS \(unsafeRaw: readerRole)").run()
    }

    /// owner（書き込み側）で本番と同じ全マイグレーションを適用し、本番手順と同じ GRANT を付ける。
    private static func migrateAndGrant() async throws {
        let owner = try await makeApp(url: try url(database: databaseName))
        do {
            registerBltMigrations(owner.migrations)
            try await owner.autoMigrate()
            let ownerSQL = try sql(owner)
            try await ownerSQL.raw("GRANT USAGE ON SCHEMA public TO \(unsafeRaw: readerRole)").run()
            try await ownerSQL.raw("GRANT SELECT ON ALL TABLES IN SCHEMA public TO \(unsafeRaw: readerRole)").run()
            try await ownerSQL.raw("ALTER ROLE \(unsafeRaw: readerRole) SET default_transaction_read_only = on").run()
        } catch {
            try? await owner.asyncShutdown()
            throw error
        }
        try await owner.asyncShutdown()
    }

    private func send(_ app: Application, _ path: String) async throws -> HTTPResponseStatus {
        let request = Request(
            application: app, method: .GET, url: URI(string: path), on: app.eventLoopGroup.next())
        return try await app.responder.respond(to: request).get().status
    }

    @Test(.enabled(if: postgresURL != nil, "BLT_TEST_POSTGRES_URL not set"))
    func readerRoleCannotWriteOrRunDDL() async throws {
        try await withReaderApp { reader in
            let db = try Self.sql(reader)
            await #expect(throws: (any Error).self) {
                try await db.raw("CREATE TABLE blt_reader_ddl_probe (id int)").run()
            }
            await #expect(throws: (any Error).self) {
                try await db.raw("DELETE FROM edinet_documents").run()
            }
        }
    }

    @Test(.enabled(if: postgresURL != nil, "BLT_TEST_POSTGRES_URL not set"))
    func servingRoutesWorkWithReaderRole() async throws {
        try await withReaderApp { reader in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("blt-readonly-role-\(UUID().uuidString)", isDirectory: true)
            try await registerRoutes(
                reader, context: BltServerContext(apiKey: "test-key", cacheDir: dir),
                cfAccessTeamDomain: nil)

            #expect(try await send(reader, "/healthz") == .ok)
            // 格納行が無いので 404 か空の 200 になる。5xx は DDL・書き込み・SELECT 権限漏れのどれか。
            let paths = [
                "/v1/companies/7203/financials",
                "/v1/companies/7203/waterfall",
                "/v1/companies/7203/overview",
                "/v1/companies/7203/relations",
                "/v1/companies/7203/filing-content",
                "/v1/companies/7203/breakdown",
                "/v1/companies/7203/statement",
                "/v1/companies/7203/shares",
                "/v1/screen",
                "/v1/screen/snapshot",
                "/v1/feed/updates",
            ]
            for path in paths {
                let status = try await send(reader, path)
                #expect(status.code < 500, "\(path) -> \(status.code)")
            }

            // 常駐ループの読み取り（マスターデータのポーリング・status-report）も reader で通る。
            await MasterDataRefresher().pollOnce(db: reader.db, logger: reader.logger)
            _ = try await buildIngestStatusReport(db: reader.db, listedCodes: ["7203"], priorityCodes: [])
            _ = try await loadActiveManualXbrlOverrides(on: reader.db)
        }
    }
}
