// マイグレーション名の安定性の仕様。
// Fluent は適用済みのマイグレーションを名前（既定はモジュール名付きの型名）で記録する。
// マイグレーションを BltServerCore から BltIngestCore へ移したため、各マイグレーションは
// 名前を移動前の "BltServerCore.<型名>" に固定している。ここが崩れると、本番の migrate が
// 適用済みの全マイグレーションを未適用とみなして再実行しようとする。

import FluentKit
import FluentSQLiteDriver
import Testing
import Vapor

@testable import BltIngestCore

@Suite struct MigrationNameStabilityTests {
    @Test func everyMigrationKeepsItsAppliedName() async throws {
        let app = try await Application.make(.testing)
        do {
            app.databases.use(.sqlite(.memory), as: .sqlite)
            registerBltMigrations(app.migrations)
            // 実行はせず、未適用として並ぶマイグレーション（= 登録された全件）を取り出す。
            try await app.migrator.setupIfNeeded().get()
            let pending = try await app.migrator.previewPrepareBatch().get().map(\.0)

            #expect(pending.count == 31)
            for migration in pending {
                #expect(migration.name == "BltServerCore.\(String(describing: type(of: migration)))")
            }
            #expect(Set(pending.map(\.name)).count == pending.count)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
