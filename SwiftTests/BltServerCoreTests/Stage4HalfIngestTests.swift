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

/// フェイク計算器（成功ケース）用: makeHalfResponse の throws を吸収し `.success` へ包む。
private func makeHalfSuccess(code: String, fyEnds: [String]) -> HalfFinancialsComputeResult {
    guard let response = try? makeHalfResponse(code: code, fyEnds: fyEnds) else {
        Issue.record("makeHalfResponse encode failed unexpectedly")
        return .failed
    }
    return .success(response)
}

private let years3 = ["2023-03-31", "2024-03-31", "2025-03-31"]

@Suite struct Stage4HalfIngestTests {
    @Test func ingestStoresHalfFinancialsForEachDistinctCompany() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            try await seedDocument("S2", secCode: "67580", db: app.db)

            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { code in
                makeHalfSuccess(code: code, fyEnds: years3)
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
                return makeHalfSuccess(code: "x", fyEnds: years3)
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
                makeHalfSuccess(code: code, fyEnds: years3)
            }

            #expect(summary.attempted == 1)
            #expect(try await CompanyHalfFinancials.find("7203", on: app.db) != nil)
            #expect(try await CompanyHalfFinancials.find("6758", on: app.db) == nil)
        }
    }

    // MARK: - explicitCodes 絞り込み（--codes 手動指定）

    @Test func ingestSkipsCompaniesNotInExplicitCodes() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)  // explicitCodes に含む
            try await seedDocument("S2", secCode: "67580", db: app.db)  // 含まない

            let summary = try await runStage4HalfIngest(
                db: app.db, years: 5, limit: nil, explicitCodes: ["7203"]
            ) { code in
                makeHalfSuccess(code: code, fyEnds: years3)
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
                return makeHalfSuccess(code: "x", fyEnds: years3)
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
                makeHalfSuccess(code: code, fyEnds: years3)
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

            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { _ in .failed }

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
                makeHalfSuccess(code: code, fyEnds: years3)
            }
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyHalfFinancials.find("7203", on: app.db))
            #expect(row.cacheVersion == companyHalfFinancialsCacheVersion)
        }
    }

    @Test func ingestCountsComputeFailuresWithoutStoring() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { _ in .failed }
            #expect(summary.failed == 1)
            #expect(summary.notApplicable == 0)
            #expect(summary.stored == 0)
            #expect(try await CompanyHalfFinancials.query(on: app.db).count() == 0)
        }
    }

    /// 対象外（例: 半期報告書未提出）は failed に混入させず notApplicable として数える（issue #73 フォローアップ）。
    /// プレースホルダ行（periods 空）を保存する点は issue #86 派生（無駄な再試行を防ぐ）。
    @Test func ingestCountsNotApplicableSeparatelyFromFailed() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { _ in
                .notApplicable
            }
            #expect(summary.attempted == 1)
            #expect(summary.notApplicable == 1)
            #expect(summary.failed == 0)
            #expect(summary.stored == 0)
            let row = try #require(try await CompanyHalfFinancials.find("7203", on: app.db))
            #expect(row.cacheVersion == companyHalfFinancialsCacheVersion)
            #expect(row.response.periodCount == 0)
        }
    }

    /// プレースホルダ行が既にあり highWater が一致するなら、次回 ingest は missing として
    /// 再試行しない（skip される）。issue #86 派生（毎回無条件リトライの再発防止）。
    @Test func ingestSkipsNotApplicablePlaceholderWhenHighWaterMatches() async throws {
        try await withMigratedApp { app in
            try await seedDocument(
                "S1", secCode: "72030", docTypeCode: "120",
                submitDateTime: "2025-06-20 09:00", db: app.db)

            let first = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { _ in .notApplicable }
            #expect(first.notApplicable == 1)

            let second = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run again when high-water is unchanged")
                return .notApplicable
            }

            #expect(second.skipped == 1)
            #expect(second.attempted == 0)
            #expect(second.notApplicable == 0)
        }
    }

    /// notApplicable プレースホルダ行は REST read で 200（空 periods）を返さず 404 のまま
    /// （公開インターフェースの挙動は変えない。issue #86 派生）。
    @Test func loadStoredHalfFinancialsReturnsNilForNotApplicablePlaceholder() async throws {
        try await withMigratedApp { app in
            try await seedDocument(
                "S1", secCode: "72030", docTypeCode: "120",
                submitDateTime: "2025-06-20 09:00", db: app.db)
            _ = try await runStage4HalfIngest(db: app.db, years: 5, limit: nil) { _ in .notApplicable }

            #expect(try await loadStoredHalfFinancials(code: "7203", years: 5, db: app.db) == nil)
            #expect(try await loadStoredHalfAnalysis(code: "7203", years: 5, db: app.db) == nil)
        }
    }

    @Test func ingestLimitsNewlyAttemptedCompanies() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            try await seedDocument("S2", secCode: "67580", db: app.db)
            try await seedDocument("S3", secCode: "99840", db: app.db)

            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: 2) { code in
                makeHalfSuccess(code: code, fyEnds: years3)
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
                makeHalfSuccess(code: code, fyEnds: years3)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            #expect(try await CompanyHalfFinancials.find("6758", on: app.db) != nil)
            let staleAfter = try #require(try await CompanyHalfFinancials.find("7203", on: app.db))
            #expect(staleAfter.cacheVersion == "stale")  // stale より先に空白を埋める
        }
    }

    /// 新規有報(high-water 不一致)は cache_version 不一致より優先して処理される（通期と同じ規則）。
    @Test func ingestPrioritizesNewFilingOverStaleVersionWhenLimited() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)  // high-water 変化なし
            try await seedDocument("S2", secCode: "67580", submitDateTime: "2026-01-15 09:00", db: app.db)  // 新規有報

            let staleVersion = CompanyHalfFinancials()
            staleVersion.id = "7203"
            staleVersion.response = try makeHalfResponse(code: "7203", fyEnds: years3)
            staleVersion.cacheVersion = "stale"
            staleVersion.requestedYears = 5
            staleVersion.highWater = "2025-06-20 09:00"  // seedDocument のデフォルトと一致 → high-water は非stale
            try await staleVersion.create(on: app.db)

            let staleHighWater = CompanyHalfFinancials()
            staleHighWater.id = "6758"
            staleHighWater.response = try makeHalfResponse(code: "6758", fyEnds: years3)
            staleHighWater.cacheVersion = companyHalfFinancialsCacheVersion
            staleHighWater.requestedYears = 5
            staleHighWater.highWater = "2025-06-01 09:00"  // 現在の提出日時より古い → 新規有報あり
            try await staleHighWater.create(on: app.db)

            let summary = try await runStage4HalfIngest(db: app.db, years: 5, limit: 1) { code in
                makeHalfSuccess(code: code, fyEnds: years3)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let processed = try #require(try await CompanyHalfFinancials.find("6758", on: app.db))
            #expect(processed.cacheVersion == companyHalfFinancialsCacheVersion)
            let untouched = try #require(try await CompanyHalfFinancials.find("7203", on: app.db))
            #expect(untouched.cacheVersion == "stale")  // version stale は後回しのまま未処理
        }
    }

    // MARK: - servable/unservable 集計

    @Test func countServableCompanyHalfFinancialsSplitsByReadFloor() async throws {
        try await withMigratedApp { app in
            // half-v1: 床(2)未満 → unservable。half-v2/half-v3: 床以上 → servable。
            for (code, version) in [("7203", "half-v1"), ("6758", "half-v2"), ("9984", "half-v3")] {
                let row = CompanyHalfFinancials()
                row.id = code
                row.response = try makeHalfResponse(code: code, fyEnds: years3)
                row.cacheVersion = version
                row.requestedYears = 3
                try await row.create(on: app.db)
            }

            let coverage = try await countServableCompanyHalfFinancials(db: app.db)
            #expect(coverage.servable == 2)
            #expect(coverage.unservable == 1)
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

    /// 床ちょうど（half-v2）は 200。
    @Test func loadStoredHalfFinancialsAcceptsMinServableVersion() async throws {
        try await withMigratedApp { app in
            let row = CompanyHalfFinancials()
            row.id = "7203"
            row.response = try makeHalfResponse(code: "7203", fyEnds: years3)
            row.cacheVersion = "half-v2"
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
