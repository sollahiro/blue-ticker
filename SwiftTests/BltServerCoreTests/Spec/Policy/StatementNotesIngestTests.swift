// 財務諸表注記取り込みの汎用機構（対象選定・staleness・upsert・skip・read 床）を検証する。
// 各 note_type 固有の XBRL 抽出は `RealXbrlStatementNotesTests` / 外出しオラクル側。
//
// research_and_development note_type は 2026-08-11 に廃止し内訳取り込み breakdown 軸へ集約したため、
// financials passthrough は使わず、固定結果を返すフェイクリゾルバで機構のみを見る。

import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import Vapor

@testable import BltServerCore
@testable import BlueTickerCore

private func withMigratedApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateEdinetDocument())
        app.migrations.add(CreateCompanyFinancials())
        app.migrations.add(CreateCompanyHalfFinancials())
        app.migrations.add(AddHighWaterToCompanyFinancials())
        app.migrations.add(CreateCompanyStatementNotes())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private func seedDoc(
    _ docID: String, secCode: String, submit: String = "2025-06-20 09:00", db: Database
) async throws {
    let model = EdinetDocument()
    model.id = docID
    model.edinetCode = "E00001"
    model.secCode = secCode
    model.filerName = "テスト株式会社"
    model.docTypeCode = Api.docTypeAnnualReport
    model.submitDateTime = submit
    try await model.create(on: db)
}

/// 機構テスト用: 常に同じ resolved を返す。
private func fixedResolvedResolve(value: Double = 123.45) -> StatementNoteResolveFn {
    { _, _ in
        .resolved(
            payload: StatementNotePayload(value: value, unit: "yen_per_share"),
            source: statementNoteSourceXbrlFacts, contentHash: String(value))
    }
}

@Suite struct StatementNotesIngestTests {

    // MARK: - 解決結果の格納

    @Test func ingestStoresResolvedPayloadFromResolver() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runStatementNotesIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                noteType: statementNoteTypePerShareInformation,
                resolve: fixedResolvedResolve(value: 99.0))

            #expect(summary.stored == 1)
            let key = CompanyStatementNote.compositeID(
                docID: "S1", noteType: statementNoteTypePerShareInformation)
            let row = try #require(try await CompanyStatementNote.find(key, on: app.db))
            #expect(row.payload.value == 99.0)
            #expect(row.payload.unit == "yen_per_share")
            #expect(row.source == statementNoteSourceXbrlFacts)
        }
    }

    // MARK: - 異常系

    @Test func ingestFailsWithoutStoringWhenResolverReturnsFailed() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runStatementNotesIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                noteType: statementNoteTypePerShareInformation
            ) { _, _ in .failed }

            #expect(summary.attempted == 1)
            #expect(summary.failed == 1)
            #expect(summary.stored == 0)
            #expect(try await CompanyStatementNote.query(on: app.db).count() == 0)
        }
    }

    @Test func ingestWritesNotApplicableWhenResolverSaysNotFound() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runStatementNotesIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                noteType: statementNoteTypePerShareInformation
            ) { _, _ in .notApplicable(reason: statementNoteNotApplicableNotFound) }

            #expect(summary.notApplicable == 1)
            let key = CompanyStatementNote.compositeID(
                docID: "S1", noteType: statementNoteTypePerShareInformation)
            let row = try #require(try await CompanyStatementNote.find(key, on: app.db))
            #expect(row.source == statementNoteSourceNotApplicable)
            #expect(row.notApplicableReason == statementNoteNotApplicableNotFound)
            #expect(row.needsReview == false)
        }
    }

    // MARK: - 汎用機構（staleness / skip）

    @Test func ingestSkipsWhenStoredAtCurrentVersion() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let pre = CompanyStatementNote(docID: "S1", noteType: statementNoteTypePerShareInformation)
            pre.code = "7203"
            pre.submitDateTime = "2025-06-20 09:00"
            pre.payload = StatementNotePayload(value: 100, unit: "yen_per_share")
            pre.needsReview = false
            pre.source = statementNoteSourceXbrlFacts
            pre.contentHash = "100.0"
            pre.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypePerShareInformation)
            try await pre.create(on: app.db)

            let summary = try await runStatementNotesIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                noteType: statementNoteTypePerShareInformation
            ) { _, _ in
                Issue.record("resolver must not run for an up-to-date document")
                return .failed
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    @Test func ingestReattemptsXbrlFactsRowWhenVersionStale() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let stale = CompanyStatementNote(docID: "S1", noteType: statementNoteTypePerShareInformation)
            stale.code = "7203"
            stale.submitDateTime = "2025-06-20 09:00"
            stale.payload = StatementNotePayload(value: 100, unit: "yen_per_share")
            stale.needsReview = false
            stale.source = statementNoteSourceXbrlFacts
            stale.contentHash = "100.0"
            stale.cacheVersion = "notes-eps-v0"
            try await stale.create(on: app.db)

            let summary = try await runStatementNotesIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                noteType: statementNoteTypePerShareInformation,
                resolve: fixedResolvedResolve(value: 200.0))

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let key = CompanyStatementNote.compositeID(
                docID: "S1", noteType: statementNoteTypePerShareInformation)
            let row = try #require(try await CompanyStatementNote.find(key, on: app.db))
            #expect(row.payload.value == 200.0)
            #expect(
                row.cacheVersion == statementNoteCacheVersion(forType: statementNoteTypePerShareInformation))
        }
    }

    // MARK: - read 経路（loadStoredStatementNote）

    @Test func loadByCodeReturnsLatestDocument() async throws {
        try await withMigratedApp { app in
            let old = CompanyStatementNote(docID: "S24", noteType: statementNoteTypePerShareInformation)
            old.code = "7203"
            old.submitDateTime = "2024-06-20 09:00"
            old.payload = StatementNotePayload(value: 90, unit: "yen_per_share")
            old.needsReview = false
            old.source = statementNoteSourceXbrlFacts
            old.contentHash = "90.0"
            old.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypePerShareInformation)
            try await old.create(on: app.db)

            let latest = CompanyStatementNote(docID: "S25", noteType: statementNoteTypePerShareInformation)
            latest.code = "7203"
            latest.submitDateTime = "2025-06-20 09:00"
            latest.payload = StatementNotePayload(value: 123.45, unit: "yen_per_share")
            latest.needsReview = false
            latest.source = statementNoteSourceXbrlFacts
            latest.contentHash = "123.45"
            latest.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypePerShareInformation)
            try await latest.create(on: app.db)

            let result = try await loadStoredStatementNote(
                code: "7203", docId: nil, noteType: statementNoteTypePerShareInformation, db: app.db)
            guard case .found(let json) = result else {
                Issue.record("expected .found, got \(result)")
                return
            }
            #expect(json["doc_id"] as? String == "S25")
            #expect(json["code"] as? String == "7203")
            #expect(json["note_type"] as? String == statementNoteTypePerShareInformation)
            let note = try #require(json["note"] as? [String: Any])
            #expect(note["value"] as? Double == 123.45)
        }
    }

    @Test func loadByDocIdReturnsThatDocument() async throws {
        try await withMigratedApp { app in
            let row = CompanyStatementNote(docID: "S1", noteType: statementNoteTypePerShareInformation)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = StatementNotePayload(value: 100, unit: "yen_per_share")
            row.needsReview = false
            row.source = statementNoteSourceXbrlFacts
            row.contentHash = "100.0"
            row.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypePerShareInformation)
            try await row.create(on: app.db)

            let result = try await loadStoredStatementNote(
                code: "7203", docId: "S1", noteType: statementNoteTypePerShareInformation, db: app.db)
            guard case .found(let json) = result else {
                Issue.record("expected .found, got \(result)")
                return
            }
            #expect(json["doc_id"] as? String == "S1")
        }
    }

    @Test func loadByDocIdRejectsMismatchedCode() async throws {
        try await withMigratedApp { app in
            let row = CompanyStatementNote(docID: "S1", noteType: statementNoteTypePerShareInformation)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = StatementNotePayload(value: 100, unit: "yen_per_share")
            row.needsReview = false
            row.source = statementNoteSourceXbrlFacts
            row.contentHash = "100.0"
            row.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypePerShareInformation)
            try await row.create(on: app.db)

            let result = try await loadStoredStatementNote(
                code: "6758", docId: "S1", noteType: statementNoteTypePerShareInformation, db: app.db)
            guard case .absent = result else {
                Issue.record("expected .absent, got \(result)")
                return
            }
        }
    }

    /// 未知の note_type は行の有無に関わらず absent（将来 note_type 追加時の安全側デフォルト）。
    @Test func loadRejectsUnknownNoteType() async throws {
        try await withMigratedApp { app in
            let row = CompanyStatementNote(docID: "S1", noteType: statementNoteTypePerShareInformation)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = StatementNotePayload(value: 100, unit: "yen_per_share")
            row.needsReview = false
            row.source = statementNoteSourceXbrlFacts
            row.contentHash = "100.0"
            row.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypePerShareInformation)
            try await row.create(on: app.db)

            let result = try await loadStoredStatementNote(
                code: "7203", docId: nil, noteType: "unknown_note_type", db: app.db)
            guard case .absent = result else {
                Issue.record("expected .absent, got \(result)")
                return
            }
        }
    }

    @Test func loadReturnsNotApplicableReasonWhenRowIsNotApplicable() async throws {
        try await withMigratedApp { app in
            let row = CompanyStatementNote(docID: "S1", noteType: statementNoteTypeDividends)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = StatementNotePayload(needsReview: false, warnings: [])
            row.needsReview = false
            row.source = statementNoteSourceNotApplicable
            row.contentHash = ""
            row.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypeDividends)
            row.notApplicableReason = statementNoteNotApplicableNotFound
            try await row.create(on: app.db)

            let result = try await loadStoredStatementNote(
                code: "7203", docId: nil, noteType: statementNoteTypeDividends, db: app.db)
            guard case .notApplicable(let reason) = result else {
                Issue.record("expected .notApplicable, got \(result)")
                return
            }
            #expect(reason == statementNoteNotApplicableNotFound)
        }
    }

    @Test func loadReturnsAbsentWhenXbrlFactsRowBelowFloor() async throws {
        try await withMigratedApp { app in
            let row = CompanyStatementNote(docID: "S1", noteType: statementNoteTypePerShareInformation)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = StatementNotePayload(value: 100, unit: "yen_per_share")
            row.needsReview = false
            row.source = statementNoteSourceXbrlFacts
            row.contentHash = "100.0"
            row.cacheVersion = "notes-eps-v0"
            try await row.create(on: app.db)

            let result = try await loadStoredStatementNote(
                code: "7203", docId: nil, noteType: statementNoteTypePerShareInformation, db: app.db)
            guard case .absent = result else {
                Issue.record("expected .absent, got \(result)")
                return
            }
        }
    }

    // MARK: - servable/unservable 集計

    @Test func countServableStatementNotesSplitsByReadFloor() async throws {
        try await withMigratedApp { app in
            let servable = CompanyStatementNote(docID: "S1", noteType: statementNoteTypePerShareInformation)
            servable.code = "7203"
            servable.submitDateTime = "2025-06-20 09:00"
            servable.payload = StatementNotePayload(value: 100, unit: "yen_per_share")
            servable.needsReview = false
            servable.source = statementNoteSourceXbrlFacts
            servable.contentHash = "100.0"
            servable.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypePerShareInformation)
            try await servable.create(on: app.db)

            let unservable = CompanyStatementNote(docID: "S2", noteType: statementNoteTypePerShareInformation)
            unservable.code = "6758"
            unservable.submitDateTime = "2025-06-20 09:00"
            unservable.payload = StatementNotePayload(value: 50, unit: "yen_per_share")
            unservable.needsReview = false
            unservable.source = statementNoteSourceXbrlFacts
            unservable.contentHash = "50.0"
            unservable.cacheVersion = "notes-eps-v0"
            try await unservable.create(on: app.db)

            let coverage = try await countServableStatementNotes(db: app.db)
            #expect(coverage.servable == 1)
            #expect(coverage.unservable == 1)
        }
    }
}
