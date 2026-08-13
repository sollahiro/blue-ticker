// Statement 取り込みの DB ロジック（対象選定＝ filingSectionCandidates 再利用・staleness 判定・upsert・limit・
// purge）と read 経路（loadStoredStatement の code 直近N件／doc_id 指定・バージョンゲート）を検証する。
// 抽出（extractStatement）は EDINET 依存のため、フェイク抽出器を注入してネットワーク非依存で見る。
//
// 内訳取り込み と異なり決定論のみ（LLM 不要）のため、staleness 判定は 有報セクション取り込み と同型（cache_version
// 不一致のみで再試行。needs_review/source の非対称性は無い）。

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
        app.migrations.add(CreateCompanyStatements())
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

private func fakeYear(_ marker: String = "資産合計", docID: String = "S1") -> StatementYear {
    StatementYear(
        fyEnd: "2025-03-31", financialPeriod: "通期", docId: docID,
        balanceSheet: [
            StatementLineItem(tag: "TotalAssets", label: marker, value: 1_000, unit: "JPY", order: nil)
        ],
        incomeStatement: [], cashFlow: [])
}

@Suite struct StatementIngestTests {

    // MARK: - 対象選定・取り込み

    @Test func ingestStoresStatementsForListedAnnualReports() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)

            let summary = try await runStatementIngest(
                db: app.db, listedCodes: ["7203", "6758"], years: 3, limit: nil
            ) { docID in .resolved(fakeYear(docID: docID)) }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
            let row = try #require(try await CompanyStatement.find("S1", on: app.db))
            #expect(row.code == "7203")
            #expect(row.cacheVersion == statementCacheVersion)
        }
    }

    @Test func ingestExcludesCompaniesNotInTargetSet() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)  // target
            try await seedDoc("S2", secCode: "99990", db: app.db)  // not in target (日経225外)

            let summary = try await runStatementIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { docID in .resolved(fakeYear(docID: docID)) }

            #expect(summary.attempted == 1)
            #expect(try await CompanyStatement.find("S2", on: app.db) == nil)
        }
    }

    @Test func ingestExcludesNonAnnualDocTypes() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)  // 有報120
            try await seedDoc("S2", secCode: "72030", docType: "160", db: app.db)  // 半期

            let summary = try await runStatementIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { docID in .resolved(fakeYear(docID: docID)) }

            #expect(summary.attempted == 1)
        }
    }

    @Test func ingestKeepsOnlyRecentNAnnualReportsPerCompany() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S22", secCode: "72030", submit: "2022-06-20 09:00", db: app.db)
            try await seedDoc("S23", secCode: "72030", submit: "2023-06-20 09:00", db: app.db)
            try await seedDoc("S24", secCode: "72030", submit: "2024-06-20 09:00", db: app.db)
            try await seedDoc("S25", secCode: "72030", submit: "2025-06-20 09:00", db: app.db)

            let summary = try await runStatementIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { docID in .resolved(fakeYear(docID: docID)) }

            #expect(summary.attempted == 3)
            #expect(summary.stored == 3)
            #expect(try await CompanyStatement.find("S25", on: app.db) != nil)
            #expect(try await CompanyStatement.find("S22", on: app.db) == nil)  // 4件目は対象外
        }
    }

    @Test func ingestPurgesExistingRowsBeyondRetentionWindow() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S22", secCode: "72030", submit: "2022-06-20 09:00", db: app.db)
            try await seedDoc("S23", secCode: "72030", submit: "2023-06-20 09:00", db: app.db)
            try await seedDoc("S24", secCode: "72030", submit: "2024-06-20 09:00", db: app.db)
            try await seedDoc("S25", secCode: "72030", submit: "2025-06-20 09:00", db: app.db)
            let old = CompanyStatement()
            old.id = "S22"
            old.code = "7203"
            old.submitDateTime = "2022-06-20 09:00"
            old.payload = fakeYear("old", docID: "S22")
            old.cacheVersion = statementCacheVersion
            try await old.create(on: app.db)

            let summary = try await runStatementIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { docID in .resolved(fakeYear(docID: docID)) }

            #expect(summary.purged == 1)
            #expect(try await CompanyStatement.find("S22", on: app.db) == nil)
        }
    }

    @Test func ingestSkipsWhenStoredAtCurrentVersion() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let pre = CompanyStatement()
            pre.id = "S1"
            pre.code = "7203"
            pre.submitDateTime = "2025-06-20 09:00"
            pre.payload = fakeYear("old", docID: "S1")
            pre.cacheVersion = statementCacheVersion
            try await pre.create(on: app.db)

            let summary = try await runStatementIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _ in
                Issue.record("extractor must not run for an up-to-date document")
                return .resolved(fakeYear())
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    @Test func ingestReextractsWhenVersionMismatches() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let stale = CompanyStatement()
            stale.id = "S1"
            stale.code = "7203"
            stale.submitDateTime = "2025-06-20 09:00"
            stale.payload = fakeYear("stale", docID: "S1")
            stale.cacheVersion = "old-version"
            try await stale.create(on: app.db)

            let summary = try await runStatementIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { docID in .resolved(fakeYear("fresh", docID: docID)) }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let row = try #require(try await CompanyStatement.find("S1", on: app.db))
            #expect(row.cacheVersion == statementCacheVersion)
            #expect(row.payload.balanceSheet.first?.label == "fresh")
        }
    }

    @Test func ingestLimitsNewlyAttempted() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)
            try await seedDoc("S3", secCode: "99840", db: app.db)

            let summary = try await runStatementIngest(
                db: app.db, listedCodes: ["7203", "6758", "9984"], years: 3, limit: 2
            ) { docID in .resolved(fakeYear(docID: docID)) }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
        }
    }

    @Test func ingestPrefersCachedDocWhenLimitCutsOff() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", submit: "2025-06-20 09:00", db: app.db)
            try await seedDoc("S2", secCode: "67580", submit: "2024-06-20 09:00", db: app.db)

            let summary = try await runStatementIngest(
                db: app.db, listedCodes: ["7203", "6758"], years: 3, limit: 1,
                cachedDocIDs: ["S2"]
            ) { docID in .resolved(fakeYear(docID: docID)) }

            #expect(summary.attempted == 1)
            #expect(try await CompanyStatement.find("S2", on: app.db) != nil)
            #expect(try await CompanyStatement.find("S1", on: app.db) == nil)
        }
    }

    @Test func ingestCountsFailuresWithoutStoring() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runStatementIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _ in .failed }

            #expect(summary.attempted == 1)
            #expect(summary.failed == 1)
            #expect(summary.stored == 0)
            #expect(try await CompanyStatement.query(on: app.db).count() == 0)
        }
    }

    @Test func ingestStoresNotApplicablePlaceholderAndReadOmitsIt() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "49010", db: app.db)

            let summary = try await runStatementIngest(
                db: app.db, listedCodes: ["4901"], years: 3, limit: nil
            ) { _ in .notApplicable(reason: statementNotApplicableUSGAAP) }

            #expect(summary.attempted == 1)
            #expect(summary.notApplicable == 1)
            #expect(summary.stored == 0)
            let row = try #require(try await CompanyStatement.find("S1", on: app.db))
            #expect(isStatementNotApplicablePlaceholder(row.payload))
            #expect(try await loadStoredStatement(code: "4901", docId: nil, years: 3, db: app.db) == nil)
            #expect(try await loadStoredStatement(code: "4901", docId: "S1", years: 3, db: app.db) == nil)
        }
    }

    // MARK: - servable/unservable 集計

    private func seedStored(
        _ docID: String, code: String, submit: String, db: Database,
        version: String = statementCacheVersion, payload: StatementYear? = nil
    ) async throws {
        let row = CompanyStatement()
        row.id = docID
        row.code = code
        row.submitDateTime = submit
        row.payload = payload ?? fakeYear(docID: docID)
        row.cacheVersion = version
        try await row.create(on: db)
    }

    @Test func countServableStatementsSplitsByReadFloor() async throws {
        try await withMigratedApp { app in
            try await seedStored("S1", code: "7203", submit: "2025-06-20 09:00", db: app.db, version: "statement-v0")
            try await seedStored("S2", code: "6758", submit: "2025-06-20 09:00", db: app.db, version: "statement-v1")

            let coverage = try await countServableStatements(db: app.db)
            #expect(coverage.servable == 1)
            #expect(coverage.unservable == 1)
        }
    }

    // MARK: - read 経路

    @Test func loadByDocIdReturnsThatDocument() async throws {
        try await withMigratedApp { app in
            try await seedStored("S24", code: "7203", submit: "2024-06-20 09:00", db: app.db)
            try await seedStored("S25", code: "7203", submit: "2025-06-20 09:00", db: app.db)

            let json = try #require(
                try await loadStoredStatement(code: "7203", docId: "S24", years: 5, db: app.db))
            #expect(json["code"] as? String == "7203")
            let years = try #require(json["years"] as? [[String: Any]])
            #expect(years.count == 1)
            #expect(years[0]["doc_id"] as? String == "S24")
        }
    }

    @Test func loadByDocIdRejectsMismatchedCode() async throws {
        try await withMigratedApp { app in
            try await seedStored("S1", code: "7203", submit: "2025-06-20 09:00", db: app.db)
            let json = try await loadStoredStatement(code: "6758", docId: "S1", years: 5, db: app.db)
            #expect(json == nil)
        }
    }

    @Test func loadWithoutDocIdReturnsUpToRequestedYearsNewestFirst() async throws {
        try await withMigratedApp { app in
            try await seedStored("S23", code: "7203", submit: "2023-06-20 09:00", db: app.db)
            try await seedStored("S24", code: "7203", submit: "2024-06-20 09:00", db: app.db)
            try await seedStored("S25", code: "7203", submit: "2025-06-20 09:00", db: app.db)

            let json = try #require(
                try await loadStoredStatement(code: "7203", docId: nil, years: 2, db: app.db))
            let years = try #require(json["years"] as? [[String: Any]])
            #expect(years.count == 2)
            #expect(years[0]["doc_id"] as? String == "S25")
            #expect(years[1]["doc_id"] as? String == "S24")
        }
    }

    @Test func loadReturnsNilWhenVersionBelowFloor() async throws {
        try await withMigratedApp { app in
            try await seedStored("S1", code: "7203", submit: "2025-06-20 09:00", db: app.db, version: "old")
            let json = try await loadStoredStatement(code: "7203", docId: nil, years: 5, db: app.db)
            #expect(json == nil)
        }
    }

    @Test func loadExcludesBelowFloorRowsFromMultiYearResult() async throws {
        try await withMigratedApp { app in
            try await seedStored(
                "S-ok", code: "7203", submit: "2024-06-20 09:00", db: app.db, version: "statement-v1")
            try await seedStored(
                "S-bad", code: "7203", submit: "2025-06-20 09:00", db: app.db, version: "old")

            let json = try #require(
                try await loadStoredStatement(code: "7203", docId: nil, years: 5, db: app.db))
            let years = try #require(json["years"] as? [[String: Any]])
            #expect(years.count == 1)
            #expect(years[0]["doc_id"] as? String == "S-ok")
        }
    }

    @Test func loadReturnsNilForUnknownCompany() async throws {
        try await withMigratedApp { app in
            let json = try await loadStoredStatement(code: "0000", docId: nil, years: 5, db: app.db)
            #expect(json == nil)
        }
    }

    @Test func loadReturnsNilForNonPositiveYears() async throws {
        try await withMigratedApp { app in
            try await seedStored("S1", code: "7203", submit: "2025-06-20 09:00", db: app.db)
            let json = try await loadStoredStatement(code: "7203", docId: nil, years: 0, db: app.db)
            #expect(json == nil)
        }
    }

    @Test func loadJsonIncludesBalanceSheetLineItems() async throws {
        try await withMigratedApp { app in
            try await seedStored("S1", code: "7203", submit: "2025-06-20 09:00", db: app.db)
            let json = try #require(
                try await loadStoredStatement(code: "7203", docId: nil, years: 5, db: app.db))
            let years = try #require(json["years"] as? [[String: Any]])
            let bs = try #require(years[0]["balance_sheet"] as? [[String: Any]])
            #expect(bs.first?["tag"] as? String == "TotalAssets")
            #expect(bs.first?["order"] is NSNull)
        }
    }
}
