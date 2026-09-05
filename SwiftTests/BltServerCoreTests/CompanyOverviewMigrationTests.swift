// 銘柄 Overview マイグレーションの検証。
// インメモリ SQLite に migration を実走させ、company_overviews のスキーマがモデルと整合し、
// 行が round-trip することを確認する（本番は Postgres）。

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
        app.migrations.add(CreateCompanyOverviews())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private func samplePayload(
    applicable: Bool = true, overview: String = "四輪車、二輪車の製造販売を手がける。", ok: Bool = true
) -> CompanyOverviewPayload {
    CompanyOverviewPayload(
        applicable: applicable, overview: overview, charCount: overview.count,
        reason: applicable ? "" : "empty_source", ok: ok,
        okDetail: ok ? "" : "validation", clipped: false, attempts: 1,
        model: companyOverviewDefaultModel, inputCharsTotal: 120, inputCharsUsed: 120,
        inputThin: false)
}

@Suite struct CompanyOverviewMigrationTests {
    @Test func companyOverviewRoundTripsApplicableRow() async throws {
        try await withMigratedApp { app in
            let payload = samplePayload()
            let row = CompanyOverview(
                code: "7269", docID: "S100W4MT", submitDateTime: "2025-06-20 09:00",
                payload: payload, contentHash: companyOverviewContentHash("事業の内容"))
            try await row.create(on: app.db)

            let fetched = try #require(try await CompanyOverview.find("7269", on: app.db))
            #expect(fetched.docID == "S100W4MT")
            #expect(fetched.submitDateTime == "2025-06-20 09:00")
            #expect(fetched.payload == payload)
            #expect(fetched.needsReview == false)
            #expect(fetched.source == companyOverviewSourceLLM)
            #expect(fetched.contentHash == companyOverviewContentHash("事業の内容"))
            #expect(fetched.cacheVersion == companyOverviewCacheVersion)
            #expect(fetched.notApplicableReason == nil)
            #expect(fetched.updatedAt != nil)
        }
    }

    @Test func companyOverviewStoresNotApplicableAndNeedsReview() async throws {
        try await withMigratedApp { app in
            let empty = samplePayload(applicable: false, overview: "", ok: true)
            let emptyRow = CompanyOverview(
                code: "0001", docID: "S100EMPTY", submitDateTime: "2025-01-01 00:00",
                payload: empty, contentHash: companyOverviewContentHash(""))
            try await emptyRow.create(on: app.db)

            let failed = samplePayload(ok: false)
            let failedRow = CompanyOverview(
                code: "0002", docID: "S100FAIL", submitDateTime: "2025-01-02 00:00",
                payload: failed, contentHash: companyOverviewContentHash("残文"))
            try await failedRow.create(on: app.db)

            let llmFailed = samplePayload(applicable: false, overview: "", ok: false)
            let llmFailedRow = CompanyOverview(
                code: "0003", docID: "S100LLM", submitDateTime: "2025-01-03 00:00",
                payload: llmFailed, contentHash: companyOverviewContentHash("残文"))
            try await llmFailedRow.create(on: app.db)

            let storedEmpty = try #require(try await CompanyOverview.find("0001", on: app.db))
            #expect(storedEmpty.source == companyOverviewSourceNotApplicable)
            #expect(storedEmpty.needsReview == false)
            #expect(storedEmpty.notApplicableReason == "empty_source")
            #expect(storedEmpty.payload.overview.isEmpty)

            let storedFailed = try #require(try await CompanyOverview.find("0002", on: app.db))
            #expect(storedFailed.source == companyOverviewSourceLLM)
            #expect(storedFailed.needsReview == true)
            #expect(storedFailed.notApplicableReason == nil)

            let storedLLMFailed = try #require(try await CompanyOverview.find("0003", on: app.db))
            #expect(storedLLMFailed.source == companyOverviewSourceLLM)
            #expect(storedLLMFailed.needsReview == true)
            #expect(storedLLMFailed.notApplicableReason == nil)
        }
    }

    @Test func companyOverviewKeepsOneRowPerCodeWhenDocIDChanges() async throws {
        try await withMigratedApp { app in
            let first = CompanyOverview(
                code: "7269", docID: "S100OLD", submitDateTime: "2024-06-20 09:00",
                payload: samplePayload(overview: "旧文。"),
                contentHash: companyOverviewContentHash("旧"))
            try await first.create(on: app.db)

            let stored = try #require(try await CompanyOverview.find("7269", on: app.db))
            stored.docID = "S100W4MT"
            stored.submitDateTime = "2025-06-20 09:00"
            stored.payload = samplePayload()
            stored.contentHash = companyOverviewContentHash("新")
            try await stored.update(on: app.db)

            let rows = try await CompanyOverview.query(on: app.db).all()
            #expect(rows.count == 1)
            #expect(rows[0].id == "7269")
            #expect(rows[0].docID == "S100W4MT")
            #expect(rows[0].payload.overview == "四輪車、二輪車の製造販売を手がける。")
        }
    }
}
