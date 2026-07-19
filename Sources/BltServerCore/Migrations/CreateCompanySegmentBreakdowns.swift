// company_segment_breakdowns テーブルの作成。書類1件・軸1つ分の正規化済み事業別/地域別売上
// スナップショットを JSONB 1 セルに持つ。company_filing_sections（Stage 5, 生のsegments/geography表）
// とは別テーブル（docs/segment-normalization-concept.md「今後の検討事項5」参照）。
//
// このマイグレーションは Database.swift の app.migrations には未登録（意図的）。
// Neon への実際の migrate は今後の検討事項1（ingest/CLI/REST 配線）に着手する際、
// 別途ユーザー確認のうえ登録・適用する。

import Fluent

struct CreateCompanySegmentBreakdowns: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(CompanySegmentBreakdown.schema)
            .field("id", .string, .identifier(auto: false))
            .field("doc_id", .string, .required)
            .field("axis", .string, .required)
            .field("code", .string, .required)
            .field("submit_date_time", .string, .required)
            .field("payload", .json, .required)
            .field("needs_review", .bool, .required)
            .field("source", .string, .required)
            .field("content_hash", .string, .required)
            .field("cache_version", .string, .required)
            .field("llm_audit", .json)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanySegmentBreakdown.schema).delete()
    }
}
