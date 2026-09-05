// company_overviews テーブルの作成。有報1件=1行の短い会社説明を JSONB 1 セルに持つ。
// Filing 公開 `texts` には載せない。ingest stage / serving は未配線。

import Fluent

struct CreateCompanyOverviews: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(CompanyOverview.schema)
            .field("doc_id", .string, .identifier(auto: false))
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
        try await database.schema(CompanyOverview.schema).delete()
    }
}
