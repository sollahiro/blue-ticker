// ingest 分類・件数の SQL 寄せが、従来の in-memory 選定と同じ集合・件数になること。
// オラクルはシードした fixture を畳む（テスト側で全表 `.all()` しない）。

import BlueTickerCore
import Fluent
import FluentSQLiteDriver
import Testing
import Vapor

@testable import BltServerCore

private func withMigratedApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateEdinetDocument())
        app.migrations.add(AddParentDocIDToEdinetDocuments())
        app.migrations.add(CreateEdinetXbrlFacts())
        app.migrations.add(CreateCompanyStatementNotes())
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

private func seedDocument(
    _ docID: String, db: Database,
    secCode: String? = "72030",
    edinetCode: String = "E00001",
    docType: String? = Api.docTypeAnnualReport,
    ordinance: String? = Api.ordinanceCompanyDisclosure,
    submit: String,
    periodEnd: String? = nil
) async throws -> DocumentListingFields {
    let model = EdinetDocument()
    model.id = docID
    model.edinetCode = edinetCode
    model.secCode = secCode
    model.filerName = "テスト株式会社"
    model.docTypeCode = docType
    model.ordinanceCode = ordinance
    model.submitDateTime = submit
    model.periodEnd = periodEnd
    try await model.create(on: db)
    return DocumentListingFields(
        id: docID, edinetCode: edinetCode, secCode: secCode, docTypeCode: docType,
        ordinanceCode: ordinance, submitDateTime: submit, periodEnd: periodEnd)
}

private func seedFacts(_ docID: String, version: String, db: Database) async throws {
    let row = EdinetXbrlFacts()
    row.id = docID
    row.facts = [
        "NetSales": ["CurrentYearDuration": XbrlFactRecord(value: 1, consolidation: "consolidated")]
    ]
    row.cacheVersion = version
    try await row.create(on: db)
}

private func packIssuer(_ row: IssuerHighWater) -> String {
    "\(row.secCode ?? "")|\(row.edinetCode)|\(row.highWater ?? "")|\(row.newestAnnual ?? "")"
}

@Suite struct IngestBookkeepingReadTests {

    @Test func factsClassifyWorklistMatchesHydrateOracleIncludingNonAnnualDocs() async throws {
        try await withMigratedApp { app in
            var fields: [DocumentListingFields] = []
            fields.append(
                try await seedDocument(
                    "MISS-NEW", db: app.db, docType: Api.docTypeAnnualReport,
                    submit: "2025-06-22 09:00"))
            fields.append(
                try await seedDocument(
                    "STALE", db: app.db, docType: "140", submit: "2025-06-21 09:00"))
            fields.append(
                try await seedDocument(
                    "FRESH", db: app.db, docType: "160", submit: "2025-06-20 09:00"))
            fields.append(
                try await seedDocument(
                    "MISS-OLD", db: app.db, secCode: "67580", edinetCode: "E00002",
                    docType: Api.docTypeAnnualReport, ordinance: "030",
                    submit: "2025-06-19 09:00"))
            try await seedFacts("STALE", version: "facts-v0", db: app.db)
            try await seedFacts("FRESH", version: xbrlFactsCacheVersion, db: app.db)

            let oracle = factsIngestClassifyWorklistFromFields(
                fields, factsByID: ["STALE": "facts-v0", "FRESH": xbrlFactsCacheVersion],
                currentVersion: xbrlFactsCacheVersion)
            let got = try await factsIngestClassifyWorklist(db: app.db)

            #expect(got.missing == oracle.missing)
            #expect(got.stale == oracle.stale)
            #expect(got.skipped == oracle.skipped)
            #expect(got.missing == ["MISS-NEW", "MISS-OLD"])
            #expect(got.stale == ["STALE"])
            #expect(got.skipped == 1)
        }
    }

    @Test func annualReportDisclosureDocsMatchInMemoryDocTypeAndOrdinanceFilter() async throws {
        try await withMigratedApp { app in
            var fields: [DocumentListingFields] = []
            fields.append(
                try await seedDocument("KEEP-120-010", db: app.db, submit: "2025-06-20 09:00"))
            fields.append(
                try await seedDocument(
                    "DROP-120-030", db: app.db, ordinance: "030", submit: "2025-06-21 09:00"))
            fields.append(
                try await seedDocument(
                    "DROP-160-010", db: app.db, docType: "160", submit: "2025-06-22 09:00"))
            fields.append(
                try await seedDocument(
                    "DROP-NIL-ORD", db: app.db, ordinance: nil, submit: "2025-06-23 09:00"))
            fields.append(
                try await seedDocument(
                    "KEEP-2", db: app.db, secCode: "67580", edinetCode: "E00002",
                    submit: "2024-06-20 09:00"))

            let oracleIDs = Set(
                annualReportDisclosureDocsFromFields(fields).compactMap(\.id))
            let got = try await annualReportDisclosureDocs(db: app.db)
            #expect(Set(got.compactMap(\.id)) == oracleIDs)
            #expect(oracleIDs == ["KEEP-120-010", "KEEP-2"])
        }
    }

    @Test func issuerHighWaterSQLMatchesFoldOracleAcrossDocTypesAndOrdinances() async throws {
        try await withMigratedApp { app in
            var fields: [DocumentListingFields] = []
            fields.append(
                try await seedDocument(
                    "A120", db: app.db, submit: "2025-06-20 09:00", periodEnd: "2025-03-31"))
            fields.append(
                try await seedDocument(
                    "A130", db: app.db, docType: "130", submit: "2025-09-18 15:00",
                    periodEnd: "2025-03-31"))
            fields.append(
                try await seedDocument(
                    "A140", db: app.db, docType: "140", submit: "2025-11-01 09:00",
                    periodEnd: "2025-09-30"))
            fields.append(
                try await seedDocument(
                    "A030", db: app.db, ordinance: "030", submit: "2026-01-01 09:00",
                    periodEnd: "2026-03-31"))
            fields.append(
                try await seedDocument(
                    "B120", db: app.db, secCode: "67580", edinetCode: "E00002",
                    submit: "2024-06-20 09:00", periodEnd: "2024-03-31"))

            let docTypes = Api.financialsFreshnessDocTypes
            let oracle = foldIssuerHighWaterRows(fields, docTypes: docTypes)
            let got = try await issuerHighWaterRows(db: app.db, docTypes: docTypes)
            #expect(Set(got.map(packIssuer)) == Set(oracle.map(packIssuer)))

            let toyota = try #require(got.first { $0.edinetCode == "E00001" })
            #expect(toyota.highWater == "2025-09-18 15:00")
            #expect(toyota.newestAnnual == "2025-03-31|A120")
        }
    }

    @Test func statementNoteClassifyRowsMatchUnscopedRowsIntersectedWithDocIDs() async throws {
        try await withMigratedApp { app in
            let note = statementNoteTypePerShareInformation
            let other = statementNoteTypeIssuedSharesAndCapital
            for (docID, code) in [("S1", "7203"), ("S2", "6758"), ("S3", "9984")] {
                let row = CompanyStatementNote(docID: docID, noteType: note)
                row.code = code
                row.submitDateTime = "2025-06-20 09:00"
                row.payload = StatementNotePayload(value: 1, unit: "yen_per_share")
                row.needsReview = docID == "S2"
                row.source = statementNoteSourceXbrlFacts
                row.contentHash = "1"
                row.cacheVersion = statementNoteCacheVersion(forType: note)
                try await row.create(on: app.db)
            }
            let extra = CompanyStatementNote(docID: "S1", noteType: other)
            extra.code = "7203"
            extra.submitDateTime = "2025-06-20 09:00"
            extra.payload = StatementNotePayload(value: 2, unit: "yen")
            extra.needsReview = false
            extra.source = statementNoteSourceXbrlFacts
            extra.contentHash = "2"
            extra.cacheVersion = statementNoteCacheVersion(forType: other)
            try await extra.create(on: app.db)

            let keep: Set<String> = ["S1", "S3"]
            let unscoped = try await CompanyStatementNoteSourceVersionOnly.query(on: app.db)
                .filter(\.$noteType == note)
                .all()
            let oracleIDs = Set(
                unscoped.filter { keep.contains($0.docID) }.compactMap(\.id))
            let got = try await statementNoteClassifyRows(
                db: app.db, noteType: note, docIDs: keep)
            #expect(Set(got.compactMap(\.id)) == oracleIDs)
            #expect(got.allSatisfy { keep.contains($0.docID) && $0.noteType == note })
            #expect(got.count == 2)
        }
    }

    @Test func statementNoteClassifyRowsEmptyDocIDsDoesNotQuery() async throws {
        try await withMigratedApp { app in
            let row = CompanyStatementNote(
                docID: "S1", noteType: statementNoteTypePerShareInformation)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = StatementNotePayload(value: 1, unit: "yen_per_share")
            row.needsReview = false
            row.source = statementNoteSourceXbrlFacts
            row.contentHash = "1"
            row.cacheVersion = statementNoteCacheVersion(
                forType: statementNoteTypePerShareInformation)
            try await row.create(on: app.db)

            let got = try await statementNoteClassifyRows(
                db: app.db, noteType: statementNoteTypePerShareInformation, docIDs: [])
            #expect(got.isEmpty)
        }
    }

    @Test func countServableStatementNotesMatchesRowOracleIncludingNeedsReviewAndLLM() async throws {
        try await withMigratedApp { app in
            func seedNote(
                _ docID: String, type: String, source: String, version: String, needsReview: Bool
            ) async throws {
                let row = CompanyStatementNote(docID: docID, noteType: type)
                row.code = "7203"
                row.submitDateTime = "2025-06-20 09:00"
                row.payload = StatementNotePayload(value: 1, unit: "yen_per_share")
                row.needsReview = needsReview
                row.source = source
                row.contentHash = "1"
                row.cacheVersion = version
                try await row.create(on: app.db)
            }
            let eps = statementNoteTypePerShareInformation
            try await seedNote(
                "S1", type: eps, source: statementNoteSourceXbrlFacts,
                version: statementNoteCacheVersion(forType: eps), needsReview: false)
            try await seedNote(
                "S2", type: eps, source: statementNoteSourceXbrlFacts,
                version: "notes-eps-v0", needsReview: false)
            try await seedNote(
                "S3", type: eps, source: statementNoteSourceLLM,
                version: "notes-eps-v0", needsReview: true)
            try await seedNote(
                "S4", type: statementNoteTypeIssuedSharesAndCapital,
                source: statementNoteSourceNotApplicable,
                version: issuedSharesAndCapitalNoteCacheVersion, needsReview: false)

            let rows = try await CompanyStatementNoteSourceVersionOnly.query(on: app.db)
                .filter(\.$noteType != "")
                .all()
            let oracle = servableCountsFromRows(
                rows, source: { $0.source }, cacheVersion: { $0.cacheVersion },
                group: { $0.noteType }
            ) { source, version, noteType in
                isServableStatementNote(source: source, cacheVersion: version, noteType: noteType)
            }
            let got = try await countServableStatementNotes(db: app.db)
            #expect(got.servable == oracle.servable)
            #expect(got.unservable == oracle.unservable)
            #expect(got.servable == 3)
            #expect(got.unservable == 1)
        }
    }

    @Test func breakdownClassifyRowsMatchUnscopedRowsIntersectedWithDocIDs() async throws {
        try await withMigratedApp { app in
            func seedBreakdown(_ docID: String, axis: String, needsReview: Bool) async throws {
                let row = CompanyBreakdown(docID: docID, axis: axis)
                row.code = "7203"
                row.submitDateTime = "2025-06-20 09:00"
                row.payload = BreakdownSnapshotPayload(
                    axis: axis, denominator: 1, denominatorTag: "t", rows: [],
                    sourceKind: "test", needsReview: needsReview, warnings: [])
                row.needsReview = needsReview
                row.source = breakdownSourceXbrlFacts
                row.contentHash = "h"
                row.cacheVersion = breakdownCacheVersion(forAxis: axis)
                try await row.create(on: app.db)
            }
            try await seedBreakdown("S1", axis: breakdownAxisProductService, needsReview: false)
            try await seedBreakdown("S2", axis: breakdownAxisProductService, needsReview: true)
            try await seedBreakdown("S3", axis: breakdownAxisProductService, needsReview: false)
            try await seedBreakdown("S1", axis: breakdownAxisGeography, needsReview: false)

            let keep: Set<String> = ["S1", "S3"]
            let unscoped = try await CompanyBreakdownSourceVersionOnly.query(on: app.db)
                .filter(\.$axis == breakdownAxisProductService)
                .all()
            let oracleIDs = Set(
                unscoped.filter { keep.contains($0.docID) }.compactMap(\.id))
            let got = try await breakdownClassifyRows(
                db: app.db, axis: breakdownAxisProductService, docIDs: keep)
            #expect(Set(got.compactMap(\.id)) == oracleIDs)
            #expect(got.allSatisfy { $0.axis == breakdownAxisProductService })
            #expect(got.count == 2)
        }
    }

    @Test func countServableBreakdownsMatchesRowOracle() async throws {
        try await withMigratedApp { app in
            func seedBreakdown(
                _ docID: String, axis: String, source: String, version: String
            ) async throws {
                let row = CompanyBreakdown(docID: docID, axis: axis)
                row.code = "7203"
                row.submitDateTime = "2025-06-20 09:00"
                row.payload = BreakdownSnapshotPayload(
                    axis: axis, denominator: 1, denominatorTag: "t", rows: [],
                    sourceKind: "test", needsReview: false, warnings: [])
                row.needsReview = false
                row.source = source
                row.contentHash = "h"
                row.cacheVersion = version
                try await row.create(on: app.db)
            }
            try await seedBreakdown(
                "S1", axis: breakdownAxisProductService, source: breakdownSourceXbrlFacts,
                version: productServiceBreakdownCacheVersion)
            try await seedBreakdown(
                "S2", axis: breakdownAxisProductService, source: breakdownSourceXbrlFacts,
                version: "breakdown-product_service-v0")
            try await seedBreakdown(
                "S3", axis: breakdownAxisGeography, source: breakdownSourceGeographyLLM,
                version: geographyBreakdownCacheVersion)
            try await seedBreakdown(
                "S4", axis: breakdownAxisGeography, source: "unknown_source",
                version: "nope")

            let rows = try await CompanyBreakdownSourceVersionOnly.query(on: app.db)
                .filter(\.$axis != "")
                .all()
            let oracle = servableCountsFromRows(
                rows, source: { $0.source }, cacheVersion: { $0.cacheVersion },
                group: { $0.axis }
            ) { source, version, axis in
                isServableBreakdown(source: source, cacheVersion: version, axis: axis)
            }
            let got = try await countServableBreakdowns(db: app.db)
            #expect(got.servable == oracle.servable)
            #expect(got.unservable == oracle.unservable)
            #expect(got.servable == 3)
            #expect(got.unservable == 1)
        }
    }
}
