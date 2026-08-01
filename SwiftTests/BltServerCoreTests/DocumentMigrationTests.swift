// 書類同期 マイグレーションの検証。
// インメモリ SQLite に migration を実走させ、edinet_documents / edinet_sync_state の
// スキーマがモデルと整合し、行が round-trip することを確認する（本番は Postgres）。

import Fluent
import FluentSQLiteDriver
import Testing
import Vapor

@testable import BltServerCore

/// インメモリ SQLite で 書類同期 マイグレーションを適用した Application を生成し、
/// body 実行後に確実に shutdown する（Application.make は asyncShutdown が必須）。
private func withMigratedApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateEdinetDocument())
        app.migrations.add(CreateEdinetSyncState())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

@Suite struct DocumentMigrationTests {
    @Test func edinetDocumentRoundTripsAllFields() async throws {
        try await withMigratedApp { app in
            let doc = EdinetDocument()
            doc.id = "S100ABCD"
            doc.edinetCode = "E12345"
            doc.secCode = "72030"
            doc.filerName = "トヨタ自動車株式会社"
            doc.docTypeCode = "120"
            doc.ordinanceCode = "010"
            doc.formCode = "030000"
            doc.periodStart = "2024-04-01"
            doc.periodEnd = "2025-03-31"
            doc.submitDateTime = "2025-06-20 09:00"
            doc.docDescription = "有価証券報告書"
            try await doc.create(on: app.db)

            let fetched = try #require(try await EdinetDocument.find("S100ABCD", on: app.db))
            #expect(fetched.edinetCode == "E12345")
            #expect(fetched.secCode == "72030")
            #expect(fetched.filerName == "トヨタ自動車株式会社")
            #expect(fetched.docTypeCode == "120")
            #expect(fetched.periodEnd == "2025-03-31")
            #expect(fetched.submitDateTime == "2025-06-20 09:00")
            #expect(fetched.docDescription == "有価証券報告書")
        }
    }

    @Test func edinetDocumentAllowsNilOptionalFields() async throws {
        try await withMigratedApp { app in
            // 非上場提出者: sec_code・period 系・doc_description が欠ける。
            let doc = EdinetDocument()
            doc.id = "S100ZZZZ"
            doc.edinetCode = "E99999"
            doc.filerName = "某ファンド"
            doc.submitDateTime = "2025-01-10 14:00"
            try await doc.create(on: app.db)

            let fetched = try #require(try await EdinetDocument.find("S100ZZZZ", on: app.db))
            #expect(fetched.secCode == nil)
            #expect(fetched.docTypeCode == nil)
            #expect(fetched.periodEnd == nil)
            #expect(fetched.docDescription == nil)
        }
    }

    @Test func syncStateRoundTripsSingleRow() async throws {
        try await withMigratedApp { app in
            let state = EdinetSyncState()
            state.id = EdinetSyncState.singletonID
            state.syncedThrough = "2025-06-20"
            try await state.create(on: app.db)

            let fetched = try #require(
                try await EdinetSyncState.find(EdinetSyncState.singletonID, on: app.db))
            #expect(fetched.syncedThrough == "2025-06-20")
        }
    }
}
