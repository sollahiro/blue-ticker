// 数値 fact 取り込みの DB ロジック（候補選定・staleness 判定・upsert・limit）を検証する。
// 取得・パース（parseXbrlFactIndex）は EDINET 依存のため、フェイクパーサを注入してネットワーク非依存で見る。

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
        app.migrations.add(CreateEdinetXbrlFacts())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private func seedDocument(_ docID: String, submit: String, db: Database) async throws {
    let model = EdinetDocument()
    model.id = docID
    model.edinetCode = "E00001"
    model.secCode = "72030"
    model.filerName = "テスト株式会社"
    model.docTypeCode = "120"
    model.submitDateTime = submit
    try await model.create(on: db)
}

private func payload(_ value: Double) -> XbrlFactIndexPayload {
    ["NetSales": ["CurrentYearDuration": XbrlFactRecord(value: value, consolidation: "consolidated")]]
}

@Suite struct FactsIngestTests {
    @Test func ingestStoresFactsForAllUnparsedDocuments() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", submit: "2025-06-20 09:00", db: app.db)
            try await seedDocument("S2", submit: "2025-06-21 09:00", db: app.db)

            let summary = try await runFactsIngest(db: app.db, limit: nil) { _ in payload(100) }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
            #expect(summary.skipped == 0)
            #expect(summary.failed == 0)
            #expect(try await EdinetXbrlFacts.query(on: app.db).count() == 2)
        }
    }

    @Test func ingestSkipsDocumentsAlreadyParsedAtCurrentVersion() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", submit: "2025-06-20 09:00", db: app.db)
            // 現行バージョンでパース済みの行を先に置く → skip される。
            let pre = EdinetXbrlFacts()
            pre.id = "S1"
            pre.facts = payload(1)
            pre.cacheVersion = xbrlFactsCacheVersion
            try await pre.create(on: app.db)

            let summary = try await runFactsIngest(db: app.db, limit: nil) { _ in
                Issue.record("parser must not run for a freshly parsed document")
                return payload(999)
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
            #expect(summary.stored == 0)
        }
    }

    @Test func ingestReparsesWhenStoredVersionMismatches() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", submit: "2025-06-20 09:00", db: app.db)
            // 旧バージョンの行 → 再パース対象。
            let stale = EdinetXbrlFacts()
            stale.id = "S1"
            stale.facts = payload(1)
            stale.cacheVersion = "0.0.0"
            try await stale.create(on: app.db)

            let summary = try await runFactsIngest(db: app.db, limit: nil) { _ in payload(42) }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            #expect(summary.skipped == 0)
            let row = try #require(try await EdinetXbrlFacts.find("S1", on: app.db))
            #expect(row.facts["NetSales"]?["CurrentYearDuration"]?.value == 42)
            #expect(row.cacheVersion == xbrlFactsCacheVersion)
            #expect(try await EdinetXbrlFacts.query(on: app.db).count() == 1)
        }
    }

    @Test func ingestCountsParseFailuresWithoutStoring() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", submit: "2025-06-20 09:00", db: app.db)

            let summary = try await runFactsIngest(db: app.db, limit: nil) { _ in nil }

            #expect(summary.attempted == 1)
            #expect(summary.failed == 1)
            #expect(summary.stored == 0)
            #expect(try await EdinetXbrlFacts.query(on: app.db).count() == 0)
        }
    }

    @Test func ingestLimitsNewlyAttemptedDocuments() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", submit: "2025-06-20 09:00", db: app.db)
            try await seedDocument("S2", submit: "2025-06-21 09:00", db: app.db)
            try await seedDocument("S3", submit: "2025-06-22 09:00", db: app.db)

            let summary = try await runFactsIngest(db: app.db, limit: 2) { _ in payload(7) }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
            #expect(try await EdinetXbrlFacts.query(on: app.db).count() == 2)
        }
    }

    @Test func ingestPrioritizesMissingBeforeStaleWhenLimited() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", submit: "2025-06-20 09:00", db: app.db)  // stale existing
            try await seedDocument("S2", submit: "2025-06-21 09:00", db: app.db)  // missing

            let stale = EdinetXbrlFacts()
            stale.id = "S1"
            stale.facts = payload(1)
            stale.cacheVersion = "0.0.0"
            try await stale.create(on: app.db)

            let summary = try await runFactsIngest(db: app.db, limit: 1) { _ in payload(9) }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            #expect(try await EdinetXbrlFacts.find("S2", on: app.db) != nil)
            let staleAfter = try #require(try await EdinetXbrlFacts.find("S1", on: app.db))
            #expect(staleAfter.cacheVersion == "0.0.0")  // stale より先に空白を埋める
        }
    }

    @Test func ingestPrefersCachedDocWhenLimitCutsOff() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", submit: "2025-06-22 09:00", db: app.db)
            try await seedDocument("S2", submit: "2025-06-20 09:00", db: app.db)

            let summary = try await runFactsIngest(
                db: app.db, limit: 1, cachedDocIDs: ["S2"]
            ) { _ in payload(9) }

            #expect(summary.attempted == 1)
            #expect(try await EdinetXbrlFacts.find("S2", on: app.db) != nil)
            #expect(try await EdinetXbrlFacts.find("S1", on: app.db) == nil)
        }
    }
}
