// Stage 4 取り込みの DB ロジック（企業選定・重複排除・staleness 判定・upsert・limit）と
// read 経路（loadStoredFinancials のバージョン・年数ゲートと trim）を検証する。
// 計算（computeFinancials）は EDINET 依存のため、フェイク計算器を注入してネットワーク非依存で見る。

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
        app.migrations.add(CreateCompanyFinancials())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

/// secCode 付きの書類を 1 件投入する（Stage 4 は secCode から企業を導出する）。
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

/// 公開契約 FinancialsResponse を JSON 経由で構築する（内部 MetricsResult を介さない）。
/// years 件の年度エントリ（fy_end のみ）を持たせる。
private func makeResponse(code: String, years: Int) -> FinancialsResponse {
    let yrs = (0..<years).map { ["fy_end": "20\(20 + $0)-03-31"] }
    let dict: [String: Any] = [
        "schema_version": 2, "code": code, "name": "テスト",
        "sector": "", "market": "", "currency": "JPY", "unit": "百万円",
        "years": yrs,
    ]
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(FinancialsResponse.self, from: data)
}

/// 前年依存フィールド（増減・ROIC/ROE 差分）を全年に入れた応答を新しい順で構築する。
/// trim 後の最古年でこれらが null 化されることを検証するために使う。
private let priorDependentKeys = [
    "business_profit_change", "sales_change_impact", "gross_margin_change_impact",
    "sga_change_impact", "roic_delta", "roic_margin_effect", "roic_turnover_effect",
    "roe_delta", "roe_net_margin_effect", "roe_asset_turnover_effect", "roe_leverage_effect",
]
private func makeResponseWithChanges(code: String, years: Int) -> FinancialsResponse {
    let yrs = (0..<years).map { i -> [String: Any] in
        var y: [String: Any] = ["fy_end": "20\(25 - i)-03-31", "sales": 1000.0 + Double(i)]
        for key in priorDependentKeys { y[key] = 1.0 }
        return y
    }
    let dict: [String: Any] = [
        "schema_version": 2, "code": code, "name": "テスト",
        "sector": "", "market": "", "currency": "JPY", "unit": "百万円", "years": yrs,
    ]
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(FinancialsResponse.self, from: data)
}

@Suite struct Stage4IngestTests {
    @Test func ingestStoresFinancialsForEachDistinctCompany() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            try await seedDocument("S2", secCode: "67580", db: app.db)

            let summary = try await runStage4Ingest(db: app.db, years: 5, limit: nil) { code in
                makeResponse(code: code, years: 5)
            }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
            #expect(summary.skipped == 0)
            #expect(summary.failed == 0)
            #expect(try await CompanyFinancials.query(on: app.db).count() == 2)
            #expect(try await CompanyFinancials.find("7203", on: app.db) != nil)
            #expect(try await CompanyFinancials.find("6758", on: app.db) != nil)
        }
    }

    @Test func ingestDedupesMultipleDocumentsOfSameCompany() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            try await seedDocument("S2", secCode: "72030", db: app.db)

            let summary = try await runStage4Ingest(db: app.db, years: 5, limit: nil) { code in
                makeResponse(code: code, years: 5)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            #expect(try await CompanyFinancials.query(on: app.db).count() == 1)
        }
    }

    @Test func ingestSkipsDocumentsWithoutValidSecCode() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: nil, db: app.db)
            try await seedDocument("S2", secCode: "1234", db: app.db)  // 5 桁でない
            try await seedDocument("S3", secCode: "12345", db: app.db)  // 末尾 0 でない

            let summary = try await runStage4Ingest(db: app.db, years: 5, limit: nil) { code in
                makeResponse(code: code, years: 5)
            }

            #expect(summary.attempted == 0)
            #expect(try await CompanyFinancials.query(on: app.db).count() == 0)
        }
    }

    @Test func ingestSkipsCompanyAlreadyComputedAtCurrentVersionAndYears() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            let pre = CompanyFinancials()
            pre.id = "7203"
            pre.response = makeResponse(code: "7203", years: 6)
            pre.cacheVersion = blueTickerVersion
            pre.requestedYears = 6
            try await pre.create(on: app.db)

            let summary = try await runStage4Ingest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run for a fresh company")
                return makeResponse(code: "x", years: 5)
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
            #expect(summary.stored == 0)
        }
    }

    @Test func ingestRecomputesWhenStoredYearsInsufficient() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            let pre = CompanyFinancials()
            pre.id = "7203"
            pre.response = makeResponse(code: "7203", years: 3)
            pre.cacheVersion = blueTickerVersion
            pre.requestedYears = 3
            try await pre.create(on: app.db)

            let summary = try await runStage4Ingest(db: app.db, years: 5, limit: nil) { code in
                makeResponse(code: code, years: 5)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyFinancials.find("7203", on: app.db))
            #expect(row.requestedYears == 5)
        }
    }

    @Test func ingestRecomputesWhenVersionMismatches() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            let stale = CompanyFinancials()
            stale.id = "7203"
            stale.response = makeResponse(code: "7203", years: 6)
            stale.cacheVersion = "0.0.0"
            stale.requestedYears = 6
            try await stale.create(on: app.db)

            let summary = try await runStage4Ingest(db: app.db, years: 5, limit: nil) { code in
                makeResponse(code: code, years: 5)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyFinancials.find("7203", on: app.db))
            #expect(row.cacheVersion == blueTickerVersion)
            #expect(try await CompanyFinancials.query(on: app.db).count() == 1)
        }
    }

    @Test func ingestCountsComputeFailuresWithoutStoring() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)

            let summary = try await runStage4Ingest(db: app.db, years: 5, limit: nil) { _ in nil }

            #expect(summary.attempted == 1)
            #expect(summary.failed == 1)
            #expect(summary.stored == 0)
            #expect(try await CompanyFinancials.query(on: app.db).count() == 0)
        }
    }

    @Test func ingestLimitsNewlyAttemptedCompanies() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            try await seedDocument("S2", secCode: "67580", db: app.db)
            try await seedDocument("S3", secCode: "99840", db: app.db)

            let summary = try await runStage4Ingest(db: app.db, years: 5, limit: 2) { code in
                makeResponse(code: code, years: 5)
            }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
            #expect(try await CompanyFinancials.query(on: app.db).count() == 2)
        }
    }

    // MARK: - read 経路

    @Test func loadStoredFinancialsTrimsToRequestedYears() async throws {
        try await withMigratedApp { app in
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = makeResponse(code: "7203", years: 6)
            row.cacheVersion = blueTickerVersion
            row.requestedYears = 6
            try await row.create(on: app.db)

            let json = try #require(
                try await loadStoredFinancials(code: "7203", years: 3, db: app.db))
            let years = try #require(json["years"] as? [[String: Any]])
            #expect(years.count == 3)
            #expect(json["code"] as? String == "7203")
        }
    }

    @Test func loadStoredFinancialsReturnsNilWhenVersionMismatch() async throws {
        try await withMigratedApp { app in
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = makeResponse(code: "7203", years: 6)
            row.cacheVersion = "0.0.0"
            row.requestedYears = 6
            try await row.create(on: app.db)

            let json = try await loadStoredFinancials(code: "7203", years: 3, db: app.db)
            #expect(json == nil)
        }
    }

    @Test func loadStoredFinancialsReturnsNilWhenYearsInsufficient() async throws {
        try await withMigratedApp { app in
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = makeResponse(code: "7203", years: 3)
            row.cacheVersion = blueTickerVersion
            row.requestedYears = 3
            try await row.create(on: app.db)

            let json = try await loadStoredFinancials(code: "7203", years: 5, db: app.db)
            #expect(json == nil)
        }
    }

    @Test func loadStoredFinancialsReturnsNilForUnknownCompany() async throws {
        try await withMigratedApp { app in
            let json = try await loadStoredFinancials(code: "0000", years: 5, db: app.db)
            #expect(json == nil)
        }
    }

    /// years <= 0 は DB で空 200 を返さず nil（ライブ計算＝notFound へ委ねる）。
    @Test func loadStoredFinancialsReturnsNilForNonPositiveYears() async throws {
        try await withMigratedApp { app in
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = makeResponse(code: "7203", years: 6)
            row.cacheVersion = blueTickerVersion
            row.requestedYears = 6
            try await row.create(on: app.db)

            #expect(try await loadStoredFinancials(code: "7203", years: 0, db: app.db) == nil)
        }
    }

    /// trim で最古になった年は前年依存フィールドが null 化され、ライブ経路（最古年は前年なし）と一致する。
    /// 前年非依存の項目（sales 等）と、最古でない年の前年依存値は保持される。
    @Test func loadStoredFinancialsClearsPriorDependentMetricsOnTrimmedOldestYear() async throws {
        try await withMigratedApp { app in
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = makeResponseWithChanges(code: "7203", years: 6)
            row.cacheVersion = blueTickerVersion
            row.requestedYears = 6
            try await row.create(on: app.db)

            let json = try #require(
                try await loadStoredFinancials(code: "7203", years: 3, db: app.db))
            let years = try #require(json["years"] as? [[String: Any]])
            #expect(years.count == 3)
            // 最新2年（前年あり）は前年依存値を保持。
            #expect(years[0]["business_profit_change"] as? Double != nil)
            #expect(years[1]["roe_delta"] as? Double != nil)
            // 縮めて最古になった年は前年依存値が全て null。
            for key in priorDependentKeys {
                #expect(years[2][key] is NSNull, "\(key) should be null on trimmed oldest year")
            }
            // 前年非依存の項目は最古年でも保持。
            #expect(years[2]["sales"] as? Double != nil)
        }
    }

    /// trim が起きない（要求年数 >= 格納年数）ときは最古年の前年依存値をそのまま返す。
    @Test func loadStoredFinancialsKeepsMetricsWhenNotTrimmed() async throws {
        try await withMigratedApp { app in
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = makeResponseWithChanges(code: "7203", years: 3)
            row.cacheVersion = blueTickerVersion
            row.requestedYears = 3
            try await row.create(on: app.db)

            let json = try #require(
                try await loadStoredFinancials(code: "7203", years: 3, db: app.db))
            let years = try #require(json["years"] as? [[String: Any]])
            #expect(years.count == 3)
            #expect(years[2]["business_profit_change"] as? Double != nil)
        }
    }
}
