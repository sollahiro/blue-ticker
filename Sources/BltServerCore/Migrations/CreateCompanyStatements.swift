// company_statements テーブルの作成。有報1件=1行の抽出済み BS/PL/CF/SS を JSONB 1 セルに持つ。
// payload は .json（Postgres では JSONB、SQLite では TEXT）。read は doc_id PK 一発、または
// code 一致＋submit_date_time 降順で直近 N 件を引く（JSONB 内部はクエリしない。
// company_filing_sections と同型。docs/statement-normalization-concept.md「実装方針」）。

import Fluent

struct CreateCompanyStatements: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(CompanyStatement.schema)
            .field("doc_id", .string, .identifier(auto: false))
            .field("code", .string, .required)
            .field("submit_date_time", .string, .required)
            .field("payload", .json, .required)
            .field("cache_version", .string, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanyStatement.schema).delete()
    }
}
