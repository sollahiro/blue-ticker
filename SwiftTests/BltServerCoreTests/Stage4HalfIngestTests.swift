// 半期 Stage 4 取り込みの DB ロジック（企業選定・staleness 判定・upsert・limit）と
// read 経路（loadStoredHalfFinancials のバージョン・年数ゲートと trim）を検証する。
// 計算（computeHalfFinancials）は EDINET 依存のため、フェイク計算器を注入してネットワーク非依存で見る。

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
        app.migrations.add(CreateCompanyHalfFinancials())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private func seedDocument(_ docID: String, secCode: String?, db: Database) async throws {
    let model = EdinetDocument()
    model.id = docID
    model.edinetCode = "E00001"
    model.secCode = secCode
    model.filerName = "テスト株式会社"
    model.docTypeCode = "120"
    model.submitDateTime = "2025-06-20 09:00"
    try await model.create(on: db)
}

/// 公開契約 HalfFinancialsResponse を JSON 経由で構築する。fyEnds（昇順）各年に H1/H2 を持たせる。
private func makeHalfResponse(code: String, fyEnds: [String]) -> HalfFinancialsResponse {
    var periods: [[String: Any]] = []
    for fy in fyEnds {
        for half in ["H1", "H2"] {
            periods.append(["label": "\(fy)\(half)", "half": half, "year": ["fy_end": fy]])
        }
    }
    let dict: [String: Any] = [
        "schema_version": 1, "code": code, "name": "テスト",
        "currency": "JPY", "unit": "百万円", "periods": periods,
    ]
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(HalfFinancialsResponse.self, from: data)
}

private let years3 = ["2023-03-31", "2024-03-31", "2025-03-31"]

@Suite struct Stage4HalfIngestTests {
    @Test func ingestStoresHalfFinancialsForEachDistinctCompany() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            try await seedDocument("S2", secCode: "67580", db: app.db)

            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { code in
                makeHalfResponse(code: code, fyEnds: years3)
            }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
            #expect(try await CompanyHalfFinancials.find("7203", on: app.db) != nil)
            #expect(try await CompanyHalfFinancials.find("6758", on: app.db) != nil)
        }
    }

    @Test func ingestSkipsCompanyAlreadyComputedAtCurrentVersionAndYears() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            let pre = CompanyHalfFinancials()
            pre.id = "7203"
            pre.response = makeHalfResponse(code: "7203", fyEnds: years3)
            pre.cacheVersion = companyHalfFinancialsCacheVersion
            pre.requestedYears = 5
            try await pre.create(on: app.db)

            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run for an up-to-date company")
                return makeHalfResponse(code: "x", fyEnds: years3)
            }
            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    @Test func ingestRecomputesWhenVersionMismatches() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            let stale = CompanyHalfFinancials()
            stale.id = "7203"
            stale.response = makeHalfResponse(code: "7203", fyEnds: years3)
            stale.cacheVersion = "stale"
            stale.requestedYears = 5
            try await stale.create(on: app.db)

            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { code in
                makeHalfResponse(code: code, fyEnds: years3)
            }
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyHalfFinancials.find("7203", on: app.db))
            #expect(row.cacheVersion == companyHalfFinancialsCacheVersion)
        }
    }

    @Test func ingestCountsComputeFailuresWithoutStoring() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { _ in nil }
            #expect(summary.failed == 1)
            #expect(summary.stored == 0)
            #expect(try await CompanyHalfFinancials.query(on: app.db).count() == 0)
        }
    }

    @Test func ingestLimitsNewlyAttemptedCompanies() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            try await seedDocument("S2", secCode: "67580", db: app.db)
            try await seedDocument("S3", secCode: "99840", db: app.db)

            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: 2) { code in
                makeHalfResponse(code: code, fyEnds: years3)
            }
            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
        }
    }

    // MARK: - read 経路

    @Test func loadStoredHalfFinancialsTrimsToRequestedYears() async throws {
        try await withMigratedApp { app in
            let row = CompanyHalfFinancials()
            row.id = "7203"
            row.response = makeHalfResponse(code: "7203", fyEnds: years3)
            row.cacheVersion = companyHalfFinancialsCacheVersion
            row.requestedYears = 5
            try await row.create(on: app.db)

            let json = try #require(
                try await loadStoredHalfFinancials(code: "7203", years: 1, db: app.db))
            let periods = try #require(json["periods"] as? [[String: Any]])
            #expect(periods.count == 2)  // 最新年の H1+H2
            #expect(json["schema_version"] as? Int == 1)
        }
    }

    @Test func loadStoredHalfFinancialsReturnsNilWhenVersionMismatch() async throws {
        try await withMigratedApp { app in
            let row = CompanyHalfFinancials()
            row.id = "7203"
            row.response = makeHalfResponse(code: "7203", fyEnds: years3)
            row.cacheVersion = "stale"
            row.requestedYears = 5
            try await row.create(on: app.db)

            let json = try await loadStoredHalfFinancials(code: "7203", years: 1, db: app.db)
            #expect(json == nil)
        }
    }

    @Test func loadStoredHalfFinancialsReturnsNilWhenYearsInsufficient() async throws {
        try await withMigratedApp { app in
            let row = CompanyHalfFinancials()
            row.id = "7203"
            row.response = makeHalfResponse(code: "7203", fyEnds: years3)
            row.cacheVersion = companyHalfFinancialsCacheVersion
            row.requestedYears = 2
            try await row.create(on: app.db)

            let json = try await loadStoredHalfFinancials(code: "7203", years: 5, db: app.db)
            #expect(json == nil)
        }
    }

    @Test func loadStoredHalfFinancialsReturnsNilForUnknownCompany() async throws {
        try await withMigratedApp { app in
            let json = try await loadStoredHalfFinancials(code: "0000", years: 3, db: app.db)
            #expect(json == nil)
        }
    }
}
