// screen_index: 改善プリセットの前年差（yoy）列を 3 期年平均変化幅（pp/年）列へ置き換える。
// `operating_margin_yoy` / `roic_yoy` を DROP し、`operating_margin_cagr_3y` /
// `roic_cagr_3y` を ADD する。契約 `screenIndexVersion` は screen-v3 のまま
// （索引は全消去→再 ingest で整合させる運用のためバンプしない）。
// 列ごとに未作成／残存のときだけ ADD・DROP する（autoMigrate リトライ対策）。
//
// 指標の定義・null 方針は `ScreenContract.swift`（直近の非欠測 3 期で（最新 − 最古）÷ 2）。

import Fluent
import SQLKit

struct AddScreenCagrMetricsToScreenIndex: AsyncMigration {
    static let columns = [
        "operating_margin_cagr_3y", "roic_cagr_3y",
    ]

    static let droppedColumns = [
        "operating_margin_yoy", "roic_yoy",
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
        for column in Self.droppedColumns {
            if let sql = database as? SQLDatabase {
                guard try await screenIndexHasColumn(sql, column) else { continue }
            }
            try await database.schema(ScreenIndex.schema)
                .deleteField(.init(stringLiteral: column))
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
        for column in Self.droppedColumns {
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
}
