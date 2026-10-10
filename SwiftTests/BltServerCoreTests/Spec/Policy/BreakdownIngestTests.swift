// 内訳取り込みの DB ロジック（対象選定・staleness 判定・upsert・limit・purge）と
// read 経路（loadStoredBreakdown）、および servable/unservable 集計を検証する。
// 解決（resolveBusinessBreakdown）は EDINET/LLM 依存のため、フェイク解決器を注入して
// ネットワーク非依存で見る。
//
// staleness: 決定論（xbrl_facts / stacked_segment_pnl / not_applicable）も LLM 経由
// （segment_info_llm 等）も cache_version 不一致で再試行する。決定論の needs_review=true
// だけでは現行版は再試行しない。LLM の needs_review=true は現行版でも再試行する。
// read の servable 判定も同じ version gate を共有する。公開 serving はさらに
// needs_review / llm_unit_unresolved の LLM 行を除外する（isPubliclyServableBreakdown）。

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
        app.migrations.add(AddParentDocIDToEdinetDocuments())
        app.migrations.add(CreateCompanySegmentBreakdowns())
        app.migrations.add(RenameCompanySegmentBreakdownsToCompanyBreakdowns())
        app.migrations.add(AddNotApplicableReasonToCompanyBreakdowns())
        app.migrations.add(CreateCompanyFinancials())
        app.migrations.add(CreateCompanyHalfFinancials())
        app.migrations.add(AddHighWaterToCompanyFinancials())
        app.migrations.add(AddAssemblyFingerprintToCompanyFinancials())
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
    submit: String = "2025-06-20 09:00",
    ordinance: String? = Api.ordinanceCompanyDisclosure,
    form: String? = "030000",
    db: Database
) async throws {
    let model = EdinetDocument()
    model.id = docID
    model.edinetCode = "E00001"
    model.secCode = secCode
    model.filerName = "テスト株式会社"
    model.docTypeCode = docType
    model.ordinanceCode = ordinance
    model.formCode = form
    model.submitDateTime = submit
    try await model.create(on: db)
}

private func fakePayload(
    axis: String = breakdownAxisProductService, needsReview: Bool = false, warnings: [String]? = nil,
    segments: Int = 1
) -> BreakdownSnapshotPayload {
    let rows = (0..<max(segments, 1)).map { index in
        BreakdownRowPayload(
            labelRaw: "セグメント\(index)", label: "セグメント\(index)",
            amount: 500_000, profit: nil, rowKind: "segment")
    }
    return BreakdownSnapshotPayload(
        axis: axis, denominator: 1_000_000, denominatorTag: "income_statement.sales",
        rows: rows,
        sourceKind: "test", needsReview: needsReview,
        warnings: warnings ?? (needsReview ? ["test_flag"] : []))
}

private func seedRow(
    _ docID: String, code: String, submit: String, db: Database,
    axis: String = breakdownAxisProductService,
    source: String = breakdownSourceXbrlFacts, cacheVersion: String = productServiceBreakdownCacheVersion,
    needsReview: Bool = false, contentHash: String = "h0", llmAudit: LLMBreakdownAuditPayload? = nil,
    notApplicableReason: String? = nil, warnings: [String]? = nil, segments: Int = 1
) async throws {
    let row = CompanyBreakdown(docID: docID, axis: axis)
    row.code = code
    row.submitDateTime = submit
    row.payload = fakePayload(
        axis: axis, needsReview: needsReview, warnings: warnings, segments: segments)
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
    fileprivate var withheldReason: String? {
        if case .withheld(let reason) = self { return reason }
        return nil
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
            ) { _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
            let key1 = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisProductService)
            let row = try #require(try await CompanyBreakdown.find(key1, on: app.db))
            #expect(row.code == "7203")
            #expect(row.source == breakdownSourceXbrlFacts)
        }
    }

    /// business は company_financials 行が無くても resolve を試す（分母は resolve 側が XBRL から解決、#9）。
    @Test func ingestAttemptsBusinessResolveWithoutFinancialsRow() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "87500", db: app.db)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["8750"], years: 3, limit: nil
            ) { _ in
                .resolved(
                    payload: fakePayload(), source: breakdownSourceXbrlFacts,
                    contentHash: "h-ins", audit: nil)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
        }
    }

    @Test func ingestExcludesCompaniesNotInTargetSet() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)  // target
            try await seedDoc("S2", secCode: "99990", db: app.db)  // not in target

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

            #expect(summary.attempted == 1)
            let key2 = CompanyBreakdown.compositeID(docID: "S2", axis: breakdownAxisProductService)
            #expect(try await CompanyBreakdown.find(key2, on: app.db) == nil)
        }
    }

    @Test func ingestExcludesNonAnnualDocTypes() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)  // 有報120
            try await seedDoc("S2", secCode: "72030", docType: "160", db: app.db)  // 半期

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

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
            ) { _ in .notApplicable(reason: breakdownNotApplicableGeographyOnly) }

            #expect(summary.attempted == 1)
            #expect(summary.notApplicable == 1)
            #expect(summary.stored == 0)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisProductService)
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.source == breakdownSourceNotApplicable)
            #expect(row.notApplicableReason == breakdownNotApplicableGeographyOnly)
            // E/F は確信度の高い決定的判定のため needsReview=false。
            #expect(row.needsReview == false)
        }
    }

    /// Jev が省略を適用しなかったときは、決定的 reason でも needs_review と llm_audit を残す。
    @Test func ingestKeepsJevAuditWhenOmissionIsWithheld() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            let call = SegmentNoteJevCallPayload(
                question: "omission", options: ["single_segment", "none"],
                selected: "single_segment", probability: 0.5, sentences: ["文"], applied: false)
            let jev = SegmentNoteJevAuditPayload(
                code: "", docID: "S1", axis: breakdownAxisProductService, model: "typesafe/jev-1.13",
                threshold: 0.9, applied: false, needsReview: true, sentences: ["文"], calls: [call])

            _ = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _ in
                .notApplicable(
                    reason: breakdownNotApplicableSingleSegmentDisclosed,
                    audit: .segmentNoteJev(jev))
            }

            let key = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisProductService)
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.notApplicableReason == breakdownNotApplicableSingleSegmentDisclosed)
            #expect(row.needsReview == true)
            #expect(row.llmAudit?.jev?.applied == false)
            #expect(row.llmAudit?.jev?.needsReview == true)
            #expect(row.llmAudit?.jev?.code == row.code)
            #expect(row.llmAudit?.jev?.calls.first?.probability == 0.5)
            #expect(row.llmAudit?.jev?.calls.first?.selected == "single_segment")
        }
    }

    /// unknown は要調査のため needsReview=true で保存する。決定論なので通常巡回では
    /// 再計算せず、分類ロジック改善後は cache_version バンプで再分類する。
    @Test func ingestFlagsUnknownNotApplicableReasonForReview() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)

            _ = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _ in .notApplicable(reason: breakdownNotApplicableUnknown) }

            let key = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisProductService)
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
                source: breakdownSourceSegmentInfoLLM, cacheVersion: productServiceBreakdownCacheVersion,
                needsReview: true, contentHash: "real-hash", llmAudit: audit)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _ in .notApplicable(reason: breakdownNotApplicableUnknown) }

            #expect(summary.attempted == 1)
            #expect(summary.notApplicable == 1)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisProductService)
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
            ) { _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h9", audit: nil) }

            let key = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisProductService)
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
            ) { _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h2", audit: nil) }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
        }
    }

    @Test func ingestSkipsNotApplicableRowAlreadyAtCurrentVersion() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceNotApplicable, cacheVersion: productServiceBreakdownCacheVersion,
                notApplicableReason: breakdownNotApplicableSingleSegmentDisclosed)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _ in
                Issue.record("resolver must not run for an up-to-date not_applicable row")
                return .failed
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    @Test func ingestSkipsUnknownNotApplicableFlaggedForReviewAtCurrentVersion() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceNotApplicable, cacheVersion: productServiceBreakdownCacheVersion,
                needsReview: true, notApplicableReason: breakdownNotApplicableUnknown)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _ in
                Issue.record("resolver must not run for a current-version not_applicable row")
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
            ) { docID in
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
            ) { _ in .failed }

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
            ) { _ in
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
            ) { _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h2", audit: nil) }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisProductService)
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.cacheVersion == productServiceBreakdownCacheVersion)
        }
    }

    /// clean な segment_info_llm も cache_version 不一致なら再試行する
    /// （バンプ無視の空配線で誤 profit が残らないようにする）。
    @Test func ingestReattemptsCleanLLMRowWhenVersionStale() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceSegmentInfoLLM, cacheVersion: "old-version",
                needsReview: false)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _ in
                .resolved(
                    payload: fakePayload(needsReview: false),
                    source: breakdownSourceStackedSegmentPnL,
                    contentHash: "h-stacked", audit: nil)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisProductService)
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.cacheVersion == productServiceBreakdownCacheVersion)
            #expect(row.source == breakdownSourceStackedSegmentPnL)
        }
    }

    @Test func ingestReattemptsLLMRowFlaggedForReview() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceSegmentInfoLLM, cacheVersion: productServiceBreakdownCacheVersion,
                needsReview: true)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _ in .resolved(payload: fakePayload(needsReview: false), source: breakdownSourceSegmentInfoLLM, contentHash: "h3", audit: nil) }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisProductService)
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.needsReview == false)
        }
    }

    /// 決定論の needs_review は同じ入力では結果が変わらない（RD 未タグ残差など）。
    /// 現行版のまま再試行すると unpublished 軸の limit を埋め続ける。
    @Test func ingestSkipsDeterministicRowFlaggedForReviewAtCurrentVersion() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceXbrlFacts, cacheVersion: productServiceBreakdownCacheVersion,
                needsReview: true)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _ in
                Issue.record("resolver must not run for a current-version xbrl_facts row")
                return .failed
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    /// interest_bearing_debt は xbrl_facts でも、Jev 未分類の現行版行だけ再試行する。
    /// coverage だけの needs_review は再試行しない。
    @Test func ingestRetriesInterestBearingDebtWhenJevBlocked() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S_JEV", secCode: "67580", db: app.db)
            try await seedDoc("S_COV", secCode: "72030", db: app.db)
            try await seedRow(
                "S_JEV", code: "6758", submit: "2025-06-20 09:00", db: app.db,
                axis: breakdownAxisInterestBearingDebt,
                source: breakdownSourceXbrlFacts,
                cacheVersion: interestBearingDebtBreakdownCacheVersion,
                needsReview: true, warnings: [breakdownWarningIBDRowUnclassified])
            try await seedRow(
                "S_COV", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                axis: breakdownAxisInterestBearingDebt,
                source: breakdownSourceXbrlFacts,
                cacheVersion: interestBearingDebtBreakdownCacheVersion,
                needsReview: true, warnings: [breakdownWarningIBDCoverageOutOfBand])

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["6758", "7203"], years: 3, limit: nil,
                axis: breakdownAxisInterestBearingDebt
            ) { docID in
                #expect(docID == "S_JEV")
                return .resolved(
                    payload: fakePayload(
                        axis: breakdownAxisInterestBearingDebt, needsReview: false, warnings: []),
                    source: breakdownSourceXbrlFacts, contentHash: "h-jev", audit: nil)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            #expect(summary.skipped == 1)
        }
    }

    @Test func ingestReattemptsDeterministicRowFlaggedForReviewWhenVersionStale() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceXbrlFacts, cacheVersion: "old-version",
                needsReview: true)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _ in
                .resolved(
                    payload: fakePayload(needsReview: true), source: breakdownSourceXbrlFacts,
                    contentHash: "h-stale-review", audit: nil)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisProductService)
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.cacheVersion == productServiceBreakdownCacheVersion)
            #expect(row.needsReview == true)
        }
    }

    @Test func ingestLimitsNewlyAttempted() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)
            try await seedDoc("S3", secCode: "99840", db: app.db)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203", "6758", "9984"], years: 3, limit: 2
            ) { _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

            #expect(summary.attempted == 2)
            #expect(summary.stored == 2)
        }
    }

    @Test func ingestRespectsPrecomputedCandidateKeepList() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedDoc("S2", secCode: "67580", db: app.db)
            let sets = FilingSectionCandidateSets(
                keep: [FilingDocCandidate(docID: "S1", code: "7203", submitDateTime: "2025-06-20 09:00")],
                purge: [])

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203", "6758"], years: 3, limit: nil,
                candidateSets: sets
            ) { _ in
                .resolved(
                    payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1",
                    audit: nil)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            #expect(
                try await CompanyBreakdown.find(
                    CompanyBreakdown.compositeID(docID: "S2", axis: breakdownAxisProductService), on: app.db) == nil)
        }
    }

    @Test func ingestPrefersCachedDocWhenLimitCutsOff() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", submit: "2025-06-20 09:00", db: app.db)
            try await seedDoc("S2", secCode: "67580", submit: "2024-06-20 09:00", db: app.db)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203", "6758"], years: 3, limit: 1,
                cachedDocIDs: ["S2"]
            ) { _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

            #expect(summary.attempted == 1)
            #expect(try await CompanyBreakdown.find(
                CompanyBreakdown.compositeID(docID: "S2", axis: breakdownAxisProductService), on: app.db) != nil)
            #expect(try await CompanyBreakdown.find(
                CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisProductService), on: app.db) == nil)
        }
    }

    @Test func ingestPrefersEachCompanysLatestYearBeforeOlderYearsWhenLimited() async throws {
        try await withMigratedApp { app in
            try await seedDoc("LATEST7203", secCode: "72030", submit: "2026-06-20 09:00", db: app.db)
            try await seedDoc("PRIOR7203", secCode: "72030", submit: "2025-06-20 09:00", db: app.db)
            try await seedDoc("LATEST6758", secCode: "67580", submit: "2025-03-31 09:00", db: app.db)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203", "6758"], years: 3, limit: 2,
                cachedDocIDs: ["PRIOR7203"]
            ) { _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

            #expect(summary.attempted == 2)
            #expect(try await CompanyBreakdown.find(
                CompanyBreakdown.compositeID(docID: "LATEST7203", axis: breakdownAxisProductService), on: app.db) != nil)
            #expect(try await CompanyBreakdown.find(
                CompanyBreakdown.compositeID(docID: "LATEST6758", axis: breakdownAxisProductService), on: app.db) != nil)
            #expect(try await CompanyBreakdown.find(
                CompanyBreakdown.compositeID(docID: "PRIOR7203", axis: breakdownAxisProductService), on: app.db) == nil)
        }
    }

    @Test func ingestPrefersNikkeiOverCachedNonNikkeiWhenLimitCutsOff() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "99990", submit: "2025-06-20 09:00", db: app.db)
            try await seedDoc("S2", secCode: "72030", submit: "2024-06-20 09:00", db: app.db)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["9999", "7203"], years: 3, limit: 1,
                priorityCodes: ["7203"], cachedDocIDs: ["S1"]
            ) { _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

            #expect(summary.attempted == 1)
            #expect(try await CompanyBreakdown.find(
                CompanyBreakdown.compositeID(docID: "S2", axis: breakdownAxisProductService), on: app.db) != nil)
            #expect(try await CompanyBreakdown.find(
                CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisProductService), on: app.db) == nil)
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
            ) { _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

            #expect(summary.purged == 1)
            let key22 = CompanyBreakdown.compositeID(docID: "S22", axis: breakdownAxisProductService)
            #expect(try await CompanyBreakdown.find(key22, on: app.db) == nil)
        }
    }

    @Test func ingestPurgeCountIsZeroWhenNoRowsExistOutsideWindow() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S22", secCode: "72030", submit: "2022-06-20 09:00", db: app.db)
            try await seedDoc("S23", secCode: "72030", submit: "2023-06-20 09:00", db: app.db)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil
            ) { _ in .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h1", audit: nil) }

            #expect(summary.purged == 0)
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

    /// パース不能な cache_version の LLM 行は非 servable（version gate 対象）。
    @Test func countServableTreatsUnparseableLLMVersionAsUnservable() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceSegmentInfoLLM, cacheVersion: "very-old-version")

            let coverage = try await countServableBreakdowns(db: app.db)
            #expect(coverage.servable == 0)
            #expect(coverage.unservable == 1)
        }
    }

    // MARK: - read 経路

    @Test func loadByCodeReturnsLatestDocument() async throws {
        try await withMigratedApp { app in
            try await seedRow("S24", code: "7203", submit: "2024-06-20 09:00", db: app.db)
            try await seedRow("S25", code: "7203", submit: "2025-06-20 09:00", db: app.db)

            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: breakdownAxisProductService, db: app.db)
            let json = try #require(result.foundJSON)
            #expect(json["doc_id"] as? String == "S25")
            #expect(json["code"] as? String == "7203")
            #expect(json["axis"] as? String == breakdownAxisProductService)
            let breakdown = try #require(json["breakdown"] as? [String: Any])
            #expect(breakdown["axis"] as? String == breakdownAxisProductService)
        }
    }

    @Test func loadByCodeSkipsNewerTrustFilingPreferringCompanyAnnual() async throws {
        try await withMigratedApp { app in
            try await seedDoc(
                "S100YCDE", secCode: "82530", submit: "2026-06-16 11:38", db: app.db)
            try await seedDoc(
                "S100YZ8K", secCode: "82530", submit: "2026-08-28 16:00",
                ordinance: "030", form: "09A000", db: app.db)
            try await seedRow(
                "S100YCDE", code: "8253", submit: "2026-06-16 11:38", db: app.db)
            try await seedRow(
                "S100YZ8K", code: "8253", submit: "2026-08-28 16:00", db: app.db)

            let result = try await loadStoredBreakdown(
                code: "8253", docId: nil, axis: breakdownAxisProductService, db: app.db)
            let json = try #require(result.foundJSON)
            #expect(json["doc_id"] as? String == "S100YCDE")

            let explicit = try await loadStoredBreakdown(
                code: "8253", docId: "S100YZ8K", axis: breakdownAxisProductService, db: app.db)
            #expect(explicit.isAbsent)
        }
    }

    @Test func loadByDocIdReturnsThatDocument() async throws {
        try await withMigratedApp { app in
            try await seedRow("S24", code: "7203", submit: "2024-06-20 09:00", db: app.db)
            try await seedRow("S25", code: "7203", submit: "2025-06-20 09:00", db: app.db)

            let result = try await loadStoredBreakdown(
                code: "7203", docId: "S24", axis: breakdownAxisProductService, db: app.db)
            let json = try #require(result.foundJSON)
            #expect(json["doc_id"] as? String == "S24")
        }
    }

    @Test func loadByDocIdRejectsMismatchedCode() async throws {
        try await withMigratedApp { app in
            try await seedRow("S1", code: "7203", submit: "2025-06-20 09:00", db: app.db)
            let result = try await loadStoredBreakdown(
                code: "6758", docId: "S1", axis: breakdownAxisProductService, db: app.db)
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

    /// 公開 serving stopgap: LLM の needs_review / llm_unit_unresolved は出さず、clean 行は出す。
    /// 残行 0 は未算出と同じ absent。XBRL の needs_review は触らない。
    @Test func loadHidesNeedsReviewAndUnresolvedUnitLLMRows() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S_REVIEW", code: "332A", submit: "2026-06-20 09:00", db: app.db,
                source: breakdownSourceRevenueRecognitionLLM, needsReview: true)
            try await seedRow(
                "S_UNIT", code: "7096", submit: "2026-06-20 09:00", db: app.db,
                axis: breakdownAxisGeography, source: breakdownSourceGeographyLLM,
                cacheVersion: geographyBreakdownCacheVersion, needsReview: false,
                warnings: [breakdownWarningLLMUnitUnresolved])
            try await seedRow(
                "S_OK", code: "7203", submit: "2026-06-20 09:00", db: app.db,
                source: breakdownSourceSegmentInfoLLM, needsReview: false)
            try await seedRow(
                "S_XBRL", code: "6758", submit: "2026-06-20 09:00", db: app.db,
                source: breakdownSourceXbrlFacts, needsReview: true)

            let hiddenReview = try await loadStoredBreakdown(
                code: "332A", docId: nil, axis: breakdownAxisProductService, db: app.db)
            #expect(hiddenReview.isAbsent)

            let hiddenUnit = try await loadStoredBreakdown(
                code: "7096", docId: nil, axis: breakdownAxisGeography, db: app.db)
            #expect(hiddenUnit.isAbsent)

            let served = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: breakdownAxisProductService, db: app.db)
            let json = try #require(served.foundJSON)
            #expect(json["doc_id"] as? String == "S_OK")
            let breakdown = try #require(json["breakdown"] as? [String: Any])
            #expect(breakdown["needs_review"] as? Bool == false)
            let rows = try #require(breakdown["rows"] as? [[String: Any]])
            #expect(rows.count == 1)

            let xbrl = try await loadStoredBreakdown(
                code: "6758", docId: nil, axis: breakdownAxisProductService, db: app.db)
            let xbrlJSON = try #require(xbrl.foundJSON)
            #expect(xbrlJSON["doc_id"] as? String == "S_XBRL")
        }
    }

    /// interest_bearing_debt の needs_review は未算出ではなく withheld。
    /// geography の公開除外は従来どおり absent。
    @Test func loadWithholdsInterestBearingDebtNeedsReview() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S_IBD", code: "6758", submit: "2026-06-20 09:00", db: app.db,
                axis: breakdownAxisInterestBearingDebt,
                source: breakdownSourceXbrlFacts,
                cacheVersion: interestBearingDebtBreakdownCacheVersion,
                needsReview: true, warnings: [breakdownWarningIBDCoverageOutOfBand])
            try await seedRow(
                "S_GEO", code: "7203", submit: "2026-06-20 09:00", db: app.db,
                axis: breakdownAxisGeography, source: breakdownSourceGeographyLLM,
                cacheVersion: geographyBreakdownCacheVersion, needsReview: true)

            let withheld = try await loadStoredBreakdown(
                code: "6758", docId: nil, axis: breakdownAxisInterestBearingDebt, db: app.db)
            #expect(withheld.withheldReason == breakdownWithheldNeedsReview)
            if case .withheld(let reason, let message) = mapWithheldBreakdownLoad(
                breakdownWithheldNeedsReview)
            {
                #expect(reason == breakdownNotApplicableUnknown)
                #expect(message == "有利子負債の内訳は公開していません")
            } else {
                Issue.record("expected withheld")
            }

            let geography = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: breakdownAxisGeography, db: app.db)
            #expect(geography.isAbsent)
            #expect(geography.withheldReason == nil)
        }
    }

    @Test func loadHidesOverlayRegressionEvenOnXbrlFactsRows() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S100W0S7", code: "8316", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceXbrlFacts, needsReview: true,
                warnings: [
                    "overlay_regression:row_loss:S100X7DX:orig=S100W0S7:tag=Holding:before=70:after=13"
                ])

            let hidden = try await loadStoredBreakdown(
                code: "8316", docId: nil, axis: breakdownAxisProductService, db: app.db)
            #expect(hidden.isAbsent)
            let byDoc = try await loadStoredBreakdown(
                code: "8316", docId: "S100W0S7", axis: breakdownAxisProductService, db: app.db)
            #expect(byDoc.isAbsent)
        }
    }

    /// 公開除外の最新 LLM 行があっても前年の clean 行へは落とさない（未算出と同じ absent）。
    @Test func loadDoesNotFallBackToOlderCleanWhenLatestLLMRowIsHidden() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S24", code: "332A", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceRevenueRecognitionLLM, needsReview: false, segments: 2)
            try await seedRow(
                "S25", code: "332A", submit: "2026-06-20 09:00", db: app.db,
                source: breakdownSourceRevenueRecognitionLLM, needsReview: true)

            let result = try await loadStoredBreakdown(
                code: "332A", docId: nil, axis: breakdownAxisProductService, db: app.db)
            #expect(result.isAbsent)

            let older = try await loadStoredBreakdown(
                code: "332A", docId: "S24", axis: breakdownAxisProductService, db: app.db)
            #expect(older.foundJSON?["doc_id"] as? String == "S24")
        }
    }

    /// 収益分解の単一行は needs_review=false でも公開しない（6620 付随収入）。
    @Test func loadHidesSingleRowRevenueRecognitionEvenWhenClean() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S100YJZT", secCode: "66200", db: app.db)
            try await seedRow(
                "S100YJZT", code: "6620", submit: "2026-06-25 13:27", db: app.db,
                source: breakdownSourceRevenueRecognitionLLM, needsReview: false, segments: 1)

            let result = try await loadStoredBreakdown(
                code: "6620", docId: "S100YJZT", axis: breakdownAxisProductService, db: app.db)
            #expect(result.isAbsent)
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
                code: "7203", docId: nil, axis: breakdownAxisProductService, db: app.db)
            #expect(result.isAbsent)
        }
    }

    /// パース不能な cache_version の LLM 行は read しない。
    @Test func loadOmitsLLMRowWithUnparseableCacheVersion() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                source: breakdownSourceSegmentInfoLLM, cacheVersion: "very-old-version")
            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: breakdownAxisProductService, db: app.db)
            #expect(result.isAbsent)
        }
    }

    @Test func loadReturnsNilForUnknownCompany() async throws {
        try await withMigratedApp { app in
            let result = try await loadStoredBreakdown(
                code: "0000", docId: nil, axis: breakdownAxisProductService, db: app.db)
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
                code: "7203", docId: nil, axis: breakdownAxisProductService, db: app.db)
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
                code: "8604", docId: nil, axis: breakdownAxisProductService, db: app.db)
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
                source: breakdownSourceNotApplicable, cacheVersion: productServiceBreakdownCacheVersion,
                notApplicableReason: breakdownNotApplicableGeographyOnly)

            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: breakdownAxisProductService, db: app.db)
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
                code: "7203", docId: nil, axis: breakdownAxisProductService, db: app.db)
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
                source: breakdownSourceNotApplicable, cacheVersion: productServiceBreakdownCacheVersion,
                notApplicableReason: breakdownNotApplicableSingleSegmentDisclosed)

            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: breakdownAxisProductService, db: app.db)
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
            ) { _ in
                .resolved(
                    payload: fakePayload(axis: breakdownAxisGeography),
                    source: breakdownSourceGeographyLLM, contentHash: "hg1", audit: nil)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let geoKey = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisGeography)
            let bizKey = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisProductService)
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
            ) { _ in .notApplicable(reason: breakdownNotApplicableNotFound) }

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
            ) { _ in .notApplicable(reason: breakdownNotApplicableUnknown) }

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
                axis: breakdownAxisProductService, source: breakdownSourceXbrlFacts)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 1, limit: nil,
                axis: breakdownAxisGeography
            ) { _ in
                .resolved(
                    payload: fakePayload(axis: breakdownAxisGeography),
                    source: breakdownSourceGeographyLLM, contentHash: "hg", audit: nil)
            }

            #expect(summary.purged == 1)
            let geoOld = CompanyBreakdown.compositeID(docID: "S24", axis: breakdownAxisGeography)
            let bizOld = CompanyBreakdown.compositeID(docID: "S24", axis: breakdownAxisProductService)
            #expect(try await CompanyBreakdown.find(geoOld, on: app.db) == nil)
            #expect(try await CompanyBreakdown.find(bizOld, on: app.db) != nil)
        }
    }

    /// geography_llm も version gate 対象（パース不能な cache_version は非 servable）。
    @Test func loadOmitsGeographyLLMRowWithUnparseableCacheVersion() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                axis: breakdownAxisGeography, source: breakdownSourceGeographyLLM,
                cacheVersion: "very-old-version")

            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: breakdownAxisGeography, db: app.db)
            #expect(result.isAbsent)
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
                axis: breakdownAxisProductService, source: breakdownSourceXbrlFacts,
                cacheVersion: "breakdown-business-v0")

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                axis: breakdownAxisProductService
            ) { _ in
                .resolved(payload: fakePayload(), source: breakdownSourceXbrlFacts, contentHash: "h-biz", audit: nil)
            }

            #expect(summary.attempted == 1)
            let geoKey = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisGeography)
            let geoRow = try #require(try await CompanyBreakdown.find(geoKey, on: app.db))
            #expect(geoRow.cacheVersion == geographyBreakdownCacheVersion)
            let bizKey = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisProductService)
            let bizRow = try #require(try await CompanyBreakdown.find(bizKey, on: app.db))
            #expect(bizRow.cacheVersion == productServiceBreakdownCacheVersion)
        }
    }

    /// 軸別 cache_version: geography バンプ相当の ingest は business 行を stale にしない。
    @Test func geographyIngestDoesNotReattemptBusinessAxisRowOnVersionMismatch() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                axis: breakdownAxisProductService, source: breakdownSourceXbrlFacts,
                cacheVersion: productServiceBreakdownCacheVersion)
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                axis: breakdownAxisGeography, source: breakdownSourceXbrlFacts,
                cacheVersion: "breakdown-geography-v0")

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                axis: breakdownAxisGeography
            ) { _ in
                .resolved(
                    payload: fakePayload(axis: breakdownAxisGeography),
                    source: breakdownSourceXbrlFacts, contentHash: "h-geo", audit: nil)
            }

            #expect(summary.attempted == 1)
            let bizKey = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisProductService)
            let bizRow = try #require(try await CompanyBreakdown.find(bizKey, on: app.db))
            #expect(bizRow.cacheVersion == productServiceBreakdownCacheVersion)
            let geoKey = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisGeography)
            let geoRow = try #require(try await CompanyBreakdown.find(geoKey, on: app.db))
            #expect(geoRow.cacheVersion == geographyBreakdownCacheVersion)
        }
    }

    // MARK: - goodwill 軸（2026-08-13）

    /// 全軸とも company_financials 分母なしで resolve に進む（#9）。
    @Test func goodwillIngestStoresResolvedWithoutFinancials() async throws {
        try await withMigratedApp { app in
            let model = EdinetDocument()
            model.id = "S1"
            model.edinetCode = "E00001"
            model.secCode = "68410"
            model.filerName = "横河電機株式会社"
            model.docTypeCode = Api.docTypeAnnualReport
            model.ordinanceCode = Api.ordinanceCompanyDisclosure
            model.formCode = "030000"
            model.submitDateTime = "2025-06-20 09:00"
            try await model.create(on: app.db)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["6841"], years: 3, limit: nil,
                axis: breakdownAxisGoodwill
            ) { _ in
                .resolved(
                    payload: fakePayload(axis: breakdownAxisGoodwill),
                    source: breakdownSourceXbrlFacts, contentHash: "h-gw", audit: nil)
            }

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisGoodwill)
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.cacheVersion == goodwillBreakdownCacheVersion)
            #expect(row.source == breakdownSourceXbrlFacts)
        }
    }

    @Test func goodwillIngestStoresNotFoundWhenUnresolved() async throws {
        try await withMigratedApp { app in
            let model = EdinetDocument()
            model.id = "S1"
            model.edinetCode = "E00001"
            model.secCode = "72030"
            model.filerName = "トヨタ自動車株式会社"
            model.docTypeCode = Api.docTypeAnnualReport
            model.ordinanceCode = Api.ordinanceCompanyDisclosure
            model.formCode = "030000"
            model.submitDateTime = "2025-06-20 09:00"
            try await model.create(on: app.db)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                axis: breakdownAxisGoodwill
            ) { _ in .notApplicable(reason: breakdownNotApplicableNotFound) }

            #expect(summary.attempted == 1)
            #expect(summary.notApplicable == 1)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisGoodwill)
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.source == breakdownSourceNotApplicable)
            #expect(row.notApplicableReason == breakdownNotApplicableNotFound)
            #expect(row.needsReview == false)
        }
    }

    @Test func loadStoredBreakdownReturnsGoodwillAxis() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "6841", submit: "2025-06-20 09:00", db: app.db,
                axis: breakdownAxisGoodwill, source: breakdownSourceXbrlFacts,
                cacheVersion: goodwillBreakdownCacheVersion)

            let result = try await loadStoredBreakdown(
                code: "6841", docId: nil, axis: breakdownAxisGoodwill, db: app.db)
            let json = try #require(result.foundJSON)
            #expect(json["doc_id"] as? String == "S1")
            #expect(json["axis"] as? String == breakdownAxisGoodwill)
        }
    }

    @Test func loadStoredBreakdownReturnsCapexAxis() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                axis: breakdownAxisCapex, source: breakdownSourceXbrlFacts,
                cacheVersion: capexBreakdownCacheVersion)

            let result = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: breakdownAxisCapex, db: app.db)
            let json = try #require(result.foundJSON)
            #expect(json["axis"] as? String == breakdownAxisCapex)
            let breakdown = try #require(json["breakdown"] as? [String: Any])
            #expect(breakdown["amount"] == nil)
            #expect(breakdown["denominator"] == nil)
            #expect(breakdown["axis"] as? String == breakdownAxisCapex)
        }
    }

    @Test func loadStoredBreakdownDoesNotAliasLegacyBusinessAxis() async throws {
        try await withMigratedApp { app in
            try await seedRow(
                "S1", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                axis: "business", source: breakdownSourceXbrlFacts,
                cacheVersion: productServiceBreakdownCacheVersion)
            let product = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: breakdownAxisProductService, db: app.db)
            #expect(product.isAbsent)
            let legacy = try await loadStoredBreakdown(
                code: "7203", docId: nil, axis: "business", db: app.db)
            #expect(legacy.isAbsent)
        }
    }

    @Test func loadStoredBreakdownRejectsRetiredCapexAxes() async throws {
        try await withMigratedApp { app in
            for axis in retiredBreakdownAxes {
                try await seedRow(
                    "S-\(axis)", code: "7203", submit: "2025-06-20 09:00", db: app.db,
                    axis: axis, source: breakdownSourceXbrlFacts,
                    cacheVersion: "stale")
                let result = try await loadStoredBreakdown(
                    code: "7203", docId: nil, axis: axis, db: app.db)
                #expect(result.isAbsent)
            }
        }
    }

    @Test func capexIngestStoresResolvedRow() async throws {
        try await withMigratedApp { app in
            let model = EdinetDocument()
            model.id = "S1"
            model.edinetCode = "E00001"
            model.secCode = "72030"
            model.filerName = "トヨタ自動車株式会社"
            model.docTypeCode = Api.docTypeAnnualReport
            model.ordinanceCode = Api.ordinanceCompanyDisclosure
            model.formCode = "030000"
            model.submitDateTime = "2025-06-20 09:00"
            try await model.create(on: app.db)

            let summary = try await runBreakdownIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                axis: breakdownAxisCapex
            ) { _ in
                .resolved(
                    payload: fakePayload(axis: breakdownAxisCapex),
                    source: breakdownSourceXbrlFacts, contentHash: "h-capex", audit: nil)
            }
            #expect(summary.stored == 1)
            let key = CompanyBreakdown.compositeID(docID: "S1", axis: breakdownAxisCapex)
            let row = try #require(try await CompanyBreakdown.find(key, on: app.db))
            #expect(row.cacheVersion == capexBreakdownCacheVersion)
        }
    }
}
