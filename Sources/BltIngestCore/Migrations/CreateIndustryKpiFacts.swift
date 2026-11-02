// industry_kpi_facts テーブルの作成（業種 KPI 取り込み）。
// 書類 1 件・業種グループ 1 つ分の KPI スナップショットを JSONB 1 セルに持つ。
// 本番にはこの PR では適用しない（blt-ingest migrate は Mac で Sorahiro の OK 後）。

import BltStoreCore
import FluentKit

struct CreateIndustryKpiFacts: AsyncMigration {
    var name: String { "BltServerCore.CreateIndustryKpiFacts" }

    func prepare(on database: Database) async throws {
        try await database.schema(IndustryKpiFact.schema)
            .field("id", .string, .identifier(auto: false))
            .field("doc_id", .string, .required)
            .field("industry_group", .string, .required)
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
        try await database.schema(IndustryKpiFact.schema).delete()
    }
}
