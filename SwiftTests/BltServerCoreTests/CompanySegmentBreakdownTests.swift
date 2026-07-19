// Stage 6 の永続化スキーマ（company_segment_breakdowns）が意図どおり動くかを検証する。
// docs/segment-normalization-concept.md「今後の検討事項5」参照。ingest/read の実配線
// （今後の検討事項1）はまだ無いため、ここではモデル・マイグレーション・合成主キーのみを見る。

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
        app.migrations.add(CreateCompanySegmentBreakdowns())
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
            BreakdownRowPayload(labelRaw: "プリンティング", amount: 2_487_885_000_000, share: 0.538, profit: nil, rowKind: "segment"),
            BreakdownRowPayload(labelRaw: "メディカル", amount: 579_723_000_000, share: 0.125, profit: nil, rowKind: "segment"),
        ],
        sourceKind: sourceKind,
        needsReview: needsReview,
        warnings: needsReview ? ["llm_row_sum_mismatch"] : []
    )
}

@Suite struct CompanySegmentBreakdownTests {

    @Test func compositeIDJoinsDocIDAndAxisWithSeparator() {
        #expect(CompanySegmentBreakdown.compositeID(docID: "S100XTLJ", axis: "business") == "S100XTLJ#business")
        #expect(CompanySegmentBreakdown.compositeID(docID: "S100XTLJ", axis: "geography") == "S100XTLJ#geography")
    }

    @Test func createAndFindRoundTripsPayloadAndOptionalLLMAudit() async throws {
        try await withMigratedApp { app in
            let row = CompanySegmentBreakdown(docID: "S100XTLJ", axis: "business")
            row.code = "7751"
            row.submitDateTime = "2026-03-25 00:00"
            row.payload = fakeSnapshot()
            row.needsReview = false
            row.source = segmentBreakdownSourceSegmentInfoLLM
            row.contentHash = "abc123"
            row.cacheVersion = segmentBreakdownCacheVersion
            row.llmAudit = LLMBreakdownAuditPayload(sourceTableIndex: 1, periodColumn: "当期", unit: "million_yen", profitDisclosed: true, notes: "test")
            try await row.create(on: app.db)

            let found = try #require(try await CompanySegmentBreakdown.find("S100XTLJ#business", on: app.db))
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
            let row = CompanySegmentBreakdown(docID: "S100VXJA", axis: "business")
            row.code = "2802"
            row.submitDateTime = "2025-03-31 00:00"
            row.payload = fakeSnapshot(sourceKind: "xbrl_facts")
            row.needsReview = false
            row.source = segmentBreakdownSourceXbrlFacts
            row.contentHash = "def456"
            row.cacheVersion = segmentBreakdownCacheVersion
            row.llmAudit = nil
            try await row.create(on: app.db)

            let found = try #require(try await CompanySegmentBreakdown.find("S100VXJA#business", on: app.db))
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
            let business = CompanySegmentBreakdown(docID: "S100W043", axis: "business")
            business.code = "6103"
            business.submitDateTime = "2025-06-20 00:00"
            business.payload = fakeSnapshot(axis: "business", sourceKind: "revenue_recognition")
            business.needsReview = false
            business.source = segmentBreakdownSourceRevenueRecognitionLLM
            business.contentHash = "h1"
            business.cacheVersion = segmentBreakdownCacheVersion
            try await business.create(on: app.db)

            let geography = CompanySegmentBreakdown(docID: "S100W043", axis: "geography")
            geography.code = "6103"
            geography.submitDateTime = "2025-06-20 00:00"
            geography.payload = fakeSnapshot(axis: "geography", sourceKind: "html_table")
            geography.needsReview = false
            geography.source = segmentBreakdownSourceGeographyLLM
            geography.contentHash = "h2"
            geography.cacheVersion = segmentBreakdownCacheVersion
            try await geography.create(on: app.db)

            #expect(try await CompanySegmentBreakdown.query(on: app.db).filter(\.$docID == "S100W043").count() == 2)
        }
    }

    @Test func needsReviewColumnIsQueryableWithoutTouchingPayload() async throws {
        try await withMigratedApp { app in
            let clean = CompanySegmentBreakdown(docID: "S1", axis: "business")
            clean.code = "1111"
            clean.submitDateTime = "2025-01-01 00:00"
            clean.payload = fakeSnapshot(sourceKind: "xbrl_facts", needsReview: false)
            clean.needsReview = false
            clean.source = segmentBreakdownSourceXbrlFacts
            clean.contentHash = "h1"
            clean.cacheVersion = segmentBreakdownCacheVersion
            try await clean.create(on: app.db)

            let flagged = CompanySegmentBreakdown(docID: "S2", axis: "business")
            flagged.code = "2222"
            flagged.submitDateTime = "2025-01-01 00:00"
            flagged.payload = fakeSnapshot(sourceKind: "segment_info", needsReview: true)
            flagged.needsReview = true
            flagged.source = segmentBreakdownSourceSegmentInfoLLM
            flagged.contentHash = "h2"
            flagged.cacheVersion = segmentBreakdownCacheVersion
            try await flagged.create(on: app.db)

            let needingReview = try await CompanySegmentBreakdown.query(on: app.db)
                .filter(\.$needsReview == true)
                .all()
            #expect(needingReview.map(\.docID) == ["S2"])
        }
    }
}
