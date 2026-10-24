// company_icons テーブルの作成。会社1社=1行で favicon の R2 格納先メタデータを持つ。

import BltStoreCore
import FluentKit

struct CreateCompanyIcons: AsyncMigration {
    // 適用済みの記録（_fluent_migrations）と一致させるため、移動前のモジュール名で固定する。
    var name: String { "BltServerCore.CreateCompanyIcons" }

    func prepare(on database: Database) async throws {
        try await database.schema(CompanyIcon.schema)
            .field("code", .string, .identifier(auto: false))
            .field("source_url", .string, .required)
            .field("r2_object_key", .string, .required)
            .field("content_type", .string, .required)
            .field("cache_version", .string, .required)
            .field("fetched_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanyIcon.schema).delete()
    }
}
