// Stage 5 取り込みの DB ロジック（対象選定＝上場×有報×直近N年・staleness 判定・upsert・limit）と
// read 経路（loadStoredFilingSections の code 最新／doc_id 指定・バージョンゲート・sections 絞り込み）を検証する。
// 抽出（extractFilingSections）は EDINET 依存のため、フェイク抽出器を注入してネットワーク非依存で見る。

import BlueTickerCore
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
        app.migrations.add(CreateEdinetDocument())
        app.migrations.add(CreateCompanyFilingSections())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private func seedDoc(
    _ docID: String, secCode: String?, docType: String? = Api.docTypeAnnualReport,
    submit: String = "2025-06-20 09:00", db: Database
) async throws {
    let model = EdinetDocument()
    model.id = docID
    model.edinetCode = "E00001"
    model.secCode = secCode
    model.filerName = "テスト株式会社"
    model.docTypeCode = docType
    model.submitDateTime = submit
    try await model.create(on: db)
}

private func fakePayload(_ marker: String = "risk") -> FilingSectionsPayload {
    FilingSectionsPayload(
        texts: ["business_risks": marker, "mda": ""],
        specials: ["segments": SegmentPayload(method: "not_found", tables: [], facts: [])])
}

private let keys = "business_risks,mda,segments"

@Suite struct Stage5IngestTests {

    // MARK: - 対象選定・取り込み

    @Test func ingestStoresSectionsForListedAnnualReports() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)

            let summary = try await runStage5Ingest(
                db: app.db, listedCodes: ["7203", "6758"], years: 3, sectionKeys: keys, limit: nil
            ) { _ in fakePayload() }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
            #expect(try await CompanyFilingSections.find("S1", on: app.db) != nil)
            let row = try #require(try await CompanyFilingSections.find("S2", on: app.db))
            #expect(row.code == "6758")
        }
    }

    @Test func ingestExcludesNonListedCompanies() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)  // listed
            try await seedDoc("S2", secCode: "99990", db: app.db)  // not in listedCodes

            let summary = try await runStage5Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, sectionKeys: keys, limit: nil
            ) { _ in fakePayload() }

            #expect(summary.attempted == 1)
            #expect(try await CompanyFilingSections.find("S2", on: app.db) == nil)
        }
    }

    @Test func ingestExcludesNonAnnualDocTypes() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)  // 有報120
            try await seedDoc("S2", secCode: "72030", docType: "160", db: app.db)  // 半期
            try await seedDoc("S3", secCode: "72030", docType: nil, db: app.db)

            let summary = try await runStage5Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, sectionKeys: keys, limit: nil
            ) { _ in fakePayload() }

            #expect(summary.attempted == 1)
            #expect(try await CompanyFilingSections.find("S1", on: app.db) != nil)
            #expect(try await CompanyFilingSections.find("S2", on: app.db) == nil)
        }
    }

    @Test func ingestSkipsInvalidSecCode() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: nil, db: app.db)
            try await seedDoc("S2", secCode: "1234", db: app.db)  // 5 桁でない
            try await seedDoc("S3", secCode: "12345", db: app.db)  // 末尾 0 でない

            let summary = try await runStage5Ingest(
                db: app.db, listedCodes: ["1234", "1234"], years: 3, sectionKeys: keys, limit: nil
            ) { _ in fakePayload() }

            #expect(summary.attempted == 0)
            #expect(try await CompanyFilingSections.query(on: app.db).count() == 0)
        }
    }

    @Test func ingestKeepsOnlyRecentNAnnualReportsPerCompany() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S22", secCode: "72030", submit: "2022-06-20 09:00", db: app.db)
            try await seedDoc("S23", secCode: "72030", submit: "2023-06-20 09:00", db: app.db)
            try await seedDoc("S24", secCode: "72030", submit: "2024-06-20 09:00", db: app.db)
            try await seedDoc("S25", secCode: "72030", submit: "2025-06-20 09:00", db: app.db)

            let summary = try await runStage5Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, sectionKeys: keys, limit: nil
            ) { _ in fakePayload() }

            #expect(summary.attempted == 3)
            #expect(summary.stored == 3)
            #expect(try await CompanyFilingSections.find("S25", on: app.db) != nil)
            #expect(try await CompanyFilingSections.find("S24", on: app.db) != nil)
            #expect(try await CompanyFilingSections.find("S23", on: app.db) != nil)
            #expect(try await CompanyFilingSections.find("S22", on: app.db) == nil)  // 4件目は対象外
        }
    }

    @Test func ingestSkipsWhenStoredAtCurrentVersionAndSectionKeys() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let pre = CompanyFilingSections()
            pre.id = "S1"
            pre.code = "7203"
            pre.submitDateTime = "2025-06-20 09:00"
            pre.payload = fakePayload("old")
            pre.cacheVersion = filingSectionsCacheVersion
            pre.sectionKeys = keys
            try await pre.create(on: app.db)

            let summary = try await runStage5Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, sectionKeys: keys, limit: nil
            ) { _ in
                Issue.record("extractor must not run for an up-to-date document")
                return fakePayload()
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    @Test func ingestReextractsWhenVersionMismatches() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let stale = CompanyFilingSections()
            stale.id = "S1"
            stale.code = "7203"
            stale.submitDateTime = "2025-06-20 09:00"
            stale.payload = fakePayload("stale")
            stale.cacheVersion = "old-version"
            stale.sectionKeys = keys
            try await stale.create(on: app.db)

            let summary = try await runStage5Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, sectionKeys: keys, limit: nil
            ) { _ in fakePayload("fresh") }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyFilingSections.find("S1", on: app.db))
            #expect(row.cacheVersion == filingSectionsCacheVersion)
            #expect(row.payload.texts["business_risks"] == "fresh")
        }
    }

    @Test func ingestReextractsWhenSectionKeysMismatch() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let pre = CompanyFilingSections()
            pre.id = "S1"
            pre.code = "7203"
            pre.submitDateTime = "2025-06-20 09:00"
            pre.payload = fakePayload("old")
            pre.cacheVersion = filingSectionsCacheVersion
            pre.sectionKeys = "business_risks,mda"  // 旧セクション集合（segments 追加前）
            try await pre.create(on: app.db)

            let summary = try await runStage5Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, sectionKeys: keys, limit: nil
            ) { _ in fakePayload("fresh") }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyFilingSections.find("S1", on: app.db))
            #expect(row.sectionKeys == keys)
        }
    }

    @Test func ingestLimitsNewlyAttempted() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)
            try await seedDoc("S3", secCode: "99840", db: app.db)

            let summary = try await runStage5Ingest(
                db: app.db, listedCodes: ["7203", "6758", "9984"], years: 3, sectionKeys: keys,
                limit: 2
            ) { _ in fakePayload() }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
            #expect(try await CompanyFilingSections.query(on: app.db).count() == 2)
        }
    }

    @Test func ingestPrioritizesMissingBeforeStaleWhenLimited() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)  // stale existing
            try await seedDoc("S2", secCode: "67580", db: app.db)  // missing

            let stale = CompanyFilingSections()
            stale.id = "S1"
            stale.code = "7203"
            stale.submitDateTime = "2025-06-20 09:00"
            stale.payload = fakePayload("stale")
            stale.cacheVersion = "old-version"
            stale.sectionKeys = keys
            try await stale.create(on: app.db)

            let summary = try await runStage5Ingest(
                db: app.db, listedCodes: ["7203", "6758"], years: 3, sectionKeys: keys, limit: 1
            ) { _ in fakePayload("fresh") }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            #expect(try await CompanyFilingSections.find("S2", on: app.db) != nil)
            let staleAfter = try #require(try await CompanyFilingSections.find("S1", on: app.db))
            #expect(staleAfter.cacheVersion == "old-version")  // stale より先に空白を埋める
        }
    }

    @Test func ingestCountsFailuresWithoutStoring() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runStage5Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, sectionKeys: keys, limit: nil
            ) { _ in nil }

            #expect(summary.attempted == 1)
            #expect(summary.failed == 1)
            #expect(summary.stored == 0)
            #expect(try await CompanyFilingSections.query(on: app.db).count() == 0)
        }
    }

    // MARK: - read 経路

    private func seedStored(
        _ docID: String, code: String, submit: String, db: Database,
        version: String = filingSectionsCacheVersion, payload: FilingSectionsPayload = fakePayload()
    ) async throws {
        let row = CompanyFilingSections()
        row.id = docID
        row.code = code
        row.submitDateTime = submit
        row.payload = payload
        row.cacheVersion = version
        row.sectionKeys = keys
        try await row.create(on: db)
    }

    @Test func loadByCodeReturnsLatestDocument() async throws {
        try await withMigratedApp { app in
            try await seedStored("S24", code: "7203", submit: "2024-06-20 09:00", db: app.db)
            try await seedStored("S25", code: "7203", submit: "2025-06-20 09:00", db: app.db)

            let json = try #require(
                try await loadStoredFilingSections(
                    code: "7203", docId: nil, sections: nil, db: app.db))
            #expect(json["doc_id"] as? String == "S25")
            #expect(json["code"] as? String == "7203")
            let sections = try #require(json["sections"] as? [String: Any])
            #expect(sections["business_risks"] as? String == "risk")
        }
    }

    @Test func loadByDocIdReturnsThatDocument() async throws {
        try await withMigratedApp { app in
            try await seedStored("S24", code: "7203", submit: "2024-06-20 09:00", db: app.db)
            try await seedStored("S25", code: "7203", submit: "2025-06-20 09:00", db: app.db)

            let json = try #require(
                try await loadStoredFilingSections(
                    code: "7203", docId: "S24", sections: nil, db: app.db))
            #expect(json["doc_id"] as? String == "S24")
        }
    }

    @Test func loadByDocIdRejectsMismatchedCode() async throws {
        try await withMigratedApp { app in
            try await seedStored("S1", code: "7203", submit: "2025-06-20 09:00", db: app.db)
            // 別会社のコードで同じ doc_id を要求 → 取り違え防止で nil。
            let json = try await loadStoredFilingSections(
                code: "6758", docId: "S1", sections: nil, db: app.db)
            #expect(json == nil)
        }
    }

    @Test func loadReturnsNilWhenVersionMismatch() async throws {
        try await withMigratedApp { app in
            try await seedStored(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db, version: "old")
            let json = try await loadStoredFilingSections(
                code: "7203", docId: nil, sections: nil, db: app.db)
            #expect(json == nil)
        }
    }

    @Test func loadReturnsNilForUnknownCompany() async throws {
        try await withMigratedApp { app in
            let json = try await loadStoredFilingSections(
                code: "0000", docId: nil, sections: nil, db: app.db)
            #expect(json == nil)
        }
    }

    @Test func loadFiltersToRequestedSections() async throws {
        try await withMigratedApp { app in
            try await seedStored("S1", code: "7203", submit: "2025-06-20 09:00", db: app.db)
            let json = try #require(
                try await loadStoredFilingSections(
                    code: "7203", docId: nil, sections: ["mda"], db: app.db))
            let sections = try #require(json["sections"] as? [String: Any])
            #expect(sections.keys.sorted() == ["mda"])
        }
    }
}
