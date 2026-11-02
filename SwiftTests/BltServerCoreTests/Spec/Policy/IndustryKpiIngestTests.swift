// 業種 KPI 取り込みの対象選定・staleness・upsert・skip。抽出はフェイク。

import BlueTickerCore
import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import Vapor

@testable import BltServerCore
@testable import BltStoreCore
@testable import BltIngestCore

private func withMigratedApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateEdinetDocument())
        app.migrations.add(AddParentDocIDToEdinetDocuments())
        app.migrations.add(CreateIndustryKpiFacts())
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
    _ docID: String, secCode: String, submit: String = "2025-06-20 09:00",
    ordinance: String? = Api.ordinanceCompanyDisclosure, form: String? = "030000",
    db: Database
) async throws {
    let model = EdinetDocument()
    model.id = docID
    model.edinetCode = "E00001"
    model.secCode = secCode
    model.filerName = "テスト銀行"
    model.docTypeCode = Api.docTypeAnnualReport
    model.ordinanceCode = ordinance
    model.formCode = form
    model.submitDateTime = submit
    try await model.create(on: db)
}

private func seedStatement(
    _ docID: String, code: String, balanceSheetTags: [String], db: Database
) async throws {
    let row = CompanyStatement()
    row.id = docID
    row.code = code
    row.submitDateTime = "2026-06-20 09:00"
    row.payload = StatementYear(
        fyEnd: "2026-03-31", financialPeriod: "2026/3", docId: docID,
        balanceSheet: balanceSheetTags.map {
            StatementLineItem(tag: $0, label: nil, value: 1, unit: "JPY", order: nil)
        },
        incomeStatement: [], cashFlow: [])
    row.cacheVersion = statementCacheVersion
    try await row.create(on: db)
}

private func samplePayload() -> IndustryKpiSnapshotPayload {
    IndustryKpiSnapshotPayload(
        industryGroup: industryKpiGroupBank,
        facts: [
            IndustryKpiFactValue(
                kpiKey: industryKpiKeyLDR, value: 82.78,
                unit: AmountUnit.Code.percent.rawValue,
                periodBasis: industryKpiPeriodBasisPeriodEnd,
                scope: industryKpiScopeConsolidated,
                sourceKind: industryKpiSourceKindDerived,
                sourceRef: "loans/(deposits+ncd)")
        ])
}

@Suite struct IndustryKpiIngestTests {
    @Test func ingestStoresResolvedBankSnapshot() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "83310", db: app.db)

            let summary = try await runIndustryKpiIngest(
                db: app.db, listedCodes: ["8331"], years: 3, limit: nil
            ) { _, _ in
                .resolved(
                    payload: samplePayload(), source: industryKpiSourceXbrlFacts,
                    contentHash: "h1")
            }

            #expect(summary.stored == 1)
            #expect(summary.notApplicable == 0)
            let key = IndustryKpiFact.compositeID(
                docID: "S1", industryGroup: industryKpiGroupBank)
            let row = try #require(try await IndustryKpiFact.find(key, on: app.db))
            #expect(row.code == "8331")
            #expect(row.cacheVersion == industryKpiCacheVersion)
            #expect(row.source == industryKpiSourceXbrlFacts)
            #expect(row.payload.fact(key: industryKpiKeyLDR, scope: industryKpiScopeConsolidated)?.value == 82.78)
        }
    }

    @Test func ingestPersistsNotApplicableNonBankAndSkipsOnSecondRun() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let first = try await runIndustryKpiIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .notApplicable(reason: industryKpiNotApplicableNotBank) }

            #expect(first.attempted == 1)
            #expect(first.notApplicable == 1)
            #expect(first.stored == 0)
            let key = IndustryKpiFact.compositeID(
                docID: "S1", industryGroup: industryKpiGroupBank)
            let row = try #require(try await IndustryKpiFact.find(key, on: app.db))
            #expect(row.source == industryKpiSourceNotApplicable)
            #expect(row.notApplicableReason == industryKpiNotApplicableNotBank)
            #expect(row.cacheVersion == industryKpiCacheVersion)
            #expect(row.payload.facts.isEmpty)

            let second = try await runIndustryKpiIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in
                Issue.record("resolver should not run for persisted not_applicable")
                return .failed
            }
            #expect(second.skipped == 1)
            #expect(second.attempted == 0)
        }
    }

    @Test func ingestLimitProgressesPastPersistedNonBanks() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)

            let first = try await runIndustryKpiIngest(
                db: app.db, listedCodes: ["7203", "6758"], years: 3, limit: 1
            ) { _, _ in .notApplicable(reason: industryKpiNotApplicableNotBank) }
            #expect(first.attempted == 1)
            #expect(first.notApplicable == 1)
            let afterFirst = try await IndustryKpiFact.query(on: app.db)
                .filter(\.$industryGroup == industryKpiGroupBank)
                .all()
            #expect(afterFirst.count == 1)

            let second = try await runIndustryKpiIngest(
                db: app.db, listedCodes: ["7203", "6758"], years: 3, limit: 1
            ) { _, _ in .notApplicable(reason: industryKpiNotApplicableNotBank) }
            #expect(second.skipped == 1)
            #expect(second.attempted == 1)
            #expect(second.notApplicable == 1)
            let afterSecond = try await IndustryKpiFact.query(on: app.db)
                .filter(\.$industryGroup == industryKpiGroupBank)
                .all()
            #expect(Set(afterSecond.compactMap(\.docID)) == ["S1", "S2"])
        }
    }

    @Test func ingestSkipsCurrentCacheVersion() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "83310", db: app.db)
            _ = try await runIndustryKpiIngest(
                db: app.db, listedCodes: ["8331"], years: 3, limit: nil
            ) { _, _ in
                .resolved(
                    payload: samplePayload(), source: industryKpiSourceXbrlFacts,
                    contentHash: "h1")
            }

            let summary = try await runIndustryKpiIngest(
                db: app.db, listedCodes: ["8331"], years: 3, limit: nil
            ) { _, _ in
                Issue.record("resolver should not run for fresh row")
                return .failed
            }
            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    @Test func candidateCodesAreBankIndustryOrDepositMarker() async throws {
        try await withMigratedApp { app in
            // 8570: 業種は銀行業以外だが BS に預金マーカーあり → 対象。
            try await seedStatement(
                "S1", code: "8570",
                balanceSheetTags: ["CashAndDueFromBanksAssetsBNK", industryKpiBankDepositMarkerTag],
                db: app.db)
            // 7203: 預金マーカーなし・業種も銀行業以外 → 対象外。
            try await seedStatement(
                "S2", code: "7203", balanceSheetTags: ["TotalAssets"], db: app.db)
            // 9999: 預金マーカーはあるが上場ユニバース外 → 対象外。
            try await seedStatement(
                "S3", code: "9999", balanceSheetTags: [industryKpiBankDepositMarkerTag],
                db: app.db)

            let codes = try await industryKpiBankCandidateCodes(
                db: app.db, listedCodes: ["8570", "7203", "8331", "7182"],
                bankIndustryCodes: ["8331", "7182"])

            // 8331 / 7182 は statements が無くても業種＝銀行業で対象（ゆうちょは預金マーカーを持たない）。
            #expect(codes == ["8570", "8331", "7182"])
        }
    }
}
