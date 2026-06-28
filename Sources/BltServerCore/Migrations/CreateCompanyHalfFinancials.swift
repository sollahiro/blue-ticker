// company_half_financials テーブルの作成。企業単位の計算済み半期財務サマリを JSONB 1 セルに持つ。
// company_financials（通期）と同構造。response は .json（Postgres では JSONB、SQLite では TEXT）。

import Fluent

struct CreateCompanyHalfFinancials: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(CompanyHalfFinancials.schema)
            .field("code", .string, .identifier(auto: false))
            .field("response", .json, .required)
            .field("cache_version", .string, .required)
            .field("requested_years", .int, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanyHalfFinancials.schema).delete()
    }
}
