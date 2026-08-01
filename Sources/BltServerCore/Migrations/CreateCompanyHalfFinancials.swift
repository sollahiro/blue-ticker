// company_half_financials テーブルの作成（凍結済み・変更しない）。
// 半期分析機能は削除済み（テーブル自体は DropCompanyHalfFinancials で削除）。
// Model 型は削除済みのため、スキーマ名は当時と同じ値をリテラルで参照する。

import Fluent

struct CreateCompanyHalfFinancials: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("company_half_financials")
            .field("code", .string, .identifier(auto: false))
            .field("response", .json, .required)
            .field("cache_version", .string, .required)
            .field("requested_years", .int, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("company_half_financials").delete()
    }
}
