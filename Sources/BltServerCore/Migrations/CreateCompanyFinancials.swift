// company_financials テーブルの作成。企業単位の計算済み財務サマリを JSONB 1 セルに持つ。
// response は .json（Postgres では JSONB、SQLite では TEXT）。読みは code PK 一発で、
// JSONB 内部はクエリしない（公開契約レスポンスをそのまま返すため）。

import Fluent

struct CreateCompanyFinancials: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(CompanyFinancials.schema)
            .field("code", .string, .identifier(auto: false))
            .field("response", .json, .required)
            .field("cache_version", .string, .required)
            .field("requested_years", .int, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanyFinancials.schema).delete()
    }
}
