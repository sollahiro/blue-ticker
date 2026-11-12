// つなぎの ingest（company_segment_transitions）と年次応答が、同じ「前年」を見ること。
// 同じ決算期の書類が 2 つある会社でも、前年とのつなぎを消さない。

import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import Vapor

@testable import BltIngestCore
@testable import BltStoreCore
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
        app.migrations.add(CreateCompanySegmentTransitions())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private func segmentRow(_ local: String, value: Double) -> BreakdownRowPayload {
    var row = BreakdownRowPayload(
        labelRaw: local, label: local, amount: value, profit: nil, rowKind: "segment")
    row.segmentKey = "E00001:ext:\(local)"
    row.externalSales = BreakdownMetricCellPayload(
        value: value, basis: breakdownSourceXbrlFacts, source: "NetSales", decimals: -6)
    return row
}

private func seedYear(
    docID: String, periodEnd: String, submit: String, rows: [BreakdownRowPayload], db: Database
) async throws {
    let doc = EdinetDocument()
    doc.id = docID
    doc.edinetCode = "E00001"
    doc.secCode = "12340"
    doc.filerName = "テスト株式会社"
    doc.docTypeCode = Api.docTypeAnnualReport
    doc.ordinanceCode = Api.ordinanceCompanyDisclosure
    doc.formCode = "030000"
    doc.submitDateTime = submit
    doc.periodEnd = periodEnd
    try await doc.create(on: db)

    let row = CompanyBreakdown(docID: docID, axis: breakdownAxisSegment)
    row.code = "1234"
    row.submitDateTime = submit
    row.payload = BreakdownSnapshotPayload(
        axis: breakdownAxisSegment, denominator: 1, denominatorTag: "NetSales", rows: rows,
        sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
    row.needsReview = false
    row.source = breakdownSourceXbrlFacts
    row.contentHash = "h"
    row.cacheVersion = segmentBreakdownCacheVersion
    try await row.create(on: db)
}

@Suite struct SegmentTransitionIngestTests {
    @Test func twoFilingsForOnePeriodKeepThePriorYearLink() async throws {
        try await withMigratedApp { app in
            let db = app.db
            // 2025/3 期: A と Old。2026/3 期: A と New（Old が消えて New が出た）。
            // 2026/3 期は同じ決算期で 2 書類（後から出した方が採用される）。
            try await seedYear(
                docID: "S2025", periodEnd: "2025-03-31", submit: "2025-06-20 09:00",
                rows: [segmentRow("AMember", value: 10_000_000), segmentRow("OldMember", value: 5_000_000)], db: db)
            try await seedYear(
                docID: "S2026a", periodEnd: "2026-03-31", submit: "2026-06-20 09:00",
                rows: [segmentRow("AMember", value: 11_000_000), segmentRow("NewMember", value: 6_000_000)], db: db)
            try await seedYear(
                docID: "S2026b", periodEnd: "2026-03-31", submit: "2026-07-01 09:00",
                rows: [segmentRow("AMember", value: 12_000_000), segmentRow("NewMember", value: 6_000_000)], db: db)

            try await runSegmentTransitionIngest(db: db, listedCodes: ["1234"])

            let stored = try await CompanySegmentTransition.query(on: db).all()
            #expect(Set(stored.map(\.fyEnd)) == ["2026-03-31"])
            #expect(
                Set(stored.map { "\($0.oldKey ?? "-")>\($0.newKey ?? "-")" }) == [
                    "E00001:ext:OldMember>-", "->E00001:ext:NewMember",
                ])

            guard
                case .found(let object) = try await loadStoredSegmentWaterfall(
                    code: "1234", metric: segmentWaterfallMetricExternalSales, key: nil, years: 5,
                    fiscalYear: nil, db: db)
            else {
                Issue.record("年次応答が無い")
                return
            }
            let years = try #require(object["years"] as? [[String: Any]])
            #expect(years.map { $0["doc_id"] as? String } == ["S2026b", "S2025"])
            // Old が消えて New が出たので、この年は折れ線を切る。
            #expect(years[0][segmentWaterfallLineCutKey] as? Bool == true)

            // 同じ内容でもう一度回しても行は書き直さない（id と件数が同じ）。
            try await runSegmentTransitionIngest(db: db, listedCodes: ["1234"])
            let again = try await CompanySegmentTransition.query(on: db).all()
            #expect(again.count == stored.count)
        }
    }
}
