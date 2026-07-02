// company_filing_sections テーブルの作成。有報1件=1行の抽出済みセクション本文を JSONB 1 セルに持つ。
// payload は .json（Postgres では JSONB、SQLite では TEXT）。read は doc_id PK 一発、または
// code 一致＋submit_date_time 降順で最新1件を引く（JSONB 内部はクエリしない）。

import Fluent

struct CreateCompanyFilingSections: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(CompanyFilingSections.schema)
            .field("doc_id", .string, .identifier(auto: false))
            .field("code", .string, .required)
            .field("submit_date_time", .string, .required)
            .field("payload", .json, .required)
            .field("cache_version", .string, .required)
            .field("section_keys", .string, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanyFilingSections.schema).delete()
    }
}
