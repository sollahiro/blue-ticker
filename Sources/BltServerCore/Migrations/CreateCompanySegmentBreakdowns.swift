// company_segment_breakdowns テーブルの作成（初回名。後に RenameCompanySegmentBreakdownsToCompanyBreakdowns
// で company_breakdowns へ改名。docs/breakdown-normalization-concept.md「今後の検討事項5」参照）。
// 書類1件・軸1つ分の正規化済み事業別/地域別売上スナップショットを JSONB 1 セルに持つ。
// company_filing_sections（有報セクション取り込み, 生のsegments/geography表）とは別テーブル。
//
// 本番適用済みのため凍結: テーブル名は現行モデル（CompanyBreakdown）の schema に依存せず
// リテラル文字列で固定する（モデル名が変わっても本マイグレーションの意味は変えない）。
//
// Database.swift の app.migrations に登録済み（今後の検討事項1、business/geography 両軸の
// ingest/CLI/REST/MCP 配線）。axis="business"/"geography" の行が書き込まれる。

import Fluent

private let legacyCompanySegmentBreakdownsSchema = "company_segment_breakdowns"

struct CreateCompanySegmentBreakdowns: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(legacyCompanySegmentBreakdownsSchema)
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
        try await database.schema(legacyCompanySegmentBreakdownsSchema).delete()
    }
}
