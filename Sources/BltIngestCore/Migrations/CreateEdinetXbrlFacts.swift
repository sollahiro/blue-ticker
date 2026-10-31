// edinet_xbrl_facts テーブルの作成（凍結済み・変更しない）。
// 数値 fact 投影は閉じ、テーブル自体は DropEdinetXbrlFacts で削除する。
// Model 型は削除済みのため、スキーマ名は当時と同じ値をリテラルで参照する。
// 適用済みの記録（_fluent_migrations）を壊さないよう、この Create はリストに残す。

import FluentKit

struct CreateEdinetXbrlFacts: AsyncMigration {
    // 適用済みの記録（_fluent_migrations）と一致させるため、移動前のモジュール名で固定する。
    var name: String { "BltServerCore.CreateEdinetXbrlFacts" }

    func prepare(on database: Database) async throws {
        try await database.schema("edinet_xbrl_facts")
            .field("doc_id", .string, .identifier(auto: false))
            .field("facts", .json, .required)
            .field("cache_version", .string, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("edinet_xbrl_facts").delete()
    }
}
