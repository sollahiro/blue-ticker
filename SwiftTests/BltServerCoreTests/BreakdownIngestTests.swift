// 内訳取り込みの DB ロジック（対象選定・staleness 判定・upsert・limit・purge）と
// read 経路（loadStoredBreakdown）、および servable/unservable 集計を検証する。
// 解決（resolveBusinessBreakdown）は EDINET/LLM 依存のため、フェイク解決器を注入して
// ネットワーク非依存で見る。
//
// 有報セクション取り込み との最大の違い（意図的に重点検証する）:
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
        app.migrations.add(AddNotApplicableReasonToCompanyBreakdowns())
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

    // 内訳取り込み は分母売上（財務取り込み）が無いと解決に進まない（missing sales → skip / not_found）。
    // 有報候補の seed には対応する financials 行も添える。
    if let secCode, docType == nil || docType == Api.docTypeAnnualReport {
        try await seedSalesForDoc(code: String(secCode.prefix(4)), docID: docID, db: db)
    }
}

/// 内訳取り込み テスト用: docID に紐づく売上を company_financials へ足す（同一 code は追記）。
private func seedSalesForDoc(
    code: String, docID: String, salesMillionYen: Double = 1_000_000, db: Database
) async throws {
    let yearJSON = """
        {"fy_end":"2025-03-31","FinancialPeriod":"通期",
         "RawData":{"Sales":\(Int(salesMillionYen))},"CalculatedData":{"DocID":"\(docID)"}}
        """
    let newYear = try JSONDecoder().decode(YearEntry.self, from: Data(yearJSON.utf8))

    if let existing = try await CompanyFinancials.find(code, on: db) {
        var result = existing.response.toMetricsResult()
        var years = result.years ?? []
        years.removeAll { $0.calculatedData.docID == docID }
        years.append(newYear)
        result.years = years
        existing.response = FinancialsResponse(
            code: code, name: existing.response.name, sector: existing.response.sector,
            market: existing.response.market, result: result)
        try await existing.update(on: db)
        return
    }

    var result = MetricsResult.blank
    result.code = code
    result.years = [newYear]
    let response = FinancialsResponse(
        code: code, name: "テスト", sector: "", market: "", result: result)
    let row = CompanyFinancials()
    row.id = code
    row.response = response
    row.cacheVersion = companyFinancialsCacheVersion
    row.requestedYears = 6
    try await row.create(on: db)
}

private func fakePayload(
    axis: String = "business", needsReview: Bool = false
) -> BreakdownSnapshotPayload {
    BreakdownSnapshotPayload(
        axis: axis, denominator: 1_000_000, denominatorTag: "income_statement.sales",
        rows: [
            BreakdownRowPayload(
                labelRaw: "セグメントA", amount: 500_000, profit: nil, rowKind: "segment")
        ],
        sourceKind: "test", needsReview: needsReview, warnings: needsReview ? ["test_flag"] : [])
}

private func seedRow(
    _ docID: String, code: String, submit: String, db: Database,
    axis: String = breakdownAxisBusiness,
    source: String = breakdownSourceXbrlFacts, cacheVersion: String = businessBreakdownCacheVersion,
    needsReview: Bool = false, contentHash: String = "h0", llmAudit: LLMBreakdownAuditPayload? = nil,
    notApplicableReason: String? = nil
) async throws {
    let row = CompanyBreakdown(docID: docID, axis: axis)
    row.code = code
    row.submitDateTime = submit
    row.payload = fakePayload(axis: axis, needsReview: needsReview)
    row.needsReview = needsReview
    row.source = source
    row.contentHash = contentHash
    row.cacheVersion = cacheVersion
    row.llmAudit = llmAudit
    row.notApplicableReason = notApplicableReason
    try await row.create(on: db)
}

/// テスト用の `BreakdownLoadResult` 抽出ヘルパー（issue #132 で戻り値を3値化したため）。
extension BreakdownLoadResult {
    fileprivate var foundJSON: [String: Any]? {
        if case .found(let json) = self { return json }
        return nil
    }
    fileprivate var notApplicableReason: String? {
        if case .notApplicable(let reason) = self { return reason }
        return nil
    }
    fileprivate var isAbsent: Bool {
        if case .absent = self { return true }
        return false
    }
}

@Suite struct BreakdownIngestTests {

    // MARK: - 対象選定・取り込み

    @Test func ingestStoresResolvedBreakdownsForTargetCompanies() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)

            let summary = try await runBreakdownIngest(
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

            let summary = try await runBreakdownIngest(
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

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

            #expect(summary.attempted == 1)
        }
    }

    /// issue #132: notApplicable もプレースホルダ行として永続化される（`.notFound` の
    /// 「行を作らない」方針とは別。理由を REST/MCP へ返すために必要）。
    @Test func ingestStoresNotApplicablePlaceholderWithReason() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .notApplicable(reason: breakdownNotApplicableGeographyOnly) }

            #expect(summary.attempted == 1)
            #expect(summary.notApplicable == 1)
            #expect(summary.stored == 0)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: "business")
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.source == breakdownSourceNotApplicable)
            #expect(row.notApplicableReason == breakdownNotApplicableGeographyOnly)
            // E/F は確信度の高い決定的判定のため needsReview=false。
            #expect(row.needsReview == false)
        }
    }

    /// unknown は要調査のため needsReview=true で保存し、通常巡回や `--codes` 指名 ingest で
    /// 再分類できるようにする（ユーザー要望: 「unknownは開発側でレビューして指名ingestなど」）。
    @Test func ingestFlagsUnknownNotApplicableReasonForReview() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            _ = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .notApplicable(reason: breakdownNotApplicableUnknown) }

            let key = CompanyBreakdown.compositeID(docID: "S1", axis: "business")
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.needsReview == true)
        }
    }

    /// Opus監査で指摘（issue #132）: 既存の実データ行（LLM経由でneeds_review=trueの再試行対象等）が
    /// 一時的な解決失敗（LLM停止・Financials未計算等）でnotApplicableへ「格下げ」されると、正しいデータを
    /// 破壊してしまう。既存が実データを持つ場合は上書きせず、次回また再試行対象として残すべき。
    @Test func ingestDoesNotOverwriteExistingRealDataWithNotApplicablePlaceholder() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let audit = LLMBreakdownAuditPayload(
                sourceTableIndex: 0, periodColumn: "当期", unit: "million_yen",
                profitDisclosed: true, notes: "test")
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceSegmentInfoLLM, cacheVersion: businessBreakdownCacheVersion,
                needsReview: true, contentHash: "real-hash", llmAudit: audit)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .notApplicable(reason: breakdownNotApplicableUnknown) }

            #expect(summary.attempted == 1)
            #expect(summary.notApplicable == 1)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: "business")
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            // 実データ（LLM経由）が保持されたままであること。
            #expect(row.source == breakdownSourceSegmentInfoLLM)
            #expect(row.notApplicableReason == nil)
            #expect(row.payload.rows.count == 1)
            #expect(row.needsReview == true)
        }
    }

    /// 実データ（`.resolved`）で再解決された行は、以前 notApplicable プレースホルダだった場合でも
    /// `notApplicableReason` が nil へ戻ること（`applyFields` が毎回無条件で設定するため desync しない）。
    @Test func ingestClearsNotApplicableReasonWhenLaterResolved() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceNotApplicable, cacheVersion: "old-version",
                notApplicableReason: breakdownNotApplicableGeographyOnly)

            _ = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h9", audit: nil) }

            let key = CompanyBreakdown.compositeID(docID: "S1", axis: "business")
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.source == breakdownSourceXbrlFacts)
            #expect(row.notApplicableReason == nil)
        }
    }

    /// not_applicable source は xbrl_facts と同様、cache_version バンプで再試行してよい
    /// （分類ロジック改善を拾うため）。
    @Test func ingestReattemptsNotApplicableRowWhenVersionStale() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceNotApplicable, cacheVersion: "old-version",
                notApplicableReason: breakdownNotApplicableGeographyOnly)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h2", audit: nil) }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
        }
    }

    @Test func ingestSkipsNotApplicableRowAlreadyAtCurrentVersion() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceNotApplicable, cacheVersion: businessBreakdownCacheVersion,
                notApplicableReason: breakdownNotApplicableSingleSegmentDisclosed)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in
                Issue.record("resolver must not run for an up-to-date not_applicable row")
                return .failed
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    /// issue #130（E/F判定の検知結果明示化）: notApplicable の理由別内訳が正しく集計されること。
    @Test func ingestClassifiesNotApplicableReasonsSeparately() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)  // geography
            try await seedDoc("S2", secCode: "67580", db: app.db)  // single segment
            try await seedDoc("S3", secCode: "99840", db: app.db)  // unknown

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203", "6758", "9984"], years: 3, limit: nil
            ) { docID, _ in
                switch docID {
                case "S1": return .notApplicable(reason: breakdownNotApplicableGeographyOnly)
                case "S2": return .notApplicable(reason: breakdownNotApplicableSingleSegmentDisclosed)
                default: return .notApplicable(reason: breakdownNotApplicableUnknown)
                }
            }

            #expect(summary.notApplicable == 3)
            #expect(summary.notApplicableGeographyOnly == 1)
            #expect(summary.notApplicableSingleSegmentDisclosed == 1)
            #expect(summary.notApplicableUnknown == 1)
        }
    }

    @Test func ingestCountsFailuresWithoutStoring() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runBreakdownIngest(
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

            let summary = try await runBreakdownIngest(
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

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _, _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h2", audit: nil) }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: "business")
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.cacheVersion == businessBreakdownCacheVersion)
        }
    }

    /// 有報セクション取り込み との最大の差分: LLM 経由の行は cache_version のバンプだけでは再試行しない
    /// （needs_review=false なら据え置き）。
    @Test func ingestDoesNotReattemptLLMRowOnVersionBumpAloneWhenNotFlagged() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceSegmentInfoLLM, cacheVersion: "old-version",
                needsReview: false)

            let summary = try await runBreakdownIngest(
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
                source: breakdownSourceSegmentInfoLLM, cacheVersion: businessBreakdownCacheVersion,
                needsReview: true)

            let summary = try await runBreakdownIngest(
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

            let summary = try await runBreakdownIngest(
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

            let summary = try await runBreakdownIngest(
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

            let summary = try await runBreakdownIngest(
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
            // 内訳取り込み 正規化器が期待する円単位へ変換して返す。
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

    /// 有報セクション取り込み との最大の差分: LLM 経由の行は cache_version が古くても常に servable。
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

            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: "business", db: app.db)
            let json = try #require(result.foundJSON)
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

            let result = try await loadStoredBreakdown(
                code: "7203", docId: "S24", axis: "business", db: app.db)
            let json = try #require(result.foundJSON)
            #expect(json["doc_id"] as? String == "S24")
        }
    }

    @Test func loadByDocIdRejectsMismatchedCode() async throws {
        try await withMigratedApp { app in
            try await seedRow("S1", code: "7203", submit: "2025-06-20 09:00", db: app.db)
            let result = try await loadStoredBreakdown(
                code: "6758", docId: "S1", axis: "business", db: app.db)
            #expect(result.isAbsent)
        }
    }

    /// business / geography 以外の軸は行の有無に関わらず absent（将来 axis 追加時の安全側デフォルト）。
    @Test func loadRejectsUnknownAxis() async throws {
        try await withMigratedApp { app in
            try await seedRow("S1", code: "7203", submit: "2025-06-20 09:00", db: app.db)
            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: "product", db: app.db)
            #expect(result.isAbsent)
        }
    }

    /// geography も business と同じく格納済み行を読める（2026-07-27 品質ゲート通過後に解禁）。
    @Test func loadReturnsGeographyRowWhenPresent() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                axis: breakdownAxisGeography, source: breakdownSourceGeographyLLM,
                cacheVersion: geographyBreakdownCacheVersion)

            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: breakdownAxisGeography, db: app.db)
            let json = try #require(result.foundJSON)
            #expect(json["doc_id"] as? String == "S1")
            #expect(json["axis"] as? String == breakdownAxisGeography)
            let breakdown = try #require(json["breakdown"] as? [String: Any])
            #expect(breakdown["axis"] as? String == breakdownAxisGeography)
        }
    }

    /// geography の notApplicable（例: not_found）行も business と同型で reason を返す。
    @Test func loadReturnsGeographyNotApplicableReason() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                axis: breakdownAxisGeography, source: breakdownSourceNotApplicable,
                cacheVersion: geographyBreakdownCacheVersion,
                notApplicableReason: breakdownNotApplicableNotFound)

            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: breakdownAxisGeography, db: app.db)
            #expect(result.notApplicableReason == breakdownNotApplicableNotFound)
            #expect(result.foundJSON == nil)
        }
    }

    @Test func loadReturnsNilWhenXbrlFactsRowBelowFloor() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceXbrlFacts, cacheVersion: "breakdown-v0")
            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: "business", db: app.db)
            #expect(result.isAbsent)
        }
    }

    /// 有報セクション取り込み との最大の差分: LLM 経由の行は cache_version が古くても read 可能。
    @Test func loadReturnsLLMRowEvenWithOldCacheVersion() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceSegmentInfoLLM, cacheVersion: "very-old-version")
            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: "business", db: app.db)
            let json = try #require(result.foundJSON)
            #expect(json["doc_id"] as? String == "S1")
        }
    }

    @Test func loadReturnsNilForUnknownCompany() async throws {
        try await withMigratedApp { app in
            let result = try await loadStoredBreakdown(
                code: "0000", docId: nil, axis: "business", db: app.db)
            #expect(result.isAbsent)
        }
    }

    /// xbrl_facts 経由の行には llm_audit が無いため、キー自体を出さない
    /// （REST/MCP応答にnullを混ぜない。既存フィールドとの一貫性）。
    @Test func loadOmitsLlmAuditKeyForXbrlFactsRow() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceXbrlFacts)
            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: "business", db: app.db)
            let json = try #require(result.foundJSON)
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
            let result = try await loadStoredBreakdown(
                code: "8604", docId: nil, axis: "business", db: app.db)
            let json = try #require(result.foundJSON)
            let llmAuditJson = try #require(json["llm_audit"] as? [String: Any])
            #expect(llmAuditJson["notes"] as? String == "収益合計（金融費用控除後）と税引前当期純利益の行を転置。")
            #expect(llmAuditJson["profit_disclosed"] as? Bool == true)
            #expect(llmAuditJson["source_table_index"] as? Int == 0)
        }
    }

    // MARK: - read 経路（notApplicable、issue #132）

    /// notApplicable プレースホルダ行は breakdown データではなく reason を返す。
    @Test func loadReturnsNotApplicableReasonForPlaceholderRow() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceNotApplicable, cacheVersion: businessBreakdownCacheVersion,
                notApplicableReason: breakdownNotApplicableGeographyOnly)

            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: "business", db: app.db)
            #expect(result.notApplicableReason == breakdownNotApplicableGeographyOnly)
            #expect(result.foundJSON == nil)
        }
    }

    /// not_applicable source も xbrl_facts と同じバージョン床を受ける
    /// （分類ロジックが変わった後の古い reason を誤って返さないため）。
    @Test func loadTreatsStaleNotApplicableRowAsAbsent() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceNotApplicable, cacheVersion: "breakdown-v0",
                notApplicableReason: breakdownNotApplicableUnknown)

            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: "business", db: app.db)
            #expect(result.isAbsent)
        }
    }

    /// 最新書類が notApplicable の場合、より古い書類に実データがあってもそれは返さない
    /// （最新の状態を正しく反映する。Financials の notApplicablePlaceholder と同じ設計判断）。
    @Test func loadPrefersLatestNotApplicableOverOlderRealData() async throws {
        try await withMigratedApp { app in
            try await seedRow("S24", code: "7203", submit: "2024-06-20 09:00", db: app.db)
            try await seedRow(
                "S25", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceNotApplicable, cacheVersion: businessBreakdownCacheVersion,
                notApplicableReason: breakdownNotApplicableSingleSegmentDisclosed)

            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: "business", db: app.db)
            #expect(result.notApplicableReason == breakdownNotApplicableSingleSegmentDisclosed)
        }
    }

    // MARK: - servable/unservable 集計（not_applicable source）

    /// not_applicable source も xbrl_facts と同じくバージョン床で servable/unservable が分かれる。
    @Test func countServableSplitsNotApplicableRowsByVersionFloorLikeXbrlFacts() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceNotApplicable, cacheVersion: "breakdown-v0",
                notApplicableReason: breakdownNotApplicableUnknown)
            try await seedRow(
                "S2", code: "6758", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceNotApplicable, cacheVersion: "breakdown-v1",
                notApplicableReason: breakdownNotApplicableGeographyOnly)

            let coverage = try await countServableBreakdowns(db: app.db)
            #expect(coverage.servable == 1)
            #expect(coverage.unservable == 1)
        }
    }

    // MARK: - geography 軸

    @Test func geographyIngestStoresResolvedRowsUnderGeographyAxis() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                axis: breakdownAxisGeography
            ) { _, _ in
                .resolved(
                    payload: fakePayload(axis: breakdownAxisGeography),
                    source: breakdownSourceGeographyLLM, contentHash: "hg1", audit: nil)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let geoKey = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisGeography)
            let bizKey = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisBusiness)
            let row = try #require(try await CompanyBreakdown.find(geoKey, on: app.db))
            #expect(row.source == breakdownSourceGeographyLLM)
            #expect(row.payload.axis == breakdownAxisGeography)
            #expect(row.cacheVersion == geographyBreakdownCacheVersion)
            #expect(try await CompanyBreakdown.find(bizKey, on: app.db) == nil)
        }
    }

    @Test func geographyNotFoundWritesDeterministicPlaceholderWithoutReview() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                axis: breakdownAxisGeography
            ) { _, _ in .notApplicable(reason: breakdownNotApplicableNotFound) }

            #expect(summary.notApplicable == 1)
            #expect(summary.notApplicableUnknown == 0)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisGeography)
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.source == breakdownSourceNotApplicable)
            #expect(row.notApplicableReason == breakdownNotApplicableNotFound)
            #expect(row.needsReview == false)
            #expect(row.cacheVersion == geographyBreakdownCacheVersion)
        }
    }

    @Test func geographyUnknownFailureWritesNeedsReviewPlaceholder() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                axis: breakdownAxisGeography
            ) { _, _ in .notApplicable(reason: breakdownNotApplicableUnknown) }

            #expect(summary.notApplicableUnknown == 1)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisGeography)
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.needsReview == true)
        }
    }

    @Test func geographyPurgeDeletesOnlyGeographyAxisRows() async throws {
        try await withMigratedApp { app in
            // years=1 のため直近1件以外は purge 対象。
            try await seedDoc("S24", secCode: "72030", submit: "2024-06-20 09:00", db: app.db)
            try await seedDoc("S25", secCode: "72030", submit: "2025-06-20 09:00", db: app.db)
            try await seedRow(
                "S24", code: "7203", submit: "2024-06-20 09:00", db: app.db,
                axis: breakdownAxisGeography, source: breakdownSourceGeographyLLM)
            try await seedRow(
                "S24", code: "7203", submit: "2024-06-20 09:00", db: app.db,
                axis: breakdownAxisBusiness, source: breakdownSourceXbrlFacts)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 1, limit: nil,
                axis: breakdownAxisGeography
            ) { _, _ in
                .resolved(
                    payload: fakePayload(axis: breakdownAxisGeography),
                    source: breakdownSourceGeographyLLM, contentHash: "hg", audit: nil)
            }

            #expect(summary.purged == 1)
            let geoOld = CompanyBreakdown.compositeID(docID: "S24", axis: breakdownAxisGeography)
            let bizOld = CompanyBreakdown.compositeID(docID: "S24", axis: breakdownAxisBusiness)
            #expect(try await CompanyBreakdown.find(geoOld, on: app.db) == nil)
            #expect(try await CompanyBreakdown.find(bizOld, on: app.db) != nil)
        }
    }

    /// LLM 経由（geography_llm）の geography 行は business と同じく cache_version が古くても read 可能。
    @Test func loadReturnsGeographyLLMRowEvenWithOldCacheVersion() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                axis: breakdownAxisGeography, source: breakdownSourceGeographyLLM,
                cacheVersion: "very-old-version")

            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: breakdownAxisGeography, db: app.db)
            let json = try #require(result.foundJSON)
            #expect(json["doc_id"] as? String == "S1")
        }
    }

    /// 軸別 cache_version: business バンプ相当の ingest は geography 行を stale にしない。
    @Test func businessIngestDoesNotReattemptGeographyAxisRowOnVersionMismatch() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                axis: breakdownAxisGeography, source: breakdownSourceXbrlFacts,
                cacheVersion: geographyBreakdownCacheVersion)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                axis: breakdownAxisBusiness, source: breakdownSourceXbrlFacts,
                cacheVersion: "breakdown-business-v0")

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                axis: breakdownAxisBusiness
            ) { _, _ in
                .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h-biz", audit: nil)
            }

            #expect(summary.attempted == 1)
            let geoKey = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisGeography)
            let geoRow = try #require(try await CompanyBreakdown.find(geoKey, on: app.db))
            #expect(geoRow.cacheVersion == geographyBreakdownCacheVersion)
            let bizKey = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisBusiness)
            let bizRow = try #require(try await CompanyBreakdown.find(bizKey, on: app.db))
            #expect(bizRow.cacheVersion == businessBreakdownCacheVersion)
        }
    }

    /// 軸別 cache_version: geography バンプ相当の ingest は business 行を stale にしない。
    @Test func geographyIngestDoesNotReattemptBusinessAxisRowOnVersionMismatch() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                axis: breakdownAxisBusiness, source: breakdownSourceXbrlFacts,
                cacheVersion: businessBreakdownCacheVersion)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                axis: breakdownAxisGeography, source: breakdownSourceXbrlFacts,
                cacheVersion: "breakdown-geography-v0")

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                axis: breakdownAxisGeography
            ) { _, _ in
                .resolved(
                    payload: fakePayload(axis: breakdownAxisGeography),
                    source: breakdownSourceXbrlFacts, contentHash: "h-geo", audit: nil)
            }

            #expect(summary.attempted == 1)
            let bizKey = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisBusiness)
            let bizRow = try #require(try await CompanyBreakdown.find(bizKey, on: app.db))
            #expect(bizRow.cacheVersion == businessBreakdownCacheVersion)
            let geoKey = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisGeography)
            let geoRow = try #require(try await CompanyBreakdown.find(geoKey, on: app.db))
            #expect(geoRow.cacheVersion == geographyBreakdownCacheVersion)
        }
    }
}
