// 銘柄 Overview 取り込みの DB ロジック（対象選定＝上場×会社有報120・府令010×会社ごと最新1件・
// staleness 判定・upsert・limit）を検証する。生成（generateCompanyOverview）は EDINET/LLM 依存のため、
// フェイク生成器を注入してネットワーク非依存で見る。

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
        app.migrations.add(CreateCompanyOverviews())
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

private func sampleDraft(
    overview: String = "四輪車、二輪車の製造販売を手がける。", applicable: Bool = true, ok: Bool = true
) -> CompanyOverviewDraft {
    CompanyOverviewDraft(
        applicable: applicable, overview: overview, charCount: overview.count,
        reason: applicable ? "" : "empty_source", ok: ok,
        okDetail: ok ? "" : "validation", clipped: false, attempts: 1,
        model: companyOverviewDefaultModel, inputCharsTotal: 120, inputCharsUsed: 120,
        inputThin: false)
}

private func generated(
    overview: String = "四輪車、二輪車の製造販売を手がける。", source: String = "事業の内容",
    applicable: Bool = true, ok: Bool = true
) -> CompanyOverviewResolveResult {
    .generated(draft: sampleDraft(overview: overview, applicable: applicable, ok: ok), sourceText: source)
}

@Suite struct OverviewIngestTests {

    @Test func ingestStoresOverviewsForListedAnnualReports() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203", "6758"], limit: nil
            ) { _, _ in generated() }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
            #expect(try await CompanyOverview.find("7203", on: app.db) != nil)
            let row = try #require(try await CompanyOverview.find("6758", on: app.db))
            #expect(row.payload.overview == "四輪車、二輪車の製造販売を手がける。")
            #expect(row.cacheVersion == companyOverviewCacheVersion)
            #expect(row.source == companyOverviewSourceLLM)
            #expect(row.docID == "S2")
            #expect(row.submitDateTime == "2025-06-20 09:00")
        }
    }

    @Test func ingestExcludesNonListedCompanies() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "99990", db: app.db)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in generated() }

            #expect(summary.attempted == 1)
            #expect(try await CompanyOverview.find("9999", on: app.db) == nil)
        }
    }

    @Test func ingestExcludesCompaniesNotInExplicitCodes() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203", "6758"], limit: nil, explicitCodes: ["7203"]
            ) { _, _ in generated() }

            #expect(summary.attempted == 1)
            #expect(try await CompanyOverview.find("6758", on: app.db) == nil)
        }
    }

    @Test func ingestPicksOnlyLatestAnnualReportPerCompany() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1_OLD", secCode: "72030", submit: "2024-06-20 09:00", db: app.db)
            try await seedDoc("S1_NEW", secCode: "72030", submit: "2025-06-20 09:00", db: app.db)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { docID, _ in generated(overview: "最新有報の説明。", source: docID) }

            #expect(summary.attempted == 1)
            let row = try #require(try await CompanyOverview.find("7203", on: app.db))
            #expect(row.docID == "S1_NEW")
            #expect(row.contentHash == companyOverviewContentHash("S1_NEW"))
        }
    }

    @Test func ingestExcludesTrustBeneficiaryOrdinance030EvenIfNewerDocType120() async throws {
        try await withMigratedApp { app in
            try await seedDoc(
                "S100YCDE", secCode: "82530", submit: "2026-06-16 11:38", db: app.db)
            try await seedDoc(
                "S100YZ8K", secCode: "82530", submit: "2026-08-28 16:00",
                ordinance: "030", form: "09A000", db: app.db)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["8253"], limit: nil
            ) { docID, _ in generated(source: docID) }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyOverview.find("8253", on: app.db))
            #expect(row.docID == "S100YCDE")
        }
    }

    @Test func ingestExcludesNonAnnualDocTypes() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", docType: Api.docTypeQuarterlyReport, db: app.db)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in generated() }

            #expect(summary.attempted == 0)
        }
    }

    @Test func ingestSkipsCompanyAlreadyStoredWithCurrentVersionAndSameDoc() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let existing = CompanyOverview(
                code: "7203", docID: "S1", submitDateTime: "2025-06-20 09:00",
                payload: CompanyOverviewPayload(draft: sampleDraft(overview: "既存文。")),
                contentHash: companyOverviewContentHash("旧"))
            try await existing.create(on: app.db)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in generated() }

            #expect(summary.attempted == 0)
            #expect(summary.skipped == 1)
            let row = try #require(try await CompanyOverview.find("7203", on: app.db))
            #expect(row.payload.overview == "既存文。")
        }
    }

    @Test func ingestSkipsRowWhenVersionStaleIfSameDoc() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let existing = CompanyOverview(
                code: "7203", docID: "S1", submitDateTime: "2025-06-20 09:00",
                payload: CompanyOverviewPayload(draft: sampleDraft(overview: "旧文。")),
                contentHash: companyOverviewContentHash("旧"))
            existing.cacheVersion = "overview-v0"
            try await existing.create(on: app.db)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in generated(overview: "新文。") }

            #expect(summary.attempted == 0)
            #expect(summary.skipped == 1)
            let row = try #require(try await CompanyOverview.find("7203", on: app.db))
            #expect(row.payload.overview == "旧文。")
            #expect(row.cacheVersion == "overview-v0")
        }
    }

    @Test func ingestReattemptsNotApplicableWhenVersionStale() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let existing = CompanyOverview(
                code: "7203", docID: "S1", submitDateTime: "2025-06-20 09:00",
                payload: CompanyOverviewPayload(
                    draft: sampleDraft(overview: "", applicable: false, ok: true)),
                contentHash: companyOverviewContentHash(""))
            existing.cacheVersion = "overview-v0"
            try await existing.create(on: app.db)
            #expect(existing.source == companyOverviewSourceNotApplicable)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in generated(overview: "短い事業説明を手がける。") }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyOverview.find("7203", on: app.db))
            #expect(row.payload.overview == "短い事業説明を手がける。")
            #expect(row.cacheVersion == companyOverviewCacheVersion)
            #expect(row.source == companyOverviewSourceLLM)
        }
    }

    @Test func ingestSkipsCurrentNotApplicableWhenSameDoc() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let existing = CompanyOverview(
                code: "7203", docID: "S1", submitDateTime: "2025-06-20 09:00",
                payload: CompanyOverviewPayload(
                    draft: sampleDraft(overview: "", applicable: false, ok: true)),
                contentHash: companyOverviewContentHash(""))
            try await existing.create(on: app.db)
            #expect(existing.source == companyOverviewSourceNotApplicable)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in generated(overview: "呼ばれてはいけない文。") }

            #expect(summary.attempted == 0)
            #expect(summary.skipped == 1)
            let row = try #require(try await CompanyOverview.find("7203", on: app.db))
            #expect(row.source == companyOverviewSourceNotApplicable)
            #expect(row.payload.overview.isEmpty)
        }
    }

    @Test func ingestReattemptsNeedsReviewEvenWhenVersionStale() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let existing = CompanyOverview(
                code: "7203", docID: "S1", submitDateTime: "2025-06-20 09:00",
                payload: CompanyOverviewPayload(draft: sampleDraft(ok: false)),
                contentHash: companyOverviewContentHash("残文"))
            existing.cacheVersion = "overview-v0"
            try await existing.create(on: app.db)
            #expect(existing.needsReview == true)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in generated(overview: "再生成した説明。") }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyOverview.find("7203", on: app.db))
            #expect(row.payload.overview == "再生成した説明。")
            #expect(row.needsReview == false)
            #expect(row.cacheVersion == companyOverviewCacheVersion)
        }
    }

    @Test func ingestReattemptsRowWhenNeedsReview() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let existing = CompanyOverview(
                code: "7203", docID: "S1", submitDateTime: "2025-06-20 09:00",
                payload: CompanyOverviewPayload(draft: sampleDraft(ok: false)),
                contentHash: companyOverviewContentHash("残文"))
            try await existing.create(on: app.db)
            #expect(existing.needsReview == true)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in generated(overview: "再生成した説明。") }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyOverview.find("7203", on: app.db))
            #expect(row.payload.overview == "再生成した説明。")
            #expect(row.needsReview == false)
        }
    }

    @Test func ingestReattemptsRowWhenLatestDocChanges() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1_OLD", secCode: "72030", submit: "2024-06-20 09:00", db: app.db)
            try await seedDoc("S1_NEW", secCode: "72030", submit: "2025-06-20 09:00", db: app.db)
            let existing = CompanyOverview(
                code: "7203", docID: "S1_OLD", submitDateTime: "2024-06-20 09:00",
                payload: CompanyOverviewPayload(draft: sampleDraft(overview: "旧有報の説明。")),
                contentHash: companyOverviewContentHash("旧"))
            try await existing.create(on: app.db)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in generated(overview: "新有報の説明。") }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyOverview.find("7203", on: app.db))
            #expect(row.docID == "S1_NEW")
            #expect(row.payload.overview == "新有報の説明。")
        }
    }

    @Test func ingestStoresNotApplicableWithoutCountingAsStored() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in generated(overview: "", source: "", applicable: false, ok: true) }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 0)
            #expect(summary.notApplicable == 1)
            let row = try #require(try await CompanyOverview.find("7203", on: app.db))
            #expect(row.source == companyOverviewSourceNotApplicable)
            #expect(row.needsReview == false)
            #expect(row.payload.overview.isEmpty)
        }
    }

    @Test func ingestLimitsNewlyAttemptedCompanies() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)
            try await seedDoc("S3", secCode: "99840", db: app.db)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203", "6758", "9984"], limit: 2
            ) { _, _ in generated() }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
        }
    }

    @Test func ingestPrefersCachedDocWhenLimitCutsOff() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", submit: "2025-06-20 09:00", db: app.db)
            try await seedDoc("S2", secCode: "67580", submit: "2024-06-20 09:00", db: app.db)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203", "6758"], limit: 1, cachedDocIDs: ["S2"]
            ) { _, _ in generated() }

            #expect(summary.attempted == 1)
            #expect(try await CompanyOverview.find("6758", on: app.db) != nil)
            #expect(try await CompanyOverview.find("7203", on: app.db) == nil)
        }
    }

    @Test func ingestCountsFailedWithoutStoringOnGeneratorFailure() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runOverviewIngest(
                db: app.db, listedCodes: ["7203"], limit: nil
            ) { _, _ in .failed }

            #expect(summary.attempted == 1)
            #expect(summary.failed == 1)
            #expect(summary.stored == 0)
            #expect(try await CompanyOverview.find("7203", on: app.db) == nil)
        }
    }
}
