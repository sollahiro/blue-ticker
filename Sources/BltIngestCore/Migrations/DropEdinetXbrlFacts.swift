// 閉じた数値 fact 投影テーブル edinet_xbrl_facts を削除する。
// 配信も他 stage も読まず、生 XBRL から再導出できる。本番は 0 行のまま未使用だった。
// DROP TABLE IF EXISTS なので、テーブルが既に無い環境でも失敗しない。
// revert は当時のスキーマでテーブルを再作成するのみで、削除されたデータは復元しない。

import FluentKit
import SQLKit

struct DropEdinetXbrlFacts: AsyncMigration {
    // 適用済みの記録（_fluent_migrations）と一致させるため、移動前のモジュール名で固定する。
    var name: String { "BltServerCore.DropEdinetXbrlFacts" }

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS \(ident: "edinet_xbrl_facts")").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("edinet_xbrl_facts")
            .field("doc_id", .string, .identifier(auto: false))
            .field("facts", .json, .required)
            .field("cache_version", .string, .required)
            .field("updated_at", .datetime)
            .create()
    }
}
