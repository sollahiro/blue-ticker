// serving 経路の code + submit_date_time 降順クエリ用の複合索引。
// company_statements / filing_sections / statement_notes / breakdowns は作成時に索引がなく、
// 銘柄あたりの全行を Seq Scan していた。edinet_documents の feed 索引と同型の後追い追加。
//
// `CREATE INDEX IF NOT EXISTS` にする。configureDatabase の autoMigrate はタイムアウト付き
// リトライで、呼び出し側が諦めたあとも元の DDL が完了しうる。途中までの索引が残ったまま
// Fluent が未記録だと、再試行の CREATE INDEX が重複名で落ちて DB 付き起動が止まる。

import Fluent
import SQLKit

struct AddCodeSubmitDateTimeIndexes: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_company_statements_code_submit
            ON company_statements (code, submit_date_time)
            """
        ).run()
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_company_filing_sections_code_submit
            ON company_filing_sections (code, submit_date_time)
            """
        ).run()
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_company_statement_notes_code_note_submit
            ON company_statement_notes (code, note_type, submit_date_time)
            """
        ).run()
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_company_breakdowns_code_axis_submit
            ON company_breakdowns (code, axis, submit_date_time)
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.drop(index: "idx_company_statements_code_submit").ifExists().run()
        try await sql.drop(index: "idx_company_filing_sections_code_submit").ifExists().run()
        try await sql.drop(index: "idx_company_statement_notes_code_note_submit").ifExists().run()
        try await sql.drop(index: "idx_company_breakdowns_code_axis_submit").ifExists().run()
    }
}
