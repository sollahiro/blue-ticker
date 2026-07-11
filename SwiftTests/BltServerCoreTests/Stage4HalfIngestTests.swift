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
        // AddHighWaterToCompanyFinancials は両テーブルを触るため、通期側も作っておく。
        app.migrations.add(CreateCompanyFinancials())
        app.migrations.add(AddHighWaterToCompanyFinancials())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

/// docTypeCode / submitDateTime は high-water 判定のテストで可変にできるよう引数化する。
private func seedDocument(
    _ docID: String, secCode: String?, docTypeCode: String = "120",
    submitDateTime: String = "2025-06-20 09:00", db: Database
) async throws {
    let model = EdinetDocument()
    model.id = docID
    model.edinetCode = "E00001"
    model.secCode = secCode
    model.filerName = "テスト株式会社"
    model.docTypeCode = docTypeCode
    model.submitDateTime = submitDateTime
    try await model.create(on: db)
}

/// 公開契約 HalfFinancialsResponse を JSON 経由で構築する。fyEnds（昇順）各年に H1/H2 を持たせる。
private func makeHalfResponse(code: String, fyEnds: [String]) throws -> HalfFinancialsResponse {
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
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(HalfFinancialsResponse.self, from: data)
}

private let years3 = ["2023-03-31", "2024-03-31", "2025-03-31"]

@Suite struct Stage4HalfIngestTests {
    @Test func ingestStoresHalfFinancialsForEachDistinctCompany() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            try await seedDocument("S2", secCode: "67580", db: app.db)

            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { code in
                try? makeHalfResponse(code: code, fyEnds: years3)
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
            pre.response = try makeHalfResponse(code: "7203", fyEnds: years3)
            pre.cacheVersion = companyHalfFinancialsCacheVersion
            pre.requestedYears = 5
            pre.highWater = "2025-06-20 09:00"  // seedDocument のデフォルト submitDateTime と一致
            try await pre.create(on: app.db)

            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run for an up-to-date company")
                return try? makeHalfResponse(code: "x", fyEnds: years3)
            }
            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    // MARK: - listedCodes 絞り込み（上場廃止・外国法人の除外）

    @Test func ingestSkipsCompaniesNotInListedCodes() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)  // listedCodes に含む
            try await seedDocument("S2", secCode: "67580", db: app.db)  // 上場廃止想定・含まない

            let summary = try await runStage4HalfIngest(
                db: app.db, years: 5, limit: nil, listedCodes: ["7203"]
            ) { code in
                try? makeHalfResponse(code: code, fyEnds: years3)
            }

            #expect(summary.attempted == 1)
            #expect(try await CompanyHalfFinancials.find("7203", on: app.db) != nil)
            #expect(try await CompanyHalfFinancials.find("6758", on: app.db) == nil)
        }
    }

    // MARK: - high-water 鮮度トリガー（issue #26）

    @Test func skipsWhenHighWaterMatches() async throws {
        try await withMigratedApp { app in
            try await seedDocument(
                "S1", secCode: "72030", docTypeCode: "120",
                submitDateTime: "2025-06-20 09:00", db: app.db)
            let pre = CompanyHalfFinancials()
            pre.id = "7203"
            pre.response = try makeHalfResponse(code: "7203", fyEnds: years3)
            pre.cacheVersion = companyHalfFinancialsCacheVersion
            pre.requestedYears = 5
            pre.highWater = "2025-06-20 09:00"
            try await pre.create(on: app.db)

            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run when high-water matches")
                return try? makeHalfResponse(code: "x", fyEnds: years3)
            }
            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    /// Stage 4-half は通期(120/130)に加え半期/四半期(140/160)も消費種別に含む。
    /// 通期のみを見る Stage 4 とは異なり、140 の新規提出だけでも再計算がトリガーされる。
    @Test func recomputesWhenNewerQuarterlyFilingArrives() async throws {
        try await withMigratedApp { app in
            try await seedDocument(
                "S1", secCode: "72030", docTypeCode: "120",
                submitDateTime: "2025-06-01 09:00", db: app.db)
            let pre = CompanyHalfFinancials()
            pre.id = "7203"
            pre.response = try makeHalfResponse(code: "7203", fyEnds: years3)
            pre.cacheVersion = companyHalfFinancialsCacheVersion
            pre.requestedYears = 5
            pre.highWater = "2025-06-01 09:00"
            try await pre.create(on: app.db)

            try await seedDocument(
                "S2", secCode: "72030", docTypeCode: "140",
                submitDateTime: "2025-08-01 09:00", db: app.db)

            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { code in
                try? makeHalfResponse(code: code, fyEnds: years3)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyHalfFinancials.find("7203", on: app.db))
            #expect(row.highWater == "2025-08-01 09:00")
        }
    }

    @Test func keepsHighWaterOnComputeFailure() async throws {
        try await withMigratedApp { app in
            try await seedDocument(
                "S1", secCode: "72030", docTypeCode: "120",
                submitDateTime: "2025-06-20 09:00", db: app.db)
            let pre = CompanyHalfFinancials()
            pre.id = "7203"
            pre.response = try makeHalfResponse(code: "7203", fyEnds: years3)
            pre.cacheVersion = companyHalfFinancialsCacheVersion
            pre.requestedYears = 5
            pre.highWater = "2025-01-01 09:00"  // 現在の max より古い → 再計算対象
            try await pre.create(on: app.db)

            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { _ in nil }

            #expect(summary.attempted == 1)
            #expect(summary.failed == 1)
            #expect(summary.stored == 0)
            let row = try #require(try await CompanyHalfFinancials.find("7203", on: app.db))
            #expect(row.highWater == "2025-01-01 09:00")  // 失敗時は更新されず据え置き
        }
    }

    @Test func ingestRecomputesWhenVersionMismatches() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            let stale = CompanyHalfFinancials()
            stale.id = "7203"
            stale.response = try makeHalfResponse(code: "7203", fyEnds: years3)
            stale.cacheVersion = "stale"
            stale.requestedYears = 5
            try await stale.create(on: app.db)

            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { code in
                try? makeHalfResponse(code: code, fyEnds: years3)
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
                try? makeHalfResponse(code: code, fyEnds: years3)
            }
            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
        }
    }

    @Test func ingestPrioritizesMissingBeforeStaleWhenLimited() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)  // stale existing
            try await seedDocument("S2", secCode: "67580", db: app.db)  // missing

            let stale = CompanyHalfFinancials()
            stale.id = "7203"
            stale.response = try makeHalfResponse(code: "7203", fyEnds: years3)
            stale.cacheVersion = "stale"
            stale.requestedYears = 5
            try await stale.create(on: app.db)

            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: 1) { code in
                try? makeHalfResponse(code: code, fyEnds: years3)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            #expect(try await CompanyHalfFinancials.find("6758", on: app.db) != nil)
            let staleAfter = try #require(try await CompanyHalfFinancials.find("7203", on: app.db))
            #expect(staleAfter.cacheVersion == "stale")  // stale より先に空白を埋める
        }
    }

    // MARK: - read 経路

    @Test func loadStoredHalfFinancialsTrimsToRequestedYears() async throws {
        try await withMigratedApp { app in
            let row = CompanyHalfFinancials()
            row.id = "7203"
            row.response = try makeHalfResponse(code: "7203", fyEnds: years3)
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
            row.response = try makeHalfResponse(code: "7203", fyEnds: years3)
            row.cacheVersion = "stale"
            row.requestedYears = 5
            try await row.create(on: app.db)

            let json = try await loadStoredHalfFinancials(code: "7203", years: 1, db: app.db)
            #expect(json == nil)
        }
    }

    /// 床未満は 404。床は明示定数で、現行版との完全一致ではない（issue #73 の half-v2 バンプ対応）。
    @Test func loadStoredHalfFinancialsReturnsNilWhenBelowMinServable() async throws {
        try await withMigratedApp { app in
            let row = CompanyHalfFinancials()
            row.id = "7203"
            row.response = try makeHalfResponse(code: "7203", fyEnds: years3)
            row.cacheVersion = "half-v0"
            row.requestedYears = 5
            try await row.create(on: app.db)

            let json = try await loadStoredHalfFinancials(code: "7203", years: 1, db: app.db)
            #expect(json == nil)
        }
    }

    /// 床ちょうど（half-v1）は現行版（half-v2）でなくても 200。
    @Test func loadStoredHalfFinancialsAcceptsMinServableVersion() async throws {
        try await withMigratedApp { app in
            let row = CompanyHalfFinancials()
            row.id = "7203"
            row.response = try makeHalfResponse(code: "7203", fyEnds: years3)
            row.cacheVersion = "half-v1"
            row.requestedYears = 5
            try await row.create(on: app.db)

            let json = try #require(
                try await loadStoredHalfFinancials(code: "7203", years: 1, db: app.db))
            #expect(json["code"] as? String == "7203")
        }
    }

    @Test func loadStoredHalfFinancialsReturnsNilWhenYearsInsufficient() async throws {
        try await withMigratedApp { app in
            let row = CompanyHalfFinancials()
            row.id = "7203"
            row.response = try makeHalfResponse(code: "7203", fyEnds: years3)
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

    // 半期上限を超える要求年数はクランプして warm read を返す（nil にしない）。
    // クランプ前は requestedYears(=halfMaxYears) >= years(halfMaxYears+1) が偽で常に空振りし、
    // CLI 既定（analyzeDefaultYears=6 > 5）がサーバーをライブ計算へ落としていた。
    @Test func loadStoredHalfFinancialsClampsYearsBeyondHalfMax() async throws {
        try await withMigratedApp { app in
            let row = CompanyHalfFinancials()
            row.id = "7203"
            row.response = try makeHalfResponse(code: "7203", fyEnds: years3)
            row.cacheVersion = companyHalfFinancialsCacheVersion
            row.requestedYears = Api.halfMaxYears
            try await row.create(on: app.db)

            let json = try #require(
                try await loadStoredHalfFinancials(
                    code: "7203", years: Api.halfMaxYears + 1, db: app.db))
            let periods = try #require(json["periods"] as? [[String: Any]])
            #expect(!periods.isEmpty)
        }
    }
}
