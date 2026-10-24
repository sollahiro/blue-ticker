import BltStoreCore
import FluentKit

/// edinet_master_snapshot テーブルの作成。単一行（id = 1）で CSV の生バイト列を保持する。
struct CreateEdinetMasterSnapshot: AsyncMigration {
    // 適用済みの記録（_fluent_migrations）と一致させるため、移動前のモジュール名で固定する。
    var name: String { "BltServerCore.CreateEdinetMasterSnapshot" }

    func prepare(on database: Database) async throws {
        try await database.schema(EdinetMasterSnapshot.schema)
            .field("id", .int, .identifier(auto: false))
            .field("content", .data, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(EdinetMasterSnapshot.schema).delete()
    }
}
