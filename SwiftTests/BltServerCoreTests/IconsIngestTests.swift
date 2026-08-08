// 会社アイコン取り込みの DB ロジック（対象選定＝上場×有報×会社ごと最新1件・staleness 判定・upsert・limit）を
// 検証する。抽出（extractAndUploadCompanyIcon）は EDINET/favicon/R2 依存のため、フェイク抽出器を注入して
// ネットワーク非依存で見る。

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
        app.migrations.add(CreateCompanyIcons())
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

private func fakeResult(_ marker: String = "icon") -> CompanyIconExtractResult {
    CompanyIconExtractResult(
        sourceURL: "https://example.com", r2ObjectKey: "company-icons/\(marker).png",
        contentType: "image/png")
}

@Suite struct IconsIngestTests {

    // MARK: - 対象選定・取り込み

    @Test func ingestStoresIconsForListedAnnualReports() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203", "6758"], limit: nil
            ) { _, _ in fakeResult() }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
            #expect(try await CompanyIcon.find("7203", on: app.db) != nil)
            let row = try #require(try await CompanyIcon.find("6758", on: app.db))
            #expect(row.sourceURL == "https://example.com")
            #expect(row.cacheVersion == companyIconsCacheVersion)
        }
    }

    @Test func ingestExcludesNonListedCompanies() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)  // listed
            try await seedDoc("S2", secCode: "99990", db: app.db)  // not in listedCodes

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in fakeResult() }

            #expect(summary.attempted == 1)
            #expect(try await CompanyIcon.find("9999", on: app.db) == nil)
        }
    }

    @Test func ingestExcludesCompaniesNotInExplicitCodes() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)  // explicitCodes に含む
            try await seedDoc("S2", secCode: "67580", db: app.db)  // 含まない

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203", "6758"], limit: nil, explicitCodes: ["7203"]
            ) { _, _ in fakeResult() }

            #expect(summary.attempted == 1)
            #expect(try await CompanyIcon.find("6758", on: app.db) == nil)
        }
    }

    @Test func ingestPicksOnlyLatestAnnualReportPerCompany() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1_OLD", secCode: "72030", submit: "2024-06-20 09:00", db: app.db)
            try await seedDoc("S1_NEW", secCode: "72030", submit: "2025-06-20 09:00", db: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { docID, _ in fakeResult(docID) }

            #expect(summary.attempted == 1)
            let row = try #require(try await CompanyIcon.find("7203", on: app.db))
            #expect(row.r2ObjectKey == "company-icons/S1_NEW.png")
        }
    }

    @Test func ingestExcludesNonAnnualDocTypes() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", docType: Api.docTypeQuarterlyReport, db: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in fakeResult() }

            #expect(summary.attempted == 0)
        }
    }

    // MARK: - staleness・limit

    @Test func ingestSkipsCompanyAlreadyStoredWithCurrentVersion() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let existing = CompanyIcon(
                code: "7203", sourceURL: "https://old.example.com", r2ObjectKey: "old.png",
                contentType: "image/png", cacheVersion: companyIconsCacheVersion)
            try await existing.create(on: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in fakeResult() }

            #expect(summary.attempted == 0)
            #expect(summary.skipped == 1)
            let row = try #require(try await CompanyIcon.find("7203", on: app.db))
            #expect(row.sourceURL == "https://old.example.com")  // 上書きされていない
        }
    }

    @Test func ingestReattemptsRowWhenVersionStale() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let existing = CompanyIcon(
                code: "7203", sourceURL: "https://old.example.com", r2ObjectKey: "old.png",
                contentType: "image/png", cacheVersion: "icons-v0")
            try await existing.create(on: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in fakeResult("new") }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyIcon.find("7203", on: app.db))
            #expect(row.r2ObjectKey == "company-icons/new.png")
            #expect(row.cacheVersion == companyIconsCacheVersion)
        }
    }

    @Test func ingestLimitsNewlyAttemptedCompanies() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)
            try await seedDoc("S3", secCode: "99840", db: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203", "6758", "9984"], limit: 2
            ) { _, _ in fakeResult() }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
        }
    }

    // MARK: - 抽出失敗

    @Test func ingestCountsFailedWithoutStoringOnExtractorFailure() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in nil }

            #expect(summary.attempted == 1)
            #expect(summary.failed == 1)
            #expect(summary.stored == 0)
            #expect(try await CompanyIcon.find("7203", on: app.db) == nil)
        }
    }
}
