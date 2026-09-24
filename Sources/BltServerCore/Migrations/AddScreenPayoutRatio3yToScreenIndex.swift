// screen_index: 高還元の年次配当性向 3 期（表示列）。既存マイグレーションは本番適用済みのため触らない。
// 列は nullable。平均 `payout_ratio` の意味変更（最新 FY → 直近 3 期算術平均）は
// `screenIndexVersion` = screen-v4 の stamp 不一致で全件 rebuild する。
// 列ごとに未作成のときだけ ADD する（autoMigrate リトライ対策）。
// 許可リストには載せない（`payout_ratio` 投影時に `payout_ratio_3y` として応答するだけ）。

import Fluent
import SQLKit

struct AddScreenPayoutRatio3yToScreenIndex: AsyncMigration {
    static let columns = [
        "payout_ratio_y1", "payout_ratio_y2", "payout_ratio_y3",
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
