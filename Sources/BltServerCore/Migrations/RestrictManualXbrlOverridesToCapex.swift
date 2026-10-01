// 廃止した policy_holding_securities 上書き行を消し、item CHECK を capex のみにする。
// 行削除を先にしないと、制約を狭めた時点で残行があると autoMigrate が失敗する。
// 再実行できる形（DELETE は冪等、制約は無いときだけ付け直す）。

import Fluent
import SQLKit

struct RestrictManualXbrlOverridesToCapex: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            """
            DELETE FROM manual_xbrl_overrides
            WHERE item = 'policy_holding_securities'
            """
        ).run()
        if sql.dialect.name == "postgresql" {
            try await sql.raw(
                """
                DO $$
                BEGIN
                    IF EXISTS (
                        SELECT 1 FROM pg_constraint
                        WHERE conname = 'manual_xbrl_overrides_item_check'
                    ) THEN
                        ALTER TABLE manual_xbrl_overrides
                        DROP CONSTRAINT manual_xbrl_overrides_item_check;
                    END IF;
                    ALTER TABLE manual_xbrl_overrides
                    ADD CONSTRAINT manual_xbrl_overrides_item_check
                    CHECK (item IN ('capex'));
                END $$
                """
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase, sql.dialect.name == "postgresql" else { return }
        try await sql.raw(
            """
            DO $$
            BEGIN
                IF EXISTS (
                    SELECT 1 FROM pg_constraint
                    WHERE conname = 'manual_xbrl_overrides_item_check'
                ) THEN
                    ALTER TABLE manual_xbrl_overrides
                    DROP CONSTRAINT manual_xbrl_overrides_item_check;
                END IF;
                ALTER TABLE manual_xbrl_overrides
                ADD CONSTRAINT manual_xbrl_overrides_item_check
                CHECK (item IN ('capex', 'policy_holding_securities'));
            END $$
            """
        ).run()
    }
}
