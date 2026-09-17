// screen_index に派生契約の cache_version を足す。CreateScreenIndex は本番適用済みのため触らない。
// nullable（required は付けない）。既存行は NULL のまま残す。次回 financials ingest は
// 公開床（servable）の company_financials を screen_index へ投影する（現行 fin-vN 一致は問わない）。
// assembly_fingerprint と違い、既存行を現行版で埋めない（埋めると CAGR 再投影が起きない）。
// 未作成のときだけ ADD する（autoMigrate リトライで列だけ先にできた場合に備える）。

import Fluent
import SQLKit

struct AddCacheVersionToScreenIndex: AsyncMigration {
    func prepare(on database: Database) async throws {
        if let sql = database as? SQLDatabase,
           try await screenIndexHasColumn(sql, "cache_version")
        {
            return
        }
        try await database.schema(ScreenIndex.schema)
            .field("cache_version", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            guard try await screenIndexHasColumn(sql, "cache_version") else { return }
        }
        try await database.schema(ScreenIndex.schema)
            .deleteField("cache_version")
            .update()
    }
}
