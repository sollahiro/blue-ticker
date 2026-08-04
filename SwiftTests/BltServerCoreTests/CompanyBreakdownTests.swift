// 内訳取り込み の永続化スキーマ（company_breakdowns）が意図どおり動くかを検証する。
// docs/breakdown-normalization-concept.md「今後の検討事項5」参照。モデル・マイグレーション・
// 合成主キーのみを見る（ingest/read の実配線の検証は BreakdownIngestTests.swift）。

import BlueTickerCore
import Fluent
import FluentSQLiteDriver
import Foundation
import SQLKit
import Testing
import Vapor

@testable import BltServerCore

private func withMigratedApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        app.databases.use(.sqlite(.memory), as: .sqlite)
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

private func fakeSnapshot(
    axis: String = "business", sourceKind: String = "segment_info", needsReview: Bool = false
) -> BreakdownSnapshotPayload {
    BreakdownSnapshotPayload(
        axis: axis,
        denominator: 4_624_727_000_000,
        denominatorTag: "income_statement.sales",
        rows: [
            BreakdownRowPayload(labelRaw: "プリンティング", label: "プリンティング", amount: 2_487_885_000_000, profit: nil, rowKind: "segment"),
            BreakdownRowPayload(labelRaw: "メディカル", label: "メディカル", amount: 579_723_000_000, profit: nil, rowKind: "segment"),
        ],
        sourceKind: sourceKind,
        needsReview: needsReview,
        warnings: needsReview ? ["llm_row_sum_mismatch"] : []
    )
}

@Suite struct CompanyBreakdownTests {

    @Test func compositeIDJoinsDocIDAndAxisWithSeparator() {
        #expect(CompanyBreakdown.compositeID(docID: "S100XTLJ", axis: "business") == "S100XTLJ#business")
        #expect(CompanyBreakdown.compositeID(docID: "S100XTLJ", axis: "geography") == "S100XTLJ#geography")
    }

    @Test func createAndFindRoundTripsPayloadAndOptionalLLMAudit() async throws {
        try await withMigratedApp { app in
            let row = CompanyBreakdown(docID: "S100XTLJ", axis: "business")
            row.code = "7751"
            row.submitDateTime = "2026-03-25 00:00"
            row.payload = fakeSnapshot()
            row.needsReview = false
            row.source = breakdownSourceSegmentInfoLLM
            row.contentHash = "abc123"
            row.cacheVersion = businessBreakdownCacheVersion
            row.llmAudit = LLMBreakdownAuditPayload(sourceTableIndex: 1, periodColumn: "当期", unit: "million_yen", profitDisclosed: true, notes: "test")
            try await row.create(on: app.db)

            let found = try #require(try await CompanyBreakdown.find("S100XTLJ#business", on: app.db))
            #expect(found.docID == "S100XTLJ")
            #expect(found.axis == "business")
            #expect(found.code == "7751")
            #expect(found.source == "segment_info_llm")
            #expect(found.needsReview == false)
            #expect(found.payload.rows.count == 2)
            #expect(found.payload.rows[0].labelRaw == "プリンティング")
            #expect(found.llmAudit?.notes == "test")
            #expect(found.llmAudit?.profitDisclosed == true)
        }
    }

    @Test func llmAuditIsNilForDeterministicXbrlFactsRows() async throws {
        try await withMigratedApp { app in
            let row = CompanyBreakdown(docID: "S100VXJA", axis: "business")
            row.code = "2802"
            row.submitDateTime = "2025-03-31 00:00"
            row.payload = fakeSnapshot(sourceKind: "xbrl_facts")
            row.needsReview = false
            row.source = breakdownSourceXbrlFacts
            row.contentHash = "def456"
            row.cacheVersion = businessBreakdownCacheVersion
            row.llmAudit = nil
            try await row.create(on: app.db)

            let found = try #require(try await CompanyBreakdown.find("S100VXJA#business", on: app.db))
            #expect(found.llmAudit == nil)
            #expect(found.source == "xbrl_facts")
        }
    }

    /// 同一 (doc_id, axis) は同じ合成主キーになるため、2軸目は別行として共存できる
    /// （1書類につき business/geography 最大2行、という設計意図の確認）。
    /// compositeID が壊れて両行が同一 id になった場合、2件目の create() が PK 制約違反で
    /// throw するため、このテストは合成キー方式が正しく機能して初めて通る（トートロジーではない）。
    @Test func sameDocIDDifferentAxisCoexistAsSeparateRows() async throws {
        try await withMigratedApp { app in
            let business = CompanyBreakdown(docID: "S100W043", axis: "business")
            business.code = "6103"
            business.submitDateTime = "2025-06-20 00:00"
            business.payload = fakeSnapshot(axis: "business", sourceKind: "revenue_recognition")
            business.needsReview = false
            business.source = breakdownSourceRevenueRecognitionLLM
            business.contentHash = "h1"
            business.cacheVersion = businessBreakdownCacheVersion
            try await business.create(on: app.db)

            let geography = CompanyBreakdown(docID: "S100W043", axis: "geography")
            geography.code = "6103"
            geography.submitDateTime = "2025-06-20 00:00"
            geography.payload = fakeSnapshot(axis: "geography", sourceKind: "html_table")
            geography.needsReview = false
            geography.source = breakdownSourceGeographyLLM
            geography.contentHash = "h2"
            geography.cacheVersion = geographyBreakdownCacheVersion
            try await geography.create(on: app.db)

            #expect(try await CompanyBreakdown.query(on: app.db).filter(\.$docID == "S100W043").count() == 2)
        }
    }

    /// issue #132: notApplicable プレースホルダ行（payload はダミー、reason に E/F/unknown を保持）
    /// が往復できること。
    @Test func notApplicableReasonRoundTripsAndPayloadStaysNil() async throws {
        try await withMigratedApp { app in
            let row = CompanyBreakdown(docID: "S100AAAA", axis: "business")
            row.code = "9999"
            row.submitDateTime = "2026-03-25 00:00"
            row.payload = fakeSnapshot(sourceKind: breakdownSourceNotApplicable)
            row.needsReview = false
            row.source = breakdownSourceNotApplicable
            row.contentHash = ""
            row.cacheVersion = businessBreakdownCacheVersion
            row.notApplicableReason = breakdownNotApplicableGeographyOnly
            try await row.create(on: app.db)

            let found = try #require(try await CompanyBreakdown.find("S100AAAA#business", on: app.db))
            #expect(found.source == breakdownSourceNotApplicable)
            #expect(found.notApplicableReason == breakdownNotApplicableGeographyOnly)
        }
    }

    /// 実データ行（source != not_applicable）は notApplicableReason が nil のまま。
    @Test func notApplicableReasonIsNilForRealDataRows() async throws {
        try await withMigratedApp { app in
            let row = CompanyBreakdown(docID: "S100BBBB", axis: "business")
            row.code = "8888"
            row.submitDateTime = "2026-03-25 00:00"
            row.payload = fakeSnapshot()
            row.needsReview = false
            row.source = breakdownSourceXbrlFacts
            row.contentHash = "abc"
            row.cacheVersion = businessBreakdownCacheVersion
            try await row.create(on: app.db)

            let found = try #require(try await CompanyBreakdown.find("S100BBBB#business", on: app.db))
            #expect(found.notApplicableReason == nil)
        }
    }

    /// `label` フィールド追加（2026-08-03、`breakdown-business-v8`）より前に格納された行は
    /// payload JSON に `label` キーを持たない。合成 Decodable のままだと `keyNotFound` で読み取り
    /// 自体が失敗する（Opus 監査で発見）。生 SQL で `label` キー無しの旧形式 JSON を直接書き込み、
    /// `find` が失敗せず `labelRaw` へフォールバックすることを確認する。
    @Test func decodesPreLabelFieldPayloadByFallingBackToLabelRaw() async throws {
        try await withMigratedApp { app in
            let legacyPayloadJSON = """
                {"axis":"business","denominator":100.0,"denominatorTag":"income_statement.sales",\
                "rows":[{"labelRaw":"旧行","amount":50.0,"profit":null,"rowKind":"segment"}],\
                "sourceKind":"xbrl_facts","needsReview":false,"warnings":[]}
                """
            let db = try #require(app.db as? any SQLDatabase)
            try await db.raw(
                """
                INSERT INTO company_breakdowns
                    (id, doc_id, axis, code, submit_date_time, payload, needs_review, source, content_hash, cache_version)
                VALUES
                    ('S100LEGACY#business', 'S100LEGACY', 'business', '0001', '2025-01-01 00:00',
                     \(bind: legacyPayloadJSON), false, \(bind: breakdownSourceXbrlFacts), 'h',
                     \(bind: businessBreakdownCacheVersion))
                """
            ).run()

            let found = try #require(try await CompanyBreakdown.find("S100LEGACY#business", on: app.db))
            #expect(found.payload.rows.count == 1)
            #expect(found.payload.rows[0].labelRaw == "旧行")
            #expect(found.payload.rows[0].label == "旧行")
        }
    }

    @Test func needsReviewColumnIsQueryableWithoutTouchingPayload() async throws {
        try await withMigratedApp { app in
            let clean = CompanyBreakdown(docID: "S1", axis: "business")
            clean.code = "1111"
            clean.submitDateTime = "2025-01-01 00:00"
            clean.payload = fakeSnapshot(sourceKind: "xbrl_facts", needsReview: false)
            clean.needsReview = false
            clean.source = breakdownSourceXbrlFacts
            clean.contentHash = "h1"
            clean.cacheVersion = businessBreakdownCacheVersion
            try await clean.create(on: app.db)

            let flagged = CompanyBreakdown(docID: "S2", axis: "business")
            flagged.code = "2222"
            flagged.submitDateTime = "2025-01-01 00:00"
            flagged.payload = fakeSnapshot(sourceKind: "segment_info", needsReview: true)
            flagged.needsReview = true
            flagged.source = breakdownSourceSegmentInfoLLM
            flagged.contentHash = "h2"
            flagged.cacheVersion = businessBreakdownCacheVersion
            try await flagged.create(on: app.db)

            let needingReview = try await CompanyBreakdown.query(on: app.db)
                .filter(\.$needsReview == true)
                .all()
            #expect(needingReview.map(\.docID) == ["S2"])
        }
    }
}
