// 財務取り込みの DB ロジック（企業選定・重複排除・staleness 判定・upsert・limit）と
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
        // AddHighWaterToCompanyFinancials は両テーブルを触るため、half 側も作っておく。
        app.migrations.add(CreateCompanyHalfFinancials())
        app.migrations.add(AddHighWaterToCompanyFinancials())
        app.migrations.add(AddAssemblyFingerprintToCompanyFinancials())
        app.migrations.add(CreateScreenIndex())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

/// secCode 付きの書類を 1 件投入する（財務取り込み は secCode から企業を導出する）。
/// docTypeCode / submitDateTime は high-water 判定のテストで可変にできるよう引数化する。
private func seedDocument(
    _ docID: String, secCode: String?, docTypeCode: String = "120",
    submitDateTime: String = "2025-06-20 09:00",
    ordinanceCode: String? = Api.ordinanceCompanyDisclosure,
    formCode: String? = "030000",
    db: Database
) async throws {
    let model = EdinetDocument()
    model.id = docID
    model.edinetCode = "E00001"
    model.secCode = secCode
    model.filerName = "テスト株式会社"
    model.docTypeCode = docTypeCode
    model.ordinanceCode = ordinanceCode
    model.formCode = formCode
    model.submitDateTime = submitDateTime
    try await model.create(on: db)
}

/// 公開契約 FinancialsResponse を JSON 経由で構築する（内部 MetricsResult を介さない）。
/// years 件の年度エントリ（fy_end のみ）を持たせる。
private func makeResponse(code: String, years: Int) throws -> FinancialsResponse {
    let yrs = (0..<years).map { ["fy_end": "20\(20 + $0)-03-31"] }
    let dict: [String: Any] = [
        "schema_version": 2, "code": code, "name": "テスト",
        "sector": "", "market": "", "currency": "JPY", "unit": "百万円",
        "years": yrs,
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(FinancialsResponse.self, from: data)
}

/// 前年依存フィールド（増減・ROIC/ROE 差分）を全年に入れた応答を新しい順で構築する。
/// trim 後の最古年でこれらが null 化されることを検証するために使う。
private let priorDependentKeys = [
    "business_profit_change", "sales_change_impact", "gross_margin_change_impact",
    "sga_change_impact", "roic_delta", "roic_margin_effect", "roic_turnover_effect",
    "roe_delta", "roe_net_margin_effect", "roe_asset_turnover_effect", "roe_leverage_effect",
]
/// フェイク計算器のヘルパー: makeResponse の結果を FinancialsComputeResult でラップする。
private func fakeSuccess(code: String, years: Int) -> FinancialsComputeResult {
    guard let response = try? makeResponse(code: code, years: years) else { return .failed }
    return .success(response)
}

private func makeResponseWithChanges(code: String, years: Int) throws -> FinancialsResponse {
    let yrs = (0..<years).map { i -> [String: Any] in
        var y: [String: Any] = ["fy_end": "20\(25 - i)-03-31", "sales": 1000.0 + Double(i)]
        for key in priorDependentKeys { y[key] = 1.0 }
        return y
    }
    let dict: [String: Any] = [
        "schema_version": 2, "code": code, "name": "テスト",
        "sector": "", "market": "", "currency": "JPY", "unit": "百万円", "years": yrs,
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(FinancialsResponse.self, from: data)
}

@Suite struct FinancialsIngestTests {
    @Test func ingestStoresFinancialsForEachDistinctCompany() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            try await seedDocument("S2", secCode: "67580", db: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { code in
                fakeSuccess(code: code, years: 5)
            }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
            #expect(summary.skipped == 0)
            #expect(summary.failed == 0)
            #expect(try await CompanyFinancials.query(on: app.db).count() == 2)
            let toyota = try #require(try await CompanyFinancials.find("7203", on: app.db))
            #expect(toyota.assemblyFingerprint == financialsAssemblyFingerprint())
            #expect(try await CompanyFinancials.find("6758", on: app.db) != nil)
        }
    }

    // MARK: - listedCodes 絞り込み（上場廃止・外国法人の除外）

    @Test func ingestSkipsCompaniesNotInListedCodes() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)  // listedCodes に含む
            try await seedDocument("S2", secCode: "67580", db: app.db)  // 上場廃止想定・含まない

            let summary = try await runFinancialsIngest(
                db: app.db, years: 5, limit: nil, listedCodes: ["7203"]
            ) { code in
                fakeSuccess(code: code, years: 5)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            #expect(try await CompanyFinancials.find("7203", on: app.db) != nil)
            #expect(try await CompanyFinancials.find("6758", on: app.db) == nil)
        }
    }

    @Test func ingestProcessesAllCompaniesWhenListedCodesIsNil() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            try await seedDocument("S2", secCode: "67580", db: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { code in
                fakeSuccess(code: code, years: 5)
            }

            #expect(summary.attempted == 2)
            #expect(try await CompanyFinancials.query(on: app.db).count() == 2)
        }
    }

    // MARK: - explicitCodes 絞り込み（--codes 手動指定）

    @Test func ingestSkipsCompaniesNotInExplicitCodes() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)  // explicitCodes に含む
            try await seedDocument("S2", secCode: "67580", db: app.db)  // 含まない

            let summary = try await runFinancialsIngest(
                db: app.db, years: 5, limit: nil, explicitCodes: ["7203"]
            ) { code in
                fakeSuccess(code: code, years: 5)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            #expect(try await CompanyFinancials.find("7203", on: app.db) != nil)
            #expect(try await CompanyFinancials.find("6758", on: app.db) == nil)
        }
    }

    @Test func ingestCombinesListedAndExplicitCodesFilters() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)  // 両方に含む
            try await seedDocument("S2", secCode: "67580", db: app.db)  // listedCodes に含まない
            try await seedDocument("S3", secCode: "99840", db: app.db)  // explicitCodes に含まない

            let summary = try await runFinancialsIngest(
                db: app.db, years: 5, limit: nil, listedCodes: ["7203", "9984"],
                explicitCodes: ["7203"]
            ) { code in
                fakeSuccess(code: code, years: 5)
            }

            #expect(summary.attempted == 1)
            #expect(try await CompanyFinancials.find("7203", on: app.db) != nil)
            #expect(try await CompanyFinancials.find("6758", on: app.db) == nil)
            #expect(try await CompanyFinancials.find("9984", on: app.db) == nil)
        }
    }

    @Test func ingestDedupesMultipleDocumentsOfSameCompany() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            try await seedDocument("S2", secCode: "72030", db: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { code in
                fakeSuccess(code: code, years: 5)
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

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { code in
                fakeSuccess(code: code, years: 5)
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
            pre.response = try makeResponse(code: "7203", years: 6)
            pre.cacheVersion = companyFinancialsCacheVersion
            pre.requestedYears = 6
            pre.highWater = "2025-06-20 09:00"  // seedDocument のデフォルト submitDateTime と一致
            pre.assemblyFingerprint = financialsAssemblyFingerprint()
            try await pre.create(on: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run for a fresh company")
                return fakeSuccess(code: "x", years: 5)
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
            #expect(summary.stored == 0)
        }
    }

    // MARK: - high-water 鮮度トリガー（issue #26）

    @Test func skipsWhenHighWaterMatches() async throws {
        try await withMigratedApp { app in
            try await seedDocument(
                "S1", secCode: "72030", docTypeCode: "120",
                submitDateTime: "2025-06-20 09:00", db: app.db)
            let pre = CompanyFinancials()
            pre.id = "7203"
            pre.response = try makeResponse(code: "7203", years: 5)
            pre.cacheVersion = companyFinancialsCacheVersion
            pre.requestedYears = 5
            pre.highWater = "2025-06-20 09:00"
            pre.assemblyFingerprint = financialsAssemblyFingerprint()
            try await pre.create(on: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run when high-water matches")
                return fakeSuccess(code: "x", years: 5)
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    @Test func recomputesWhenNewerAnnualFilingArrives() async throws {
        try await withMigratedApp { app in
            try await seedDocument(
                "S1", secCode: "72030", docTypeCode: "120",
                submitDateTime: "2025-06-20 09:00", db: app.db)
            let pre = CompanyFinancials()
            pre.id = "7203"
            pre.response = try makeResponse(code: "7203", years: 5)
            pre.cacheVersion = companyFinancialsCacheVersion
            pre.requestedYears = 5
            pre.highWater = "2025-06-20 09:00"  // 旧提出時点の high-water
            try await pre.create(on: app.db)

            // 同一企業に、より新しい有報（訂正含む消費種別）が追加提出された。
            try await seedDocument(
                "S2", secCode: "72030", docTypeCode: "130",
                submitDateTime: "2026-01-15 09:00", db: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { code in
                fakeSuccess(code: code, years: 5)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyFinancials.find("7203", on: app.db))
            #expect(row.highWater == "2026-01-15 09:00")
        }
    }

    @Test func doesNotRecomputeWhenOnlyNonConsumedDocTypeArrives() async throws {
        try await withMigratedApp { app in
            try await seedDocument(
                "S1", secCode: "72030", docTypeCode: "120",
                submitDateTime: "2025-06-01 09:00", db: app.db)
            let pre = CompanyFinancials()
            pre.id = "7203"
            pre.response = try makeResponse(code: "7203", years: 5)
            pre.cacheVersion = companyFinancialsCacheVersion
            pre.requestedYears = 5
            pre.highWater = "2025-06-01 09:00"
            pre.assemblyFingerprint = financialsAssemblyFingerprint()
            try await pre.create(on: app.db)

            // 四半期報告書(140)は 財務取り込み の消費種別（120/130）に含まれないため、
            // より新しい提出があっても通期の high-water は前進しない。
            try await seedDocument(
                "S2", secCode: "72030", docTypeCode: "140",
                submitDateTime: "2025-08-01 09:00", db: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run when only a non-consumed doc type arrives")
                return fakeSuccess(code: "x", years: 5)
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    @Test func doesNotRecomputeWhenOnlyTrustBeneficiaryOrdinance030Arrives() async throws {
        try await withMigratedApp { app in
            try await seedDocument(
                "S1", secCode: "82530", docTypeCode: "120",
                submitDateTime: "2026-06-16 11:38", db: app.db)
            let pre = CompanyFinancials()
            pre.id = "8253"
            pre.response = try makeResponse(code: "8253", years: 5)
            pre.cacheVersion = companyFinancialsCacheVersion
            pre.requestedYears = 5
            pre.highWater = "2026-06-16 11:38"
            pre.assemblyFingerprint = financialsAssemblyFingerprint()
            try await pre.create(on: app.db)

            // docType 120 でも特定有価証券府令(030)は会社有報の high-water に入れない
            try await seedDocument(
                "S-trust", secCode: "82530", docTypeCode: "120",
                submitDateTime: "2026-08-28 16:00",
                ordinanceCode: "030", formCode: "09A000", db: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run for trust beneficiary 120")
                return fakeSuccess(code: "x", years: 5)
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
            let row = try #require(try await CompanyFinancials.find("8253", on: app.db))
            #expect(row.highWater == "2026-06-16 11:38")
        }
    }

    @Test func keepsHighWaterOnComputeFailure() async throws {
        try await withMigratedApp { app in
            try await seedDocument(
                "S1", secCode: "72030", docTypeCode: "120",
                submitDateTime: "2025-06-20 09:00", db: app.db)
            let pre = CompanyFinancials()
            pre.id = "7203"
            pre.response = try makeResponse(code: "7203", years: 5)
            pre.cacheVersion = companyFinancialsCacheVersion
            pre.requestedYears = 5
            pre.highWater = "2025-01-01 09:00"  // 現在の max より古い → 再計算対象
            try await pre.create(on: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in .failed }

            #expect(summary.attempted == 1)
            #expect(summary.failed == 1)
            #expect(summary.stored == 0)
            let row = try #require(try await CompanyFinancials.find("7203", on: app.db))
            #expect(row.highWater == "2025-01-01 09:00")  // 失敗時は更新されず据え置き
        }
    }

    @Test func ingestRecomputesWhenStoredYearsInsufficient() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            let pre = CompanyFinancials()
            pre.id = "7203"
            pre.response = try makeResponse(code: "7203", years: 3)
            pre.cacheVersion = companyFinancialsCacheVersion
            pre.requestedYears = 3
            try await pre.create(on: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { code in
                fakeSuccess(code: code, years: 5)
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
            stale.response = try makeResponse(code: "7203", years: 6)
            stale.cacheVersion = "0.0.0"
            stale.requestedYears = 6
            try await stale.create(on: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { code in
                fakeSuccess(code: code, years: 5)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyFinancials.find("7203", on: app.db))
            #expect(row.cacheVersion == companyFinancialsCacheVersion)
            #expect(row.assemblyFingerprint == financialsAssemblyFingerprint())
            #expect(try await CompanyFinancials.query(on: app.db).count() == 1)
        }
    }

    // MARK: - 正本組立指紋（タスク #11）

    @Test func ingestRecomputesWhenAssemblyFingerprintMismatches() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            let stale = CompanyFinancials()
            stale.id = "7203"
            stale.response = try makeResponse(code: "7203", years: 6)
            stale.cacheVersion = companyFinancialsCacheVersion
            stale.requestedYears = 6
            stale.highWater = "2025-06-20 09:00"
            stale.assemblyFingerprint = "statement-v0|stale-canonical"
            try await stale.create(on: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { code in
                fakeSuccess(code: code, years: 5)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyFinancials.find("7203", on: app.db))
            #expect(row.assemblyFingerprint == financialsAssemblyFingerprint())
        }
    }

    @Test func ingestRecomputesWhenAssemblyFingerprintIsMissing() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            let stale = CompanyFinancials()
            stale.id = "7203"
            stale.response = try makeResponse(code: "7203", years: 6)
            stale.cacheVersion = companyFinancialsCacheVersion
            stale.requestedYears = 6
            stale.highWater = "2025-06-20 09:00"
            try await stale.create(on: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { code in
                fakeSuccess(code: code, years: 5)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyFinancials.find("7203", on: app.db))
            #expect(row.assemblyFingerprint == financialsAssemblyFingerprint())
        }
    }

    @Test func ingestSkipsWhenAssemblyFingerprintMatches() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            let pre = CompanyFinancials()
            pre.id = "7203"
            pre.response = try makeResponse(code: "7203", years: 5)
            pre.cacheVersion = companyFinancialsCacheVersion
            pre.requestedYears = 5
            pre.highWater = "2025-06-20 09:00"
            pre.assemblyFingerprint = financialsAssemblyFingerprint()
            try await pre.create(on: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run when assembly fingerprint matches")
                return fakeSuccess(code: "x", years: 5)
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    /// 正本指紋のずれは ingest 再組立対象だが、read 床は fin-vN のまま（再計算待ちでも 200）。
    @Test func loadStoredFinancialsAcceptsStaleAssemblyFingerprint() async throws {
        try await withMigratedApp { app in
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = try makeResponse(code: "7203", years: 6)
            row.cacheVersion = companyFinancialsCacheVersion
            row.requestedYears = 6
            row.assemblyFingerprint = "statement-v0|stale-canonical"
            try await row.create(on: app.db)

            let json = try #require(
                try await loadStoredFinancials(code: "7203", years: 3, db: app.db))
            #expect(json["code"] as? String == "7203")
        }
    }

    @Test func ingestCountsComputeFailuresWithoutStoring() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in .failed }

            #expect(summary.attempted == 1)
            #expect(summary.failed == 1)
            #expect(summary.stored == 0)
            #expect(try await CompanyFinancials.query(on: app.db).count() == 0)
        }
    }

    // MARK: - notApplicable（有価証券報告書未提出、issue #86）

    /// notApplicable（新規上場等で初回本決算前）は failed に混入せず、専用カウンタに計上される。
    @Test func ingestCountsNotApplicableSeparatelyFromFailed() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in .notApplicable }

            #expect(summary.attempted == 1)
            #expect(summary.notApplicable == 1)
            #expect(summary.failed == 0)
            #expect(summary.stored == 0)
        }
    }

    /// notApplicable はプレースホルダ行（years 空）を保存する。次回 ingest で highWater が
    /// 変わらない限り、無駄な再計算（missing 扱いでの再試行）を防ぐのが目的。
    @Test func ingestStoresPlaceholderRowOnNotApplicable() async throws {
        try await withMigratedApp { app in
            try await seedDocument(
                "S1", secCode: "72030", docTypeCode: "120",
                submitDateTime: "2025-06-20 09:00", db: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in .notApplicable }

            #expect(summary.notApplicable == 1)
            let row = try #require(try await CompanyFinancials.find("7203", on: app.db))
            #expect(row.cacheVersion == companyFinancialsCacheVersion)
            #expect(row.requestedYears == 5)
            #expect(row.highWater == "2025-06-20 09:00")
            #expect(row.assemblyFingerprint == financialsAssemblyFingerprint())
            #expect(row.response.yearCount == 0)
        }
    }

    /// プレースホルダ行が既にあり highWater が一致するなら、次回 ingest は missing として
    /// 再試行しない（skip される）。issue #86 の症状（毎回無条件リトライ）の再発防止。
    @Test func ingestSkipsNotApplicablePlaceholderWhenHighWaterMatches() async throws {
        try await withMigratedApp { app in
            try await seedDocument(
                "S1", secCode: "72030", docTypeCode: "120",
                submitDateTime: "2025-06-20 09:00", db: app.db)

            let first = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in .notApplicable }
            #expect(first.notApplicable == 1)

            let second = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run again when high-water is unchanged")
                return .notApplicable
            }

            #expect(second.skipped == 1)
            #expect(second.attempted == 0)
            #expect(second.notApplicable == 0)
        }
    }

    /// notApplicable プレースホルダ行は REST read で 200（空 years）を返さず 404 のまま
    /// （公開インターフェースの挙動は変えない。issue #86）。
    @Test func loadStoredFinancialsReturnsNilForNotApplicablePlaceholder() async throws {
        try await withMigratedApp { app in
            try await seedDocument(
                "S1", secCode: "72030", docTypeCode: "120",
                submitDateTime: "2025-06-20 09:00", db: app.db)
            _ = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in .notApplicable }

            #expect(try await loadStoredFinancials(code: "7203", years: 5, db: app.db) == nil)
            #expect(try await loadStoredAnalysis(code: "7203", years: 5, db: app.db) == nil)
        }
    }

    @Test func ingestLimitsNewlyAttemptedCompanies() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            try await seedDocument("S2", secCode: "67580", db: app.db)
            try await seedDocument("S3", secCode: "99840", db: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: 2) { code in
                fakeSuccess(code: code, years: 5)
            }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
            #expect(try await CompanyFinancials.query(on: app.db).count() == 2)
        }
    }

    @Test func ingestPrioritizesMissingBeforeStaleWhenLimited() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)  // stale existing
            try await seedDocument("S2", secCode: "67580", db: app.db)  // missing

            let stale = CompanyFinancials()
            stale.id = "7203"
            stale.response = try makeResponse(code: "7203", years: 6)
            stale.cacheVersion = "0.0.0"
            stale.requestedYears = 6
            try await stale.create(on: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: 1) { code in
                fakeSuccess(code: code, years: 5)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            #expect(try await CompanyFinancials.find("6758", on: app.db) != nil)
            let staleAfter = try #require(try await CompanyFinancials.find("7203", on: app.db))
            #expect(staleAfter.cacheVersion == "0.0.0")  // stale より先に空白を埋める
        }
    }

    /// 新規有報(high-water 不一致)は cache_version 不一致より優先して処理される
    /// （225 等の priorityCodes 以外の一般企業の優先順位: missing > high-water > years > version）。
    @Test func ingestPrioritizesNewFilingOverStaleVersionWhenLimited() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)  // high-water 変化なし
            try await seedDocument("S2", secCode: "67580", submitDateTime: "2026-01-15 09:00", db: app.db)  // 新規有報

            let staleVersion = CompanyFinancials()
            staleVersion.id = "7203"
            staleVersion.response = try makeResponse(code: "7203", years: 6)
            staleVersion.cacheVersion = "0.0.0"
            staleVersion.requestedYears = 6
            staleVersion.highWater = "2025-06-20 09:00"  // seedDocument のデフォルトと一致 → high-water は非stale
            try await staleVersion.create(on: app.db)

            let staleHighWater = CompanyFinancials()
            staleHighWater.id = "6758"
            staleHighWater.response = try makeResponse(code: "6758", years: 6)
            staleHighWater.cacheVersion = companyFinancialsCacheVersion
            staleHighWater.requestedYears = 6
            staleHighWater.highWater = "2025-06-01 09:00"  // 現在の提出日時より古い → 新規有報あり
            try await staleHighWater.create(on: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: 1) { code in
                fakeSuccess(code: code, years: 5)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let processed = try #require(try await CompanyFinancials.find("6758", on: app.db))
            #expect(processed.cacheVersion == companyFinancialsCacheVersion)
            let untouched = try #require(try await CompanyFinancials.find("7203", on: app.db))
            #expect(untouched.cacheVersion == "0.0.0")  // version stale は後回しのまま未処理
        }
    }

    /// staleHighWater が limit を超える件数存在しても、単純連結
    /// (`missing + staleHighWater + staleYears + staleVersion`) だと staleVersion は理論上
    /// 永久に処理されない（starvation）。ラウンドロビン（`interleaved`）で全バケツに毎サイクル
    /// 一定の進捗を保証していることを確認する（issue 由来: 20日間・6,400枠処理されても
    /// staleVersion 47社が一切収束しなかった実データ観測から追加）。
    @Test func ingestDoesNotStarveStaleVersionWhenManyHighWaterCandidatesExist() async throws {
        try await withMigratedApp { app in
            let highWaterCodes = ["1000", "2000", "3000", "4000", "5000"]
            for (i, code) in highWaterCodes.enumerated() {
                try await seedDocument(
                    "H\(i)", secCode: "\(code)0", submitDateTime: "2026-01-15 09:00", db: app.db)
                let pre = CompanyFinancials()
                pre.id = code
                pre.response = try makeResponse(code: code, years: 6)
                pre.cacheVersion = companyFinancialsCacheVersion
                pre.requestedYears = 6
                pre.highWater = "2025-06-01 09:00"  // 新規有報あり
                try await pre.create(on: app.db)
            }

            try await seedDocument("V0", secCode: "60000", db: app.db)  // high-water 変化なし
            let staleVersion = CompanyFinancials()
            staleVersion.id = "6000"
            staleVersion.response = try makeResponse(code: "6000", years: 6)
            staleVersion.cacheVersion = "0.0.0"
            staleVersion.requestedYears = 6
            staleVersion.highWater = "2025-06-20 09:00"  // seedDocument のデフォルトと一致
            try await staleVersion.create(on: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: 2) { code in
                fakeSuccess(code: code, years: 5)
            }

            #expect(summary.attempted == 2)
            let processedVersion = try #require(try await CompanyFinancials.find("6000", on: app.db))
            #expect(processedVersion.cacheVersion == companyFinancialsCacheVersion)  // 飢餓状態にならず処理される
        }
    }

    @Test func ingestProcessesPriorityCodesFirstWhenLimited() async throws {
        try await withMigratedApp { app in
            try await seedDocument("S1", secCode: "72030", db: app.db)
            try await seedDocument("S2", secCode: "67580", db: app.db)
            try await seedDocument("S3", secCode: "99840", db: app.db)  // 優先指定・投入順は最後

            let summary = try await runFinancialsIngest(
                db: app.db, years: 5, limit: 1, priorityCodes: ["9984"]
            ) { code in
                fakeSuccess(code: code, years: 5)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            #expect(try await CompanyFinancials.find("9984", on: app.db) != nil)
            #expect(try await CompanyFinancials.find("7203", on: app.db) == nil)
            #expect(try await CompanyFinancials.find("6758", on: app.db) == nil)
        }
    }

    // MARK: - servable/unservable 集計

    @Test func countServableCompanyFinancialsSplitsByReadFloor() async throws {
        try await withMigratedApp { app in
            // fin-v3: 床(4)未満 → unservable。fin-v4/fin-v6: 床以上 → servable。
            for (code, version) in [("7203", "fin-v3"), ("6758", "fin-v4"), ("9984", "fin-v5")] {
                let row = CompanyFinancials()
                row.id = code
                row.response = try makeResponse(code: code, years: 1)
                row.cacheVersion = version
                row.requestedYears = 1
                try await row.create(on: app.db)
            }

            let coverage = try await countServableCompanyFinancials(db: app.db)
            #expect(coverage.servable == 2)
            #expect(coverage.unservable == 1)
        }
    }

    // MARK: - read 経路

    @Test func loadStoredFinancialsTrimsToRequestedYears() async throws {
        try await withMigratedApp { app in
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = try makeResponse(code: "7203", years: 6)
            row.cacheVersion = companyFinancialsCacheVersion
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
            row.response = try makeResponse(code: "7203", years: 6)
            row.cacheVersion = "0.0.0"
            row.requestedYears = 6
            try await row.create(on: app.db)

            let json = try await loadStoredFinancials(code: "7203", years: 3, db: app.db)
            #expect(json == nil)
        }
    }

    /// 床未満（fin-v1）は 404。床は明示定数で、現行版との完全一致ではない。
    @Test func loadStoredFinancialsReturnsNilWhenBelowMinServable() async throws {
        try await withMigratedApp { app in
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = try makeResponse(code: "7203", years: 6)
            row.cacheVersion = "fin-v1"
            row.requestedYears = 6
            try await row.create(on: app.db)

            let json = try await loadStoredFinancials(code: "7203", years: 3, db: app.db)
            #expect(json == nil)
        }
    }

    /// 床ちょうど（fin-v4）は 200。
    @Test func loadStoredFinancialsAcceptsMinServableVersion() async throws {
        try await withMigratedApp { app in
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = try makeResponse(code: "7203", years: 6)
            row.cacheVersion = "fin-v4"
            row.requestedYears = 6
            try await row.create(on: app.db)

            let json = try #require(
                try await loadStoredFinancials(code: "7203", years: 3, db: app.db))
            #expect(json["code"] as? String == "7203")
        }
    }

    /// 床判定は現行版との完全一致ではなく数値比較（n >= 床）。将来のバージョン（fin-v10）も 200。
    @Test func loadStoredFinancialsAcceptsVersionAboveCurrent() async throws {
        try await withMigratedApp { app in
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = try makeResponse(code: "7203", years: 6)
            row.cacheVersion = "fin-v10"
            row.requestedYears = 6
            try await row.create(on: app.db)

            let json = try #require(
                try await loadStoredFinancials(code: "7203", years: 3, db: app.db))
            #expect(json["code"] as? String == "7203")
        }
    }

    @Test func loadStoredFinancialsReturnsNilWhenYearsInsufficient() async throws {
        try await withMigratedApp { app in
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = try makeResponse(code: "7203", years: 3)
            row.cacheVersion = companyFinancialsCacheVersion
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
            row.response = try makeResponse(code: "7203", years: 6)
            row.cacheVersion = companyFinancialsCacheVersion
            row.requestedYears = 6
            try await row.create(on: app.db)

            #expect(try await loadStoredFinancials(code: "7203", years: 0, db: app.db) == nil)
        }
    }

    /// financials（Summary）は増減分解フィールド（Waterfall 専用、`docs/financials-summary-separation.md`）を
    /// trim の有無に関わらず一切含まない。
    @Test func loadStoredFinancialsExcludesAnalysisOnlyFields() async throws {
        try await withMigratedApp { app in
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = try makeResponseWithChanges(code: "7203", years: 6)
            row.cacheVersion = companyFinancialsCacheVersion
            row.requestedYears = 6
            try await row.create(on: app.db)

            let json = try #require(
                try await loadStoredFinancials(code: "7203", years: 3, db: app.db))
            let years = try #require(json["years"] as? [[String: Any]])
            #expect(years.count == 3)
            for year in years {
                for key in priorDependentKeys {
                    #expect(year.keys.contains(key) == false, "\(key) は Summary に含めない")
                }
            }
            // 前年非依存の項目は保持。
            #expect(years[2]["sales"] as? Double != nil)
        }
    }

    /// trim で最古になった年は前年依存フィールドが null 化され、ライブ経路（最古年は前年なし）と一致する。
    /// 前年非依存の項目（sales 等）と、最古でない年の前年依存値は保持される。Waterfall 専用フィールドは
    /// `loadStoredAnalysis` からのみ確認できる（`loadStoredFinancials` は含めない）。
    @Test func loadStoredAnalysisClearsPriorDependentMetricsOnTrimmedOldestYear() async throws {
        try await withMigratedApp { app in
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = try makeResponseWithChanges(code: "7203", years: 6)
            row.cacheVersion = companyFinancialsCacheVersion
            row.requestedYears = 6
            try await row.create(on: app.db)

            let json = try #require(
                try await loadStoredAnalysis(code: "7203", years: 3, db: app.db))
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
    @Test func loadStoredAnalysisKeepsMetricsWhenNotTrimmed() async throws {
        try await withMigratedApp { app in
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = try makeResponseWithChanges(code: "7203", years: 3)
            row.cacheVersion = companyFinancialsCacheVersion
            row.requestedYears = 3
            try await row.create(on: app.db)

            let json = try #require(
                try await loadStoredAnalysis(code: "7203", years: 3, db: app.db))
            let years = try #require(json["years"] as? [[String: Any]])
            #expect(years.count == 3)
            #expect(years[2]["business_profit_change"] as? Double != nil)
        }
    }

    @Test func loadStoredFinancialsDropsDuplicateFyEndYears() async throws {
        try await withMigratedApp { app in
            let dict: [String: Any] = [
                "schema_version": 2, "code": "4376", "name": "くふう",
                "sector": "", "market": "上場", "currency": "JPY", "unit": "百万円",
                "years": [
                    ["fy_end": "2025-09-30", "doc_id": "S100XC6R", "sales": 14110.0],
                    ["fy_end": "2022-09-30", "doc_id": "S100PUYZ", "sales": 18625.0],
                    ["fy_end": "2022-09-30", "doc_id": "S100PYLV", "sales": 18625.0],
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: dict)
            let row = CompanyFinancials()
            row.id = "4376"
            row.response = try JSONDecoder().decode(FinancialsResponse.self, from: data)
            row.cacheVersion = companyFinancialsCacheVersion
            row.requestedYears = 5
            try await row.create(on: app.db)

            let json = try #require(
                try await loadStoredFinancials(code: "4376", years: 5, db: app.db))
            let years = try #require(json["years"] as? [[String: Any]])
            #expect(years.count == 2)
            #expect(years.map { $0["doc_id"] as? String } == ["S100XC6R", "S100PUYZ"])
        }
    }
}
