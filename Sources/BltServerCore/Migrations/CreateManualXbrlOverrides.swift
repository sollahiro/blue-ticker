// 手動 XBRL 上書きテーブル。有効行は (edinet_code, period_end, item) の部分ユニーク。
// CHECK は Postgres のみ（SQLite テストはコード側の閉集合で担保）。
// CREATE INDEX IF NOT EXISTS にする。autoMigrate のタイムアウト付きリトライで
// 途中までの DDL が残ると再試行が重複名で落ちるため。

import Fluent
import SQLKit

struct CreateManualXbrlOverrides: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(ManualXbrlOverrideRow.schema)
            .id()
            .field("edinet_code", .string, .required)
            .field("period_end", .string, .required)
            .field("item", .string, .required)
            .field("payload", .json, .required)
            .field("source_doc_id", .string, .required)
            .field("source_page", .string, .required)
            .field("reason", .string, .required)
            .field("created_by", .string, .required)
            .field("created_at", .datetime)
            .field("revoked_at", .datetime)
            .create()

        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS manual_xbrl_overrides_active_uniq
            ON manual_xbrl_overrides (edinet_code, period_end, item)
            WHERE revoked_at IS NULL
            """
        ).run()
        if sql.dialect.name == "postgresql" {
            try await sql.raw(
                """
                DO $$
                BEGIN
                    IF NOT EXISTS (
                        SELECT 1 FROM pg_constraint
                        WHERE conname = 'manual_xbrl_overrides_item_check'
                    ) THEN
                        ALTER TABLE manual_xbrl_overrides
                        ADD CONSTRAINT manual_xbrl_overrides_item_check
                        CHECK (item IN ('capex', 'policy_holding_securities'));
                    END IF;
                END $$
                """
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.drop(index: "manual_xbrl_overrides_active_uniq").ifExists().run()
        }
        try await database.schema(ManualXbrlOverrideRow.schema).delete()
    }
}
