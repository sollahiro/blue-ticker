// screen_index: screen-v3（高CF・高効率・改善・高還元）の 6 指標列を足す。既存マイグレーションは本番適用済みのため触らない。
// 列はすべて nullable（既存行は NULL＝未投影のまま）。値の再計算は次回 financials ingest
// （公開床 servable の company_financials を投影。旧 stamp の行は検出して全件 rebuild）または
// `blt-server screen-rebuild`。列ごとに未作成のときだけ ADD する（autoMigrate リトライ対策）。
//
// 指標の定義・null 方針は `ScreenContract.swift`（cfo / cfo_margin / fcf /
// operating_margin_yoy / roic_yoy / payout_ratio）。

import Fluent
import SQLKit

struct AddScreenV3MetricsToScreenIndex: AsyncMigration {
    static let columns = [
        "cfo", "cfo_margin", "fcf", "operating_margin_yoy", "roic_yoy", "payout_ratio",
    ]

    func prepare(on database: Database) async throws {
        for column in Self.columns {
            if let sql = database as? SQLDatabase,
                try await screenIndexHasColumn(sql, column)
            {
                continue
            }
            try await database.schema(ScreenIndex.schema)
                .field(.init(stringLiteral: column), .double)
                .update()
        }
    }

    func revert(on database: Database) async throws {
        for column in Self.columns {
            if let sql = database as? SQLDatabase {
                guard try await screenIndexHasColumn(sql, column) else { continue }
            }
            try await database.schema(ScreenIndex.schema)
                .deleteField(.init(stringLiteral: column))
                .update()
        }
    }
}
