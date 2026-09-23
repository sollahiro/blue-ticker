// screen_index: 改善プリセットの 3 期年平均変化幅（pp/年）列 `operating_margin_cagr_3y` /
// `roic_cagr_3y` を足す。既存マイグレーションは本番適用済みのため触らない。
// 旧 `operating_margin_yoy` / `roic_yoy` は物理テーブルに nullable のまま残す（本番列の
// deleteField はしない。ローリングデプロイ中の旧マシンとロールバック先が列を SELECT するため）。
// 許可リスト・書き込み・GET /v1/screen からは除外済み。
// 列ごとに未作成のときだけ ADD する（autoMigrate リトライ対策）。
//
// 契約 `screenIndexVersion` は screen-v3 のまま。値の再計算は次回 financials ingest
// （旧 stamp の行を検出して全件 rebuild）または `blt-server screen-rebuild`。
// 指標の定義・null 方針は `ScreenContract.swift`（直近の非欠測 3 期で（最新 − 最古）÷ 2）。

import Fluent
import SQLKit

struct AddScreenCagrMetricsToScreenIndex: AsyncMigration {
    static let columns = [
        "operating_margin_cagr_3y", "roic_cagr_3y",
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
