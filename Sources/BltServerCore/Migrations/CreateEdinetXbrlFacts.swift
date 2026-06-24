// edinet_xbrl_facts テーブルの作成。書類単位の数値 fact を JSONB 1 セルに持つ。
// facts は .json（Postgres では JSONB、SQLite では TEXT）。タグ横断が実需要化したら
// 保存済み JSONB から正規化投影を派生できる（再取得・再パース不要）。

import Fluent

struct CreateEdinetXbrlFacts: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(EdinetXbrlFacts.schema)
            .field("doc_id", .string, .identifier(auto: false))
            .field("facts", .json, .required)
            .field("cache_version", .string, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(EdinetXbrlFacts.schema).delete()
    }
}
