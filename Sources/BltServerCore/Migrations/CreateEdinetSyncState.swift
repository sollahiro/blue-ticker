// edinet_sync_state テーブルの作成。単一行（id = 1）で同期の高水位を持つ。

import Fluent

struct CreateEdinetSyncState: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(EdinetSyncState.schema)
            .field("id", .int, .identifier(auto: false))
            .field("synced_through", .string, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(EdinetSyncState.schema).delete()
    }
}
