// 会社アイコン取り込みの DB ロジック（対象選定＝上場×会社有報120・府令010×会社ごと最新1件・staleness 判定・upsert・limit）を
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
    submit: String = "2025-06-20 09:00",
    ordinance: String? = Api.ordinanceCompanyDisclosure,
    form: String? = "030000",
    db: Database
) async throws {
    let model = EdinetDocument()
    model.id = docID
    model.edinetCode = "E00001"
    model.secCode = secCode
    model.filerName = "テスト株式会社"
    model.docTypeCode = docType
    model.ordinanceCode = ordinance
    model.formCode = form
    model.submitDateTime = submit
    try await model.create(on: db)
}

private func fakeResult(
    _ marker: String = "icon", sourceURL: String = "https://example.com",
    cacheVersion: String = companyIconsCacheVersion
) -> CompanyIconExtractResult {
    CompanyIconExtractResult(
        sourceURL: sourceURL, r2ObjectKey: "company-icons/\(marker).png",
        contentType: "image/png", cacheVersion: cacheVersion)
}

@Suite struct IconsIngestTests {

    // MARK: - 対象選定・取り込み

    @Test func ingestStoresIconsForListedAnnualReports() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203", "6758"], limit: nil
            ) { _, _ in .success(fakeResult()) }

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
            ) { _, _ in .success(fakeResult()) }

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
            ) { _, _ in .success(fakeResult()) }

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
            ) { docID, _ in .success(fakeResult(docID)) }

            #expect(summary.attempted == 1)
            let row = try #require(try await CompanyIcon.find("7203", on: app.db))
            #expect(row.r2ObjectKey == "company-icons/S1_NEW.png")
        }
    }

    /// 8253 型: 会社 010 有報より新しい特定有価証券 030 120 があっても、アイコン候補は 010 のみ。
    @Test func ingestExcludesTrustBeneficiaryOrdinance030EvenIfNewerDocType120() async throws {
        try await withMigratedApp { app in
            try await seedDoc(
                "S100YCDE", secCode: "82530", submit: "2026-06-16 11:38", db: app.db)
            try await seedDoc(
                "S100YZ8K", secCode: "82530", submit: "2026-08-28 16:00",
                ordinance: "030", form: "09A000", db: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["8253"], limit: nil
            ) { docID, _ in .success(fakeResult(docID)) }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyIcon.find("8253", on: app.db))
            #expect(row.r2ObjectKey == "company-icons/S100YCDE.png")
        }
    }

    @Test func ingestExcludesNonAnnualDocTypes() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", docType: Api.docTypeQuarterlyReport, db: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in .success(fakeResult()) }

            #expect(summary.attempted == 0)
        }
    }

    // MARK: - staleness・limit

    @Test func ingestSkipsCompanyAlreadyStoredWithCurrentVersion() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "67580", db: app.db)
            let existing = CompanyIcon(
                code: "6758", sourceURL: "https://old.example.com", r2ObjectKey: "old.png",
                contentType: "image/png", cacheVersion: companyIconsCacheVersion)
            try await existing.create(on: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["6758"], limit: nil
            ) { _, _ in .success(fakeResult()) }

            #expect(summary.attempted == 0)
            #expect(summary.skipped == 1)
            let row = try #require(try await CompanyIcon.find("6758", on: app.db))
            #expect(row.sourceURL == "https://old.example.com")  // 上書きされていない
        }
    }

    @Test func ingestReattemptsRowWhenVersionStale() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "67580", db: app.db)
            let existing = CompanyIcon(
                code: "6758", sourceURL: "https://old.example.com", r2ObjectKey: "old.png",
                contentType: "image/png", cacheVersion: "icons-v0")
            try await existing.create(on: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["6758"], limit: nil
            ) { _, _ in .success(fakeResult("new")) }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyIcon.find("6758", on: app.db))
            #expect(row.r2ObjectKey == "company-icons/new.png")
            #expect(row.cacheVersion == companyIconsCacheVersion)
        }
    }

    @Test func ingestReplacesAutomaticToyotaIconWithManualHomepage() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let existing = CompanyIcon(
                code: "7203", sourceURL: "https://www.toyota.co.jp", r2ObjectKey: "old.png",
                contentType: "image/png", cacheVersion: companyIconsCacheVersion)
            try await existing.create(on: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in
                .success(
                    fakeResult(
                        "toyota", sourceURL: "https://toyota.jp",
                        cacheVersion: companyIconsManualCacheVersion))
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyIcon.find("7203", on: app.db))
            #expect(row.sourceURL == "https://toyota.jp")
            #expect(row.cacheVersion == companyIconsManualCacheVersion)
        }
    }

    @Test func ingestSkipsToyotaWhenManualOriginAlreadyMatches() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let existing = CompanyIcon(
                code: "7203", sourceURL: "https://toyota.jp", r2ObjectKey: "toyota.png",
                contentType: "image/png", cacheVersion: companyIconsManualCacheVersion)
            try await existing.create(on: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in .success(fakeResult()) }

            #expect(summary.attempted == 0)
            #expect(summary.skipped == 1)
            let row = try #require(try await CompanyIcon.find("7203", on: app.db))
            #expect(row.r2ObjectKey == "toyota.png")
        }
    }

    @Test func ingestDoesNotOverwriteManualIconWhenAutomaticVersionChanges() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "67580", db: app.db)
            let existing = CompanyIcon(
                code: "6758", sourceURL: "https://www.sony.com", r2ObjectKey: "manual.png",
                contentType: "image/png", cacheVersion: companyIconsManualCacheVersion)
            try await existing.create(on: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["6758"], limit: nil
            ) { _, _ in .success(fakeResult("overwrite")) }

            #expect(summary.attempted == 0)
            #expect(summary.skipped == 1)
            let row = try #require(try await CompanyIcon.find("6758", on: app.db))
            #expect(row.r2ObjectKey == "manual.png")
            #expect(row.cacheVersion == companyIconsManualCacheVersion)
        }
    }

    @Test func ingestLimitsNewlyAttemptedCompanies() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)
            try await seedDoc("S3", secCode: "99840", db: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203", "6758", "9984"], limit: 2
            ) { _, _ in .success(fakeResult()) }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
        }
    }

    @Test func ingestPrefersCachedDocWhenLimitCutsOff() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", submit: "2025-06-20 09:00", db: app.db)
            try await seedDoc("S2", secCode: "67580", submit: "2024-06-20 09:00", db: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203", "6758"], limit: 1, cachedDocIDs: ["S2"]
            ) { _, _ in .success(fakeResult()) }

            #expect(summary.attempted == 1)
            #expect(try await CompanyIcon.find("6758", on: app.db) != nil)
            #expect(try await CompanyIcon.find("7203", on: app.db) == nil)
        }
    }

    // MARK: - 抽出失敗

    @Test func ingestCountsFailedWithoutStoringOnExtractorFailure() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runIconsIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in .failure(.downloadFailed) }

            #expect(summary.attempted == 1)
            #expect(summary.failed == 1)
            #expect(summary.stored == 0)
            #expect(try await CompanyIcon.find("7203", on: app.db) == nil)
        }
    }
}
