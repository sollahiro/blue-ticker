// Stage 6 取り込みの DB ロジック（対象選定・staleness 判定・upsert・limit・purge）と
// read 経路（loadStoredBreakdown）、および servable/unservable 集計を検証する。
// 解決（resolveBusinessBreakdown）は EDINET/LLM 依存のため、フェイク解決器を注入して
// ネットワーク非依存で見る。
//
// Stage 5 との最大の違い（意図的に重点検証する）:
// - xbrl_facts 経由（決定的）の行は cache_version のバージョン不一致で再試行してよい。
// - LLM 経由（source != xbrl_facts）の行は cache_version のバンプだけでは再試行しない
//   （needs_review=true のときのみ）。read の servable 判定も同じ非対称性を持つ
//   （xbrl_facts はバージョン床、LLM 経由は存在すれば常に servable）。

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
        app.migrations.add(CreateCompanySegmentBreakdowns())
        app.migrations.add(RenameCompanySegmentBreakdownsToCompanyBreakdowns())
        app.migrations.add(CreateCompanyFinancials())
        app.migrations.add(CreateCompanyHalfFinancials())
        app.migrations.add(AddHighWaterToCompanyFinancials())
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

private func fakePayload(
    needsReview: Bool = false
) -> BreakdownSnapshotPayload {
    BreakdownSnapshotPayload(
        axis: "business", denominator: 1_000_000, denominatorTag: "income_statement.sales",
        rows: [
            BreakdownRowPayload(
                labelRaw: "セグメントA", amount: 500_000, profit: nil, rowKind: "segment")
        ],
        sourceKind: "test", needsReview: needsReview, warnings: needsReview ? ["test_flag"] : [])
}

private func seedRow(
    _ docID: String, code: String, submit: String, db: Database,
    source: String = breakdownSourceXbrlFacts, cacheVersion: String = breakdownCacheVersion,
    needsReview: Bool = false, contentHash: String = "h0", llmAudit: LLMBreakdownAuditPayload? = nil
) async throws {
    let row = CompanyBreakdown(docID: docID, axis: breakdownAxisBusiness)
    row.code = code
    row.submitDateTime = submit
    row.payload = fakePayload(needsReview: needsReview)
    row.needsReview = needsReview
    row.source = source
    row.contentHash = contentHash
    row.cacheVersion = cacheVersion
    row.llmAudit = llmAudit
    try await row.create(on: db)
}

@Suite struct Stage6IngestTests {

    // MARK: - 対象選定・取り込み

    @Test func ingestStoresResolvedBreakdownsForTargetCompanies() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)

            let summary = try await runStage6Ingest(
                db: app.db, listedCodes: ["7203", "6758"], years: 3, limit: nil
            ) { _, _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
            let key1 = CompanyBreakdown.compositeID(docID: "S1", axis: "business")
            let row = try #require(try await CompanyBreakdown.find(key1, on: app.db))
            #expect(row.code == "7203")
            #expect(row.source == breakdownSourceXbrlFacts)
        }
    }

    @Test func ingestExcludesCompaniesNotInTargetSet() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)  // target
            try await seedDoc("S2", secCode: "99990", db: app.db)  // not in target (日経225外)

            let summary = try await runStage6Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

            #expect(summary.attempted == 1)
            let key2 = CompanyBreakdown.compositeID(docID: "S2", axis: "business")
            #expect(try await CompanyBreakdown.find(key2, on: app.db) == nil)
        }
    }

    @Test func ingestExcludesNonAnnualDocTypes() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)  // 有報120
            try await seedDoc("S2", secCode: "72030", docType: "160", db: app.db)  // 半期

            let summary = try await runStage6Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

            #expect(summary.attempted == 1)
        }
    }

    @Test func ingestDoesNotStoreRowWhenResolverReturnsNotApplicable() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runStage6Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .notApplicable }

            #expect(summary.attempted == 1)
            #expect(summary.notApplicable == 1)
            #expect(summary.stored == 0)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: "business")
            #expect(try await CompanyBreakdown.find(key, on: app.db) == nil)
        }
    }

    @Test func ingestCountsFailuresWithoutStoring() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runStage6Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .failed }

            #expect(summary.attempted == 1)
            #expect(summary.failed == 1)
            #expect(summary.stored == 0)
        }
    }

    @Test func ingestSkipsXbrlFactsRowAlreadyAtCurrentVersion() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow("S1", code: "7203", submit: "2025-06-20 09:00", db: app.db)

            let summary = try await runStage6Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in
                Issue.record("resolver must not run for an up-to-date row")
                return .failed
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    @Test func ingestReattemptsXbrlFactsRowWhenVersionStale() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceXbrlFacts, cacheVersion: "old-version")

            let summary = try await runStage6Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h2", audit: nil) }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: "business")
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.cacheVersion == breakdownCacheVersion)
        }
    }

    /// Stage 5 との最大の差分: LLM 経由の行は cache_version のバンプだけでは再試行しない
    /// （needs_review=false なら据え置き）。
    @Test func ingestDoesNotReattemptLLMRowOnVersionBumpAloneWhenNotFlagged() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceSegmentInfoLLM, cacheVersion: "old-version",
                needsReview: false)

            let summary = try await runStage6Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in
                Issue.record("LLM-sourced row without needs_review must not be re-resolved on version bump")
                return .failed
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    @Test func ingestReattemptsRowFlaggedForReviewRegardlessOfSource() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceSegmentInfoLLM, cacheVersion: breakdownCacheVersion,
                needsReview: true)

            let summary = try await runStage6Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .resolved(payload: fakePayload(needsReview: false), source: breakdownSourceSegmentInfoLLM, contentHash: "h3", audit: nil) }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: "business")
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.needsReview == false)
        }
    }

    @Test func ingestLimitsNewlyAttempted() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)
            try await seedDoc("S3", secCode: "99840", db: app.db)

            let summary = try await runStage6Ingest(
                db: app.db, listedCodes: ["7203", "6758", "9984"], years: 3, limit: 2
            ) { _, _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
        }
    }

    @Test func ingestPurgesExistingRowsBeyondRetentionWindow() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S22", secCode: "72030", submit: "2022-06-20 09:00", db: app.db)
            try await seedDoc("S23", secCode: "72030", submit: "2023-06-20 09:00", db: app.db)
            try await seedDoc("S24", secCode: "72030", submit: "2024-06-20 09:00", db: app.db)
            try await seedDoc("S25", secCode: "72030", submit: "2025-06-20 09:00", db: app.db)
            try await seedRow("S22", code: "7203", submit: "2022-06-20 09:00", db: app.db)

            let summary = try await runStage6Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

            #expect(summary.purged == 1)
            let key22 = CompanyBreakdown.compositeID(docID: "S22", axis: "business")
            #expect(try await CompanyBreakdown.find(key22, on: app.db) == nil)
        }
    }

    @Test func ingestPurgeCountIsZeroWhenNoRowsExistOutsideWindow() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S22", secCode: "72030", submit: "2022-06-20 09:00", db: app.db)
            try await seedDoc("S23", secCode: "72030", submit: "2023-06-20 09:00", db: app.db)

            let summary = try await runStage6Ingest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

            #expect(summary.purged == 0)
        }
    }

    // MARK: - consolidatedSalesForDoc

    @Test func consolidatedSalesForDocReturnsNilWhenNoFinancialsRow() async throws {
        try await withMigratedApp { app in
            let sales = try await consolidatedSalesForDoc(code: "7203", docID: "S1", db: app.db)
            #expect(sales == nil)
        }
    }

    @Test func consolidatedSalesForDocReturnsMatchingYearSalesConvertedToYen() async throws {
        try await withMigratedApp { app in
            let json = """
                {"code":"7203","years":[
                    {"fy_end":"2025-03-31","FinancialPeriod":"通期",
                     "RawData":{"Sales":4624727},"CalculatedData":{"DocID":"S1"}},
                    {"fy_end":"2024-03-31","FinancialPeriod":"通期",
                     "RawData":{"Sales":4000000},"CalculatedData":{"DocID":"S0"}}
                ]}
                """
            let result = try JSONDecoder().decode(MetricsResult.self, from: Data(json.utf8))
            let response = FinancialsResponse(
                code: "7203", name: "テスト", sector: "", market: "", result: result)
            let row = CompanyFinancials()
            row.id = "7203"
            row.response = response
            row.cacheVersion = companyFinancialsCacheVersion
            row.requestedYears = 6
            try await row.create(on: app.db)

            // RawData.Sales は百万円建て（FinancialsResponse.unit）。consolidatedSalesForDoc は
            // Stage 6 正規化器が期待する円単位へ変換して返す。
            let sales = try await consolidatedSalesForDoc(code: "7203", docID: "S1", db: app.db)
            #expect(sales == 4_624_727 * Financial.millionYen)
            let salesOtherYear = try await consolidatedSalesForDoc(code: "7203", docID: "S0", db: app.db)
            #expect(salesOtherYear == 4_000_000 * Financial.millionYen)
            let salesUnknownDoc = try await consolidatedSalesForDoc(code: "7203", docID: "S9", db: app.db)
            #expect(salesUnknownDoc == nil)
        }
    }

    // MARK: - servable/unservable 集計

    @Test func countServableSplitsXbrlFactsRowsByVersionFloor() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceXbrlFacts, cacheVersion: "breakdown-v0")
            try await seedRow(
                "S2", code: "6758", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceXbrlFacts, cacheVersion: "breakdown-v1")

            let coverage = try await countServableBreakdowns(db: app.db)
            #expect(coverage.servable == 1)
            #expect(coverage.unservable == 1)
        }
    }

    /// Stage 5 との最大の差分: LLM 経由の行は cache_version が古くても常に servable。
    @Test func countServableAlwaysCountsLLMRowsRegardlessOfVersion() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceSegmentInfoLLM, cacheVersion: "very-old-version")

            let coverage = try await countServableBreakdowns(db: app.db)
            #expect(coverage.servable == 1)
            #expect(coverage.unservable == 0)
        }
    }

    // MARK: - read 経路

    @Test func loadByCodeReturnsLatestDocument() async throws {
        try await withMigratedApp { app in
            try await seedRow("S24", code: "7203", submit: "2024-06-20 09:00", db: app.db)
            try await seedRow("S25", code: "7203", submit: "2025-06-20 09:00", db: app.db)

            let json = try #require(
                try await loadStoredBreakdown(
                    code: "7203", docId: nil, axis: "business", db: app.db))
            #expect(json["doc_id"] as? String == "S25")
            #expect(json["code"] as? String == "7203")
            #expect(json["axis"] as? String == "business")
            let breakdown = try #require(json["breakdown"] as? [String: Any])
            #expect(breakdown["axis"] as? String == "business")
        }
    }

    @Test func loadByDocIdReturnsThatDocument() async throws {
        try await withMigratedApp { app in
            try await seedRow("S24", code: "7203", submit: "2024-06-20 09:00", db: app.db)
            try await seedRow("S25", code: "7203", submit: "2025-06-20 09:00", db: app.db)

            let json = try #require(
                try await loadStoredBreakdown(
                    code: "7203", docId: "S24", axis: "business", db: app.db))
            #expect(json["doc_id"] as? String == "S24")
        }
    }

    @Test func loadByDocIdRejectsMismatchedCode() async throws {
        try await withMigratedApp { app in
            try await seedRow("S1", code: "7203", submit: "2025-06-20 09:00", db: app.db)
            let json = try await loadStoredBreakdown(
                code: "6758", docId: "S1", axis: "business", db: app.db)
            #expect(json == nil)
        }
    }

    @Test func loadRejectsNonBusinessAxis() async throws {
        try await withMigratedApp { app in
            try await seedRow("S1", code: "7203", submit: "2025-06-20 09:00", db: app.db)
            let json = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: "geography", db: app.db)
            #expect(json == nil)
        }
    }

    @Test func loadReturnsNilWhenXbrlFactsRowBelowFloor() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceXbrlFacts, cacheVersion: "breakdown-v0")
            let json = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: "business", db: app.db)
            #expect(json == nil)
        }
    }

    /// Stage 5 との最大の差分: LLM 経由の行は cache_version が古くても read 可能。
    @Test func loadReturnsLLMRowEvenWithOldCacheVersion() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceSegmentInfoLLM, cacheVersion: "very-old-version")
            let json = try #require(
                try await loadStoredBreakdown(
                    code: "7203", docId: nil, axis: "business", db: app.db))
            #expect(json["doc_id"] as? String == "S1")
        }
    }

    @Test func loadReturnsNilForUnknownCompany() async throws {
        try await withMigratedApp { app in
            let json = try await loadStoredBreakdown(
                code: "0000", docId: nil, axis: "business", db: app.db)
            #expect(json == nil)
        }
    }

    /// xbrl_facts 経由の行には llm_audit が無いため、キー自体を出さない
    /// （REST/MCP応答にnullを混ぜない。既存フィールドとの一貫性）。
    @Test func loadOmitsLlmAuditKeyForXbrlFactsRow() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceXbrlFacts)
            let json = try #require(
                try await loadStoredBreakdown(
                    code: "7203", docId: nil, axis: "business", db: app.db))
            #expect(json["llm_audit"] == nil)
        }
    }

    /// LLM 経由の行は llm_audit を含む（issue #105 のprofit指標区別ギャップ対応。
    /// denominator_tag が "income_statement.sales" 以外のとき、notes から実際の指標名を確認できる）。
    @Test func loadIncludesLlmAuditForLLMRow() async throws {
        try await withMigratedApp { app in
            let audit = LLMBreakdownAuditPayload(
                sourceTableIndex: 0, periodColumn: "2026年３月期", unit: "million_yen",
                profitDisclosed: true,
                notes: "収益合計（金融費用控除後）と税引前当期純利益の行を転置。")
            try await seedRow(
                "S1", code: "8604", submit: "2026-06-22 15:36", db: app.db,
                source: breakdownSourceSegmentInfoLLM, llmAudit: audit)
            let json = try #require(
                try await loadStoredBreakdown(
                    code: "8604", docId: nil, axis: "business", db: app.db))
            let llmAuditJson = try #require(json["llm_audit"] as? [String: Any])
            #expect(llmAuditJson["notes"] as? String == "収益合計（金融費用控除後）と税引前当期純利益の行を転置。")
            #expect(llmAuditJson["profit_disclosed"] as? Bool == true)
            #expect(llmAuditJson["source_table_index"] as? Int == 0)
        }
    }
}
