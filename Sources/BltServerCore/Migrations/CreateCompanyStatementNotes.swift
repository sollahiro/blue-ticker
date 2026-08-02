// company_statement_notes テーブルの作成（財務諸表注記取り込み）。書類1件・note_type1つ分の正規化済み
// 財務諸表注記を JSONB 1 セルに持つ。company_statements（Statement取り込み 本体）・company_breakdowns
// （内訳取り込み）とは別テーブル。財務諸表注記取り込み実装計画（stateful-tickling-ritchie plan）参照。

import Fluent

struct CreateCompanyStatementNotes: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(CompanyStatementNote.schema)
            .field("id", .string, .identifier(auto: false))
            .field("doc_id", .string, .required)
            .field("note_type", .string, .required)
            .field("code", .string, .required)
            .field("submit_date_time", .string, .required)
            .field("payload", .json, .required)
            .field("needs_review", .bool, .required)
            .field("source", .string, .required)
            .field("content_hash", .string, .required)
            .field("cache_version", .string, .required)
            .field("not_applicable_reason", .string)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanyStatementNote.schema).delete()
    }
}
