// company_segment_breakdowns → company_breakdowns へのテーブル名変更。
// 「segment」を事業/地域を問わない共通概念の呼称として使わない方針（Breakdown 系命名への統一）に
// 合わせる。本番に既存データがあるため CREATE ではなく ALTER TABLE ... RENAME TO で列・データを
// そのまま保持する（CreateCompanySegmentBreakdowns は凍結済みのため変更しない）。

import Fluent
import SQLKit

enum RenameCompanySegmentBreakdownsToCompanyBreakdownsError: Error, CustomStringConvertible {
    case databaseIsNotSQL

    var description: String {
        "database はテーブル名変更に必要な SQLDatabase に適合していません（Postgres/SQLite 以外の driver？）"
    }
}

struct RenameCompanySegmentBreakdownsToCompanyBreakdowns: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw RenameCompanySegmentBreakdownsToCompanyBreakdownsError.databaseIsNotSQL
        }
        try await sql.alter(table: "company_segment_breakdowns")
            .rename(to: "company_breakdowns")
            .run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw RenameCompanySegmentBreakdownsToCompanyBreakdownsError.databaseIsNotSQL
        }
        try await sql.alter(table: "company_breakdowns")
            .rename(to: "company_segment_breakdowns")
            .run()
    }
}
