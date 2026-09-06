// serving 経路の code + submit_date_time 降順クエリ用の複合索引。
// company_statements / filing_sections / statement_notes / breakdowns は作成時に索引がなく、
// 銘柄あたりの全行を Seq Scan していた。edinet_documents の feed 索引と同型の後追い追加。

import Fluent
import SQLKit

struct AddCodeSubmitDateTimeIndexes: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.create(index: "idx_company_statements_code_submit")
            .on(CompanyStatement.schema)
            .column("code")
            .column("submit_date_time")
            .run()
        try await sql.create(index: "idx_company_filing_sections_code_submit")
            .on(CompanyFilingSections.schema)
            .column("code")
            .column("submit_date_time")
            .run()
        try await sql.create(index: "idx_company_statement_notes_code_note_submit")
            .on(CompanyStatementNote.schema)
            .column("code")
            .column("note_type")
            .column("submit_date_time")
            .run()
        try await sql.create(index: "idx_company_breakdowns_code_axis_submit")
            .on(CompanyBreakdown.schema)
            .column("code")
            .column("axis")
            .column("submit_date_time")
            .run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.drop(index: "idx_company_statements_code_submit").ifExists().run()
        try await sql.drop(index: "idx_company_filing_sections_code_submit").ifExists().run()
        try await sql.drop(index: "idx_company_statement_notes_code_note_submit").ifExists().run()
        try await sql.drop(index: "idx_company_breakdowns_code_axis_submit").ifExists().run()
    }
}
