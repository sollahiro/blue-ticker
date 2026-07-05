// EDINET マスタデータ（コードリスト CSV）の Neon 反映の DB 書き込みロジックを検証する。
// ファイル書き込み・グローバル MasterDataManager のリロードはプロセス全体の副作用を伴うため対象外。
// ここでは edinet_master_snapshot（単一行）の upsert 挙動のみを見る。

import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import Vapor

@testable import BltServerCore

private func withMigratedApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateEdinetMasterSnapshot())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

@Suite struct MasterDataSyncTests {
    @Test func upsertMasterDataSnapshotInsertsThenUpdatesSingleRow() async throws {
        try await withMigratedApp { app in
            try await upsertMasterDataSnapshot(Data("first".utf8), db: app.db)
            try await upsertMasterDataSnapshot(Data("second".utf8), db: app.db)

            let total = try await EdinetMasterSnapshot.query(on: app.db).count()
            #expect(total == 1)
            let snapshot = try #require(
                try await EdinetMasterSnapshot.find(EdinetMasterSnapshot.singletonID, on: app.db))
            #expect(snapshot.content == Data("second".utf8))
        }
    }
}
