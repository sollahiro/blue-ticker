// screen_index: 3 期売上 CAGR 列を足す。CreateScreenIndex は本番適用済みのため触らない。
// 旧 `sales_growth` / `gross_profit_margin` は物理テーブルに nullable のまま残す（本番列の
// deleteField はしない）。許可リスト・書き込み・GET /v1/screen からは除外済み。
// `sales_cagr_3y` は未作成のときだけ ADD する（autoMigrate リトライで列だけ先にできた場合に備える）。
// 値の再計算は `blt-server screen-rebuild`（または次回 financials ingest の派生更新）。

import Fluent
import SQLKit

struct ReplaceScreenIndexGrowthWithCagr: AsyncMigration {
    func prepare(on database: Database) async throws {
        if let sql = database as? SQLDatabase,
           try await screenIndexHasColumn(sql, "sales_cagr_3y")
        {
            return
        }
        try await database.schema(ScreenIndex.schema)
            .field("sales_cagr_3y", .double)
            .update()
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            guard try await screenIndexHasColumn(sql, "sales_cagr_3y") else { return }
        }
        try await database.schema(ScreenIndex.schema)
            .deleteField("sales_cagr_3y")
            .update()
    }
}

private func screenIndexHasColumn(_ sql: SQLDatabase, _ column: String) async throws -> Bool {
    if sql.dialect.name == "sqlite" {
        let rows = try await sql.raw("PRAGMA table_info(screen_index)").all()
        for row in rows {
            if (try? row.decode(column: "name", as: String.self)) == column { return true }
        }
        return false
    }
    let present = try await sql.raw(
        """
        SELECT 1 AS present
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'screen_index'
          AND column_name = \(bind: column)
        LIMIT 1
        """
    ).first(decodingColumn: "present", as: Int.self)
    return present != nil
}
