// serving 経路の code + submit_date_time 複合索引マイグレーション。
// インメモリ SQLite で適用し、sqlite_master に索引名が残ることを確認する。

import Fluent
import FluentSQLiteDriver
import SQLKit
import Testing
import Vapor

@testable import BltServerCore

private func withMigratedApp(
    includeIndexMigration: Bool = true,
    _ body: (Application) async throws -> Void
) async throws {
    let app = try await Application.make(.testing)
    do {
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateCompanyStatements())
        app.migrations.add(CreateCompanyFilingSections())
        app.migrations.add(CreateCompanyStatementNotes())
        app.migrations.add(CreateCompanySegmentBreakdowns())
        app.migrations.add(RenameCompanySegmentBreakdownsToCompanyBreakdowns())
        app.migrations.add(AddNotApplicableReasonToCompanyBreakdowns())
        if includeIndexMigration {
            app.migrations.add(AddCodeSubmitDateTimeIndexes())
        }
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private struct SQLiteIndexName: Decodable, Sendable {
    let name: String
}

private func indexNames(on sql: SQLDatabase) async throws -> Set<String> {
    let rows = try await sql.raw("SELECT name FROM sqlite_master WHERE type = 'index'")
        .all(decoding: SQLiteIndexName.self)
    return Set(rows.map(\.name))
}

private let expectedIndexNames: Set<String> = [
    "idx_company_statements_code_submit",
    "idx_company_filing_sections_code_submit",
    "idx_company_statement_notes_code_note_submit",
    "idx_company_breakdowns_code_axis_submit",
]

@Suite struct CodeSubmitIndexMigrationTests {
    @Test func addsCompositeIndexesOnServingTables() async throws {
        try await withMigratedApp { app in
            let sql = try #require(app.db as? SQLDatabase)
            let names = try await indexNames(on: sql)
            #expect(expectedIndexNames.isSubset(of: names))
        }
    }

    @Test func autoMigrateSucceedsWhenSomeIndexesAlreadyExist() async throws {
        try await withMigratedApp(includeIndexMigration: false) { app in
            let sql = try #require(app.db as? SQLDatabase)
            try await sql.raw(
                """
                CREATE INDEX idx_company_statements_code_submit
                ON company_statements (code, submit_date_time)
                """
            ).run()
            app.migrations.add(AddCodeSubmitDateTimeIndexes())
            try await app.autoMigrate()
            let names = try await indexNames(on: sql)
            #expect(expectedIndexNames.isSubset(of: names))
        }
    }
}
