// Stage 1 同期の DB 書き込みロジック（ネットワーク非依存部）を検証する。
// 取得（fetchDocumentsForSync）は EDINET 依存のため対象外。upsert・高水位更新・開始日解決を見る。

import BlueTickerCore
import Fluent
import FluentSQLiteDriver
import Testing
import Vapor

@testable import BltServerCore

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

private func record(
    _ docID: String, filerName: String = "テスト株式会社", secCode: String? = "72030"
) -> EdinetDocumentRecord {
    EdinetDocumentRecord(
        docID: docID, edinetCode: "E00001", secCode: secCode, filerName: filerName,
        docTypeCode: "120", ordinanceCode: "010", formCode: "030000",
        periodStart: "2024-04-01", periodEnd: "2025-03-31",
        submitDateTime: "2025-06-20 09:00", docDescription: "有価証券報告書")
}

@Suite struct Stage1SyncTests {
    @Test func applyDocumentsCreatesNewRows() async throws {
        try await withMigratedApp { app in
            let counts = try await applyDocuments(
                [record("S1"), record("S2")], db: app.db)
            #expect(counts.created == 2)
            #expect(counts.updated == 0)
            let total = try await EdinetDocument.query(on: app.db).count()
            #expect(total == 2)
        }
    }

    @Test func applyDocumentsUpdatesExistingByDocID() async throws {
        try await withMigratedApp { app in
            _ = try await applyDocuments([record("S1", filerName: "旧名")], db: app.db)
            // 同じ docID を別の filerName で再投入 → 更新（重複行は作らない）。
            let counts = try await applyDocuments([record("S1", filerName: "新名")], db: app.db)
            #expect(counts.created == 0)
            #expect(counts.updated == 1)

            let total = try await EdinetDocument.query(on: app.db).count()
            #expect(total == 1)
            let row = try #require(try await EdinetDocument.find("S1", on: app.db))
            #expect(row.filerName == "新名")
        }
    }

    @Test func upsertSyncStateInsertsThenUpdatesSingleRow() async throws {
        try await withMigratedApp { app in
            try await upsertSyncState(syncedThrough: "2025-06-01", db: app.db)
            try await upsertSyncState(syncedThrough: "2025-06-20", db: app.db)

            let total = try await EdinetSyncState.query(on: app.db).count()
            #expect(total == 1)
            let state = try #require(
                try await EdinetSyncState.find(EdinetSyncState.singletonID, on: app.db))
            #expect(state.syncedThrough == "2025-06-20")
        }
    }

    @Test func loadStoredFilingRecordsMatchesBySecCodePrefix() async throws {
        try await withMigratedApp { app in
            // 4 桁コード "8591" は 5 桁 secCode "85910" に前方一致。別銘柄 "12340" は除外。
            _ = try await applyDocuments(
                [
                    record("MATCH1", secCode: "85910"),
                    record("MATCH2", secCode: "85910"),
                    record("OTHER", secCode: "12340"),
                ], db: app.db)

            let records = try await loadStoredFilingRecords(code: "8591", db: app.db)
            #expect(Set(records.map(\.docID)) == ["MATCH1", "MATCH2"])
            // 5 桁コードを渡しても prefix(4) で正規化される。
            let viaFive = try await loadStoredFilingRecords(code: "85910", db: app.db)
            #expect(Set(viaFive.map(\.docID)) == ["MATCH1", "MATCH2"])
        }
    }

    @Test func loadStoredFilingRecordsReturnsEmptyWhenNoMatch() async throws {
        try await withMigratedApp { app in
            _ = try await applyDocuments([record("S1", secCode: "85910")], db: app.db)
            // 未同期銘柄は空（呼び出し側はライブ探索へフォールバックする）。
            let records = try await loadStoredFilingRecords(code: "9999", db: app.db)
            #expect(records.isEmpty)
        }
    }

    @Test func resolveStartDatePrefersExplicitThenStateThenThrows() async throws {
        try await withMigratedApp { app in
            // 明示指定が最優先。
            let explicit = try await resolveStartDate(from: "2025-01-01", db: app.db)
            #expect(explicit == "2025-01-01")

            // 状態なし・未指定 → missingStartDate。
            await #expect(throws: Stage1SyncError.self) {
                _ = try await resolveStartDate(from: nil, db: app.db)
            }

            // 状態あり・未指定 → synced_through を採用。
            try await upsertSyncState(syncedThrough: "2025-05-10", db: app.db)
            let fromState = try await resolveStartDate(from: nil, db: app.db)
            #expect(fromState == "2025-05-10")
        }
    }
}
