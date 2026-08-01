// 半期分析機能の削除に伴い company_half_financials テーブルを削除する。
// revert は当時のスキーマでテーブルを再作成するのみで、削除されたデータは復元しない。

import Fluent

struct DropCompanyHalfFinancials: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("company_half_financials").delete()
    }

    func revert(on database: Database) async throws {
        try await database.schema("company_half_financials")
            .field("code", .string, .identifier(auto: false))
            .field("response", .json, .required)
            .field("cache_version", .string, .required)
            .field("requested_years", .int, .required)
            .field("high_water", .string)
            .field("updated_at", .datetime)
            .create()
    }
}
