// buildIngestStatusReport（`blt-server status-report` の DB 集計ロジック）を検証する。
// CLI エントリ（runStatusReportCommand）は Application 起動・stdout 出力のみの薄い I/O 層のため
// 対象外（他 Stage の run*Command 自体を直接テストしないのと同じ方針）。
// ネットワーク・EDINET 非依存（フェイク行を DB へ直接投入して検証する）。

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
        app.migrations.add(CreateCompanyHalfFinancials())
        app.migrations.add(AddHighWaterToCompanyFinancials())
        app.migrations.add(DropCompanyHalfFinancials())
        app.migrations.add(CreateCompanyFilingSections())
        app.migrations.add(CreateCompanySegmentBreakdowns())
        app.migrations.add(RenameCompanySegmentBreakdownsToCompanyBreakdowns())
        app.migrations.add(AddNotApplicableReasonToCompanyBreakdowns())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

/// 有報1件（annual report）を投入する。filing-sections/breakdowns の docsTarget（filingSectionCandidates）算出に必要。
private func seedAnnualReportDoc(
    _ docID: String, secCode: String, submit: String = "2025-06-20 09:00", db: Database
) async throws {
    let model = EdinetDocument()
    model.id = docID
    model.edinetCode = "E00001"
    model.secCode = secCode
    model.filerName = "テスト株式会社"
    model.docTypeCode = Api.docTypeAnnualReport
    model.submitDateTime = submit
    try await model.create(on: db)
}

private func makeFinancialsResponse(code: String) throws -> FinancialsResponse {
    let dict: [String: Any] = [
        "schema_version": 2, "code": code, "name": "テスト",
        "sector": "", "market": "", "currency": "JPY", "unit": "百万円",
        "years": [["fy_end": "2025-03-31"]],
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(FinancialsResponse.self, from: data)
}

private func seedFinancials(
    code: String, version: String, db: Database
) async throws {
    let row = CompanyFinancials()
    row.id = code
    row.response = try makeFinancialsResponse(code: code)
    row.cacheVersion = version
    row.requestedYears = 1
    try await row.create(on: db)
}

private func fakeFilingSectionsPayload() -> FilingSectionsPayload {
    FilingSectionsPayload(
        texts: ["business_risks": "risk"],
        specials: ["segments": ExtractedBreakdownPayload(method: "not_found", tables: [], facts: [])])
}

private func seedFilingSections(
    docID: String, code: String, version: String, db: Database
) async throws {
    let row = CompanyFilingSections()
    row.id = docID
    row.code = code
    row.submitDateTime = "2025-06-20 09:00"
    row.payload = fakeFilingSectionsPayload()
    row.cacheVersion = version
    row.sectionKeys = "business_risks"
    try await row.create(on: db)
}

private func fakeBreakdownPayload() -> BreakdownSnapshotPayload {
    BreakdownSnapshotPayload(
        axis: breakdownAxisBusiness, denominator: 100, denominatorTag: "income_statement.sales",
        rows: [], sourceKind: "table", needsReview: false, warnings: [])
}

private func seedBreakdown(
    docID: String, axis: String, code: String, source: String, version: String, db: Database
) async throws {
    let row = CompanyBreakdown(docID: docID, axis: axis)
    row.code = code
    row.submitDateTime = "2025-06-20 09:00"
    row.payload = fakeBreakdownPayload()
    row.needsReview = false
    row.source = source
    row.contentHash = "hash-\(docID)-\(axis)"
    row.cacheVersion = version
    try await row.create(on: db)
}

@Suite struct StatusReportCommandTests {

    // MARK: - 空DB

    @Test func buildReportMarksStaleWhenNoRowsExist() async throws {
        try await withMigratedApp { app in
            let report = try await buildIngestStatusReport(
                db: app.db, listedCodes: ["7203", "6758"], priorityCodes: ["7203"])

            #expect(report.stages.count == 4)
            for stage in report.stages {
                #expect(stage.companiesCovered == 0)
                #expect(stage.coveragePct == 0.0)
                #expect(stage.currentVersionPct == 0.0)
                #expect(stage.servableCovered == 0)
                #expect(stage.servablePct == 0.0)
                #expect(stage.lastUpdated == nil)
                #expect(stage.stale == true)
            }
        }
    }

    // MARK: - 全件現行版・全対象カバー

    @Test func financialsCoverageAndCurrentVersionPctAreBothFullWhenAllRowsCurrent() async throws {
        try await withMigratedApp { app in
            try await seedFinancials(code: "7203", version: companyFinancialsCacheVersion, db: app.db)
            try await seedFinancials(code: "6758", version: companyFinancialsCacheVersion, db: app.db)

            let report = try await buildIngestStatusReport(
                db: app.db, listedCodes: ["7203", "6758"], priorityCodes: [])
            let financials = try #require(report.stages.first { $0.key == "financials" })

            #expect(financials.companiesCovered == 2)
            #expect(financials.companiesTarget == 2)
            #expect(financials.coveragePct == 100.0)
            #expect(financials.currentVersionPct == 100.0)
            #expect(financials.servableCovered == 2)
            #expect(financials.servablePct == 100.0)
            #expect(financials.docsCovered == nil)
            #expect(financials.docsTarget == nil)
        }
    }

    // MARK: - カバレッジと現行版反映率は独立した軸

    @Test func financialsCurrentVersionPctDropsWhileCoverageStaysFullWithStaleVersionRow() async throws {
        try await withMigratedApp { app in
            try await seedFinancials(code: "7203", version: companyFinancialsCacheVersion, db: app.db)
            try await seedFinancials(code: "6758", version: "fin-v1", db: app.db)  // 旧版

            let report = try await buildIngestStatusReport(
                db: app.db, listedCodes: ["7203", "6758"], priorityCodes: [])
            let financials = try #require(report.stages.first { $0.key == "financials" })

            #expect(financials.coveragePct == 100.0)  // 対象2社とも行はある
            #expect(financials.currentVersionPct == 50.0)  // うち現行版は1社のみ
        }
    }

    // MARK: - filing_sections（doc 単位）

    @Test func filingSectionsCurrentVersionPctReflectsDocLevelStaleness() async throws {
        try await withMigratedApp { app in
            try await seedAnnualReportDoc("S1", secCode: "72030", db: app.db)
            try await seedAnnualReportDoc("S2", secCode: "67580", db: app.db)
            try await seedFilingSections(
                docID: "S1", code: "7203", version: filingSectionsCacheVersion, db: app.db)
            try await seedFilingSections(docID: "S2", code: "6758", version: "sections-v1", db: app.db)

            let report = try await buildIngestStatusReport(
                db: app.db, listedCodes: ["7203", "6758"], priorityCodes: [])
            let sections = try #require(report.stages.first { $0.key == "filing_sections" })

            #expect(sections.companiesCovered == 2)
            #expect(sections.docsCovered == 2)
            #expect(sections.docsTarget == 2)
            #expect(sections.coveragePct == 100.0)
            #expect(sections.currentVersionPct == 50.0)
        }
    }

    // MARK: - breakdown 軸: LLM 経由の行は cache_version でゲートしない

    @Test func breakdownCurrentVersionPctIgnoresLLMSourcedRows() async throws {
        try await withMigratedApp { app in
            try await seedAnnualReportDoc("S1", secCode: "72030", db: app.db)
            try await seedAnnualReportDoc("S2", secCode: "67580", db: app.db)
            // xbrl_facts 経由・旧版 → 現行版ではない（cache_version でゲートされる）。
            try await seedBreakdown(
                docID: "S1", axis: breakdownAxisBusiness, code: "7203",
                source: breakdownSourceXbrlFacts, version: "breakdown-business-v1", db: app.db)
            // segment_info_llm 経由・見た目は古いバージョン文字列だが LLM 経由なので現行扱い。
            try await seedBreakdown(
                docID: "S2", axis: breakdownAxisBusiness, code: "6758",
                source: breakdownSourceSegmentInfoLLM, version: "breakdown-business-v1", db: app.db)

            let report = try await buildIngestStatusReport(
                db: app.db, listedCodes: [], priorityCodes: ["7203", "6758"])
            let business = try #require(report.stages.first { $0.key == "breakdown_business" })

            #expect(business.docsCovered == 2)
            #expect(business.companiesCovered == 2)
            // 現行版扱いは segment_info_llm 側の1件のみ（xbrl_facts の旧版はカウントしない）。
            #expect(business.currentVersionPct == 50.0)
        }
    }

    // MARK: - serviceable(床以上)率は現行版一致率(current_version_pct)とは独立した軸

    @Test func breakdownServablePctStaysHighWhileCurrentVersionPctDropsForOldButFloorMeetingVersion()
        async throws
    {
        try await withMigratedApp { app in
            try await seedAnnualReportDoc("S1", secCode: "72030", db: app.db)
            try await seedAnnualReportDoc("S2", secCode: "67580", db: app.db)
            try await seedBreakdown(
                docID: "S1", axis: breakdownAxisBusiness, code: "7203",
                source: breakdownSourceXbrlFacts, version: businessBreakdownCacheVersion, db: app.db)
            // xbrl_facts 経由・旧版だが床（businessBreakdownMinServableVersion=1）以上 →
            // current_version_pct には数えないが servable_pct には数える。
            try await seedBreakdown(
                docID: "S2", axis: breakdownAxisBusiness, code: "6758",
                source: breakdownSourceXbrlFacts, version: "breakdown-business-v3", db: app.db)

            let report = try await buildIngestStatusReport(
                db: app.db, listedCodes: [], priorityCodes: ["7203", "6758"])
            let business = try #require(report.stages.first { $0.key == "breakdown_business" })

            #expect(business.currentVersionPct == 50.0)  // 現行版(v7)は1件のみ
            #expect(business.servableCovered == 2)  // 床(v1)以上は2件とも該当
            #expect(business.servablePct == 100.0)
        }
    }

    @Test func financialsServablePctDropsWhileCoverageStaysFullForVersionBelowFloor() async throws {
        try await withMigratedApp { app in
            try await seedFinancials(code: "7203", version: companyFinancialsCacheVersion, db: app.db)
            // fin-v1 は companyFinancialsMinServableVersion(=4) 未満 → 配信不可。
            try await seedFinancials(code: "6758", version: "fin-v1", db: app.db)

            let report = try await buildIngestStatusReport(
                db: app.db, listedCodes: ["7203", "6758"], priorityCodes: [])
            let financials = try #require(report.stages.first { $0.key == "financials" })

            #expect(financials.coveragePct == 100.0)  // 行の存在自体は2社ともある
            #expect(financials.servableCovered == 1)  // 実際に配信可能なのは現行版の1社のみ
            #expect(financials.servablePct == 50.0)
        }
    }

    @Test func breakdownDoesNotMixAxes() async throws {
        try await withMigratedApp { app in
            try await seedAnnualReportDoc("S1", secCode: "72030", db: app.db)
            try await seedBreakdown(
                docID: "S1", axis: breakdownAxisBusiness, code: "7203",
                source: breakdownSourceXbrlFacts, version: businessBreakdownCacheVersion, db: app.db)

            let report = try await buildIngestStatusReport(
                db: app.db, listedCodes: [], priorityCodes: ["7203"])
            let business = try #require(report.stages.first { $0.key == "breakdown_business" })
            let geography = try #require(report.stages.first { $0.key == "breakdown_geography" })

            #expect(business.docsCovered == 1)
            #expect(geography.docsCovered == 0)  // geography 軸には行を投入していない
        }
    }

    // MARK: - target 0（listedCodes/priorityCodes 空）→ 0.0（クラッシュしない）

    @Test func percentagesAreZeroNotCrashWhenTargetCodesAreEmpty() async throws {
        try await withMigratedApp { app in
            // データはあるが対象集合が空 → target=0 のため coverage/current とも 0.0。
            try await seedFinancials(code: "7203", version: companyFinancialsCacheVersion, db: app.db)
            try await seedAnnualReportDoc("S1", secCode: "72030", db: app.db)
            try await seedBreakdown(
                docID: "S1", axis: breakdownAxisBusiness, code: "7203",
                source: breakdownSourceXbrlFacts, version: businessBreakdownCacheVersion, db: app.db)

            let report = try await buildIngestStatusReport(
                db: app.db, listedCodes: [], priorityCodes: [])

            for stage in report.stages {
                #expect(stage.companiesTarget == 0)
                #expect(stage.coveragePct == 0.0)
            }
        }
    }

    // MARK: - 対象母集団から外れた残存行（上場廃止等）は分子から除外する（coverage_pct が 100% を超えない）

    @Test func financialsCoveragePctDoesNotExceed100WhenStaleRowOutsideTargetExists() async throws {
        try await withMigratedApp { app in
            // 3社ぶん行があるが、対象母集団（listedCodes）は2社のみ（1社は上場廃止等で対象外になった想定）。
            try await seedFinancials(code: "7203", version: companyFinancialsCacheVersion, db: app.db)
            try await seedFinancials(code: "6758", version: companyFinancialsCacheVersion, db: app.db)
            try await seedFinancials(code: "9999", version: companyFinancialsCacheVersion, db: app.db)

            let report = try await buildIngestStatusReport(
                db: app.db, listedCodes: ["7203", "6758"], priorityCodes: [])
            let financials = try #require(report.stages.first { $0.key == "financials" })

            #expect(financials.companiesTarget == 2)
            #expect(financials.companiesCovered == 2)  // 対象外の "9999" は数えない
            #expect(financials.coveragePct == 100.0)  // 修正前は 150.0 のような超過値になっていた
        }
    }

    @Test func breakdownDocsCoveredExcludesRowsOutsidePriorityCodes() async throws {
        try await withMigratedApp { app in
            try await seedAnnualReportDoc("S1", secCode: "72030", db: app.db)
            try await seedAnnualReportDoc("S2", secCode: "99990", db: app.db)
            // "7203" は対象（priorityCodes）、"9999" は対象外の残存行。
            try await seedBreakdown(
                docID: "S1", axis: breakdownAxisBusiness, code: "7203",
                source: breakdownSourceXbrlFacts, version: businessBreakdownCacheVersion, db: app.db)
            try await seedBreakdown(
                docID: "S2", axis: breakdownAxisBusiness, code: "9999",
                source: breakdownSourceXbrlFacts, version: businessBreakdownCacheVersion, db: app.db)

            let report = try await buildIngestStatusReport(
                db: app.db, listedCodes: [], priorityCodes: ["7203"])
            let business = try #require(report.stages.first { $0.key == "breakdown_business" })

            #expect(business.companiesCovered == 1)
            #expect(business.docsCovered == 1)  // "9999" 由来の行は数えない
        }
    }

    // MARK: - docsTarget 0（優先コード未配置等）→ current_version_pct も 0.0（100%超の暴走値にならない）

    @Test func breakdownCurrentVersionPctIsZeroNotOverflowingWhenDocsTargetIsZero() async throws {
        try await withMigratedApp { app in
            // priorityCodes は空だが、既存行はある（優先コード一覧が未配置・空のケースを模す）。
            // filingSectionCandidates の対象コードが空なので docsTarget は 0 になる。
            try await seedBreakdown(
                docID: "S1", axis: breakdownAxisBusiness, code: "7203",
                source: breakdownSourceXbrlFacts, version: businessBreakdownCacheVersion, db: app.db)

            let report = try await buildIngestStatusReport(
                db: app.db, listedCodes: [], priorityCodes: [])
            let business = try #require(report.stages.first { $0.key == "breakdown_business" })

            #expect(business.docsTarget == 0)
            #expect(business.currentVersionPct == 0.0)  // 修正前は 30800.0 のような暴走値になっていた
        }
    }

    // MARK: - staleness

    @Test func stageIsNotStaleWhenUpdatedWithinFreshnessWindow() async throws {
        try await withMigratedApp { app in
            try await seedFinancials(code: "7203", version: companyFinancialsCacheVersion, db: app.db)

            let report = try await buildIngestStatusReport(
                db: app.db, listedCodes: ["7203"], priorityCodes: [], now: Date())
            let financials = try #require(report.stages.first { $0.key == "financials" })

            #expect(financials.stale == false)
            #expect(financials.lastUpdated != nil)
        }
    }

    @Test func stageIsStaleWhenLastUpdatedExceedsFreshnessWindow() async throws {
        try await withMigratedApp { app in
            try await seedFinancials(code: "7203", version: companyFinancialsCacheVersion, db: app.db)

            let farFuture = Date().addingTimeInterval(
                (Api.ingestFreshnessMaxAgeHours + 1) * 3600)
            let report = try await buildIngestStatusReport(
                db: app.db, listedCodes: ["7203"], priorityCodes: [], now: farFuture)
            let financials = try #require(report.stages.first { $0.key == "financials" })

            #expect(financials.stale == true)
        }
    }
}
