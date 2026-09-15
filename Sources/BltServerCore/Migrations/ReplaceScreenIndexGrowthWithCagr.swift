// screen_index: YoY `sales_growth` と未使用の `gross_profit_margin` を外し、3 期売上 CAGR を載せる。
// CreateScreenIndex は本番適用済みのため触らず、この後続マイグレーションで列を差し替える。
// 値の再計算は `blt-server screen-rebuild`（または次回 financials ingest の派生更新）。

import Fluent

struct ReplaceScreenIndexGrowthWithCagr: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(ScreenIndex.schema)
            .field("sales_cagr_3y", .double)
            .update()
        try await database.schema(ScreenIndex.schema)
            .deleteField("sales_growth")
            .update()
        try await database.schema(ScreenIndex.schema)
            .deleteField("gross_profit_margin")
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(ScreenIndex.schema)
            .field("sales_growth", .double)
            .update()
        try await database.schema(ScreenIndex.schema)
            .field("gross_profit_margin", .double)
            .update()
        try await database.schema(ScreenIndex.schema)
            .deleteField("sales_cagr_3y")
            .update()
    }
}
