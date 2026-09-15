// screen_index の CAGR 列追加マイグレーション。旧 YoY / 粗利率列は物理テーブルに残す。

import Fluent
import FluentSQLiteDriver
import SQLKit
import Testing
import Vapor

@testable import BltServerCore

private func withScreenIndexApp(
    includeCagrMigration: Bool = true,
    _ body: (Application) async throws -> Void
) async throws {
    let app = try await Application.make(.testing)
    do {
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateScreenIndex())
        if includeCagrMigration {
            app.migrations.add(ReplaceScreenIndexGrowthWithCagr())
        }
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private func columnNames(on sql: SQLDatabase) async throws -> Set<String> {
    let rows = try await sql.raw("PRAGMA table_info(screen_index)").all()
    return Set(try rows.map { try $0.decode(column: "name", as: String.self) })
}

@Suite struct ScreenIndexMigrationTests {
    @Test func addsSalesCagr3yWithoutDroppingLegacyColumns() async throws {
        try await withScreenIndexApp { app in
            let sql = try #require(app.db as? SQLDatabase)
            let names = try await columnNames(on: sql)
            #expect(names.contains("sales_cagr_3y"))
            #expect(names.contains("sales_growth"))
            #expect(names.contains("gross_profit_margin"))
        }
    }

    @Test func prepareIsIdempotentWhenSalesCagr3yAlreadyExists() async throws {
        try await withScreenIndexApp(includeCagrMigration: false) { app in
            let sql = try #require(app.db as? SQLDatabase)
            try await sql.raw("ALTER TABLE screen_index ADD COLUMN sales_cagr_3y DOUBLE").run()
            try await ReplaceScreenIndexGrowthWithCagr().prepare(on: app.db)
            let names = try await columnNames(on: sql)
            #expect(names.contains("sales_cagr_3y"))
            #expect(names.contains("sales_growth"))
            #expect(names.contains("gross_profit_margin"))
        }
    }
}
