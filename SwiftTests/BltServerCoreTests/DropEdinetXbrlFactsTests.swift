// 閉じた edinet_xbrl_facts の Drop が IF EXISTS で冪等であること。
// 本番スキーマでは Create を履歴に残し、後続の Drop でテーブルを消す。

import Fluent
import FluentSQLiteDriver
import SQLKit
import Testing
import Vapor

@testable import BltIngestCore

private struct SQLiteTableName: Decodable, Sendable {
    let name: String
}

private func tableExists(_ name: String, on sql: SQLDatabase) async throws -> Bool {
    let rows = try await sql.raw(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = \(bind: name)"
    ).all(decoding: SQLiteTableName.self)
    return rows.contains { $0.name == name }
}

@Suite struct DropEdinetXbrlFactsTests {
    @Test func dropRemovesCreatedTableAndIsIdempotent() async throws {
        let app = try await Application.make(.testing)
        do {
            app.databases.use(.sqlite(.memory), as: .sqlite)
            app.migrations.add(CreateEdinetXbrlFacts())
            try await app.autoMigrate()
            let sql = try #require(app.db as? SQLDatabase)
            #expect(try await tableExists("edinet_xbrl_facts", on: sql))

            try await DropEdinetXbrlFacts().prepare(on: app.db)
            #expect(try await tableExists("edinet_xbrl_facts", on: sql) == false)

            try await DropEdinetXbrlFacts().prepare(on: app.db)
            #expect(try await tableExists("edinet_xbrl_facts", on: sql) == false)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test func registeredMigrationsLeaveNoFactsTable() async throws {
        let app = try await Application.make(.testing)
        do {
            app.databases.use(.sqlite(.memory), as: .sqlite)
            registerBltMigrations(app.migrations)
            try await app.autoMigrate()
            let sql = try #require(app.db as? SQLDatabase)
            #expect(try await tableExists("edinet_xbrl_facts", on: sql) == false)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
