// screen_index テーブルの作成（BLT-49）。company_financials から派生する検索用 Read Model。
// 1 社 1 行（最新 FY）。数値列は Summary の許可リスト指標＋派生 sales_growth。null は「無い」（0 にしない）。
// 公開 REST は `GET /v1/screen`。既定ソート roic 降順のため roic に索引を張る。

import Fluent
import SQLKit

struct CreateScreenIndex: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(ScreenIndex.schema)
            .field("code", .string, .identifier(auto: false))
            .field("name", .string, .required)
            .field("market", .string, .required)
            .field("sector", .string, .required)
            .field("period_end", .string, .required)
            .field("sales", .double)
            .field("sales_growth", .double)
            .field("gross_profit_margin", .double)
            .field("operating_margin", .double)
            .field("roic", .double)
            .field("roe", .double)
            .field("net_de", .double)
            .field("updated_at", .datetime)
            .create()
        guard let sql = database as? SQLDatabase else { return }
        try await sql.create(index: "idx_screen_index_roic").on(ScreenIndex.schema).column("roic").run()
        try await sql.create(index: "idx_screen_index_sector").on(ScreenIndex.schema).column("sector").run()
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.drop(index: "idx_screen_index_roic").ifExists().run()
            try await sql.drop(index: "idx_screen_index_sector").ifExists().run()
        }
        try await database.schema(ScreenIndex.schema).delete()
    }
}
