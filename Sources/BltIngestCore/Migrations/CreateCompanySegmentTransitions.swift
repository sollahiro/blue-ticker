// company_segment_transitions: 隣接年の報告セグメントつなぎ（判断の訂正に再 ingest は不要）。

import BltStoreCore
import FluentKit
import SQLKit

struct CreateCompanySegmentTransitions: AsyncMigration {
    var name: String { "BltServerCore.CreateCompanySegmentTransitions" }

    func prepare(on database: Database) async throws {
        try await database.schema(CompanySegmentTransition.schema)
            .field("id", .string, .identifier(auto: false))
            .field("code", .string, .required)
            .field("fy_end", .string, .required)
            .field("old_key", .string)
            .field("new_key", .string)
            .field("decision", .string, .required)
            .field("basis", .string, .required)
            .field("matched", .string, .required)
            .field("needs_review", .bool, .required)
            .field("updated_at", .datetime)
            .ignoreExisting()
            .create()
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_company_segment_transitions_code_fy
            ON company_segment_transitions (code, fy_end)
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanySegmentTransition.schema).delete()
    }
}
