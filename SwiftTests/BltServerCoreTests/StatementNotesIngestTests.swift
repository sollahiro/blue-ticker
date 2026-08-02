// 財務諸表注記取り込みのうち、Stage 4（company_financials）が既に計算済みの値をそのまま再公開する
// 決定論 note_type 4種（発行済株式数・研究開発費・設備投資概要・自己株式取得）を検証する。
// dividends・per_share_information は実データレビュー（2026-08-02）でXBRL直接抽出
// （`StatementNotesResolver.resolveDividends`/`resolvePerShareInformation`）へ置き換え済みのため
// 対象外（`SwiftTests/BlueTickerTests/RealXbrlStatementNotesTests.swift` 参照）。
// 自前で XBRL を再抽出しないため、フェイク抽出器ではなく `CompanyFinancials` の実データ構造を
// シードし、`StatementNotesFinancialsPassthroughResolvers` が正しい値・単位で再公開するかを見る。
//
// 汎用機構（対象選定・staleness 判定・upsert・skip・purge）は `runStatementNotesIngest` に一本化されて
// おり Stage 6/7 と同型のため、その挙動は代表として research_and_development resolver 1つで検証する
// （4種すべてで同じ機構テストを繰り返さない）。各 note_type 固有の検証は「正しい値・単位で
// 再公開されるか」「Stage 4 未計算時は failed」「値が nil のときは not_applicable(not_found)」の3点。

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
        app.migrations.add(CreateCompanyFinancials())
        app.migrations.add(CreateCompanyHalfFinancials())
        app.migrations.add(AddHighWaterToCompanyFinancials())
        app.migrations.add(CreateCompanyStatementNotes())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private func seedDoc(
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

/// 財務取り込み（company_financials）へ、指定 docID の1年度分をシードする。単位は `RawData`/
/// `CalculatedData` の生の意味（EPS=円、RD/Buyback=百万円、ShOutFY=株）のまま渡す
/// （`FinancialsYear` 変換時に 内訳取り込み の `salesForDoc` と同じ百万円→円変換が起きる）。
private func seedFinancials(
    code: String, docID: String,
    eps: Double? = nil, issuedShares: Double? = nil, rdMillionYen: Double? = nil,
    buybackMillionYen: Double? = nil, db: Database
) async throws {
    var fields: [String: Any] = ["fy_end": "2025-03-31", "FinancialPeriod": "通期"]
    var raw: [String: Any] = [:]
    if let eps { raw["EPS"] = eps }
    if let issuedShares { raw["ShOutFY"] = issuedShares }
    if let rdMillionYen { raw["RD"] = rdMillionYen }
    if let buybackMillionYen { raw["Buyback"] = buybackMillionYen }
    fields["RawData"] = raw
    let calc: [String: Any] = ["DocID": docID]
    fields["CalculatedData"] = calc

    let data = try JSONSerialization.data(withJSONObject: fields)
    let newYear = try JSONDecoder().decode(YearEntry.self, from: data)

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
    let response = FinancialsResponse(code: code, name: "テスト", sector: "", market: "", result: result)
    let row = CompanyFinancials()
    row.id = code
    row.response = response
    row.cacheVersion = companyFinancialsCacheVersion
    row.requestedYears = 6
    try await row.create(on: db)
}

@Suite struct StatementNotesIngestTests {

    // MARK: - note_type 別: 正しい値・単位の再公開

    @Test func issuedSharesRepublishesShareCountFromFinancials() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedFinancials(code: "7203", docID: "S1", issuedShares: 3_000_000, db: app.db)

            let summary = try await runStatementNotesIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                noteType: statementNoteTypeIssuedShares,
                resolve: StatementNotesFinancialsPassthroughResolvers.issuedShares(db: app.db))

            #expect(summary.stored == 1)
            let key = CompanyStatementNote.compositeID(docID: "S1", noteType: statementNoteTypeIssuedShares)
            let row = try #require(try await CompanyStatementNote.find(key, on: app.db))
            #expect(row.payload.value == 3_000_000)
            #expect(row.payload.unit == "shares")
        }
    }

    @Test func researchAndDevelopmentConvertsMillionYenToYen() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedFinancials(code: "7203", docID: "S1", rdMillionYen: 500, db: app.db)

            let summary = try await runStatementNotesIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                noteType: statementNoteTypeResearchAndDevelopment,
                resolve: StatementNotesFinancialsPassthroughResolvers.researchAndDevelopment(db: app.db))

            #expect(summary.stored == 1)
            let key = CompanyStatementNote.compositeID(
                docID: "S1", noteType: statementNoteTypeResearchAndDevelopment)
            let row = try #require(try await CompanyStatementNote.find(key, on: app.db))
            #expect(row.payload.value == 500 * Financial.millionYen)
            #expect(row.payload.unit == "yen")
        }
    }

    @Test func treasuryStockAcquisitionConvertsMillionYenToYen() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedFinancials(code: "7203", docID: "S1", buybackMillionYen: 300, db: app.db)

            let summary = try await runStatementNotesIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                noteType: statementNoteTypeTreasuryStockAcquisition,
                resolve: StatementNotesFinancialsPassthroughResolvers.treasuryStockAcquisition(db: app.db))

            #expect(summary.stored == 1)
            let key = CompanyStatementNote.compositeID(
                docID: "S1", noteType: statementNoteTypeTreasuryStockAcquisition)
            let row = try #require(try await CompanyStatementNote.find(key, on: app.db))
            #expect(row.payload.value == 300 * Financial.millionYen)
        }
    }

    // MARK: - 異常系: Stage 4 未計算 / 値なし

    @Test func ingestFailsWithoutStoringWhenStage4HasNotComputedDocYet() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            // company_financials 行を一切シードしない（Stage 4 未計算）。

            let summary = try await runStatementNotesIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                noteType: statementNoteTypeResearchAndDevelopment,
                resolve: StatementNotesFinancialsPassthroughResolvers.researchAndDevelopment(db: app.db))

            #expect(summary.attempted == 1)
            #expect(summary.failed == 1)
            #expect(summary.stored == 0)
            #expect(try await CompanyStatementNote.query(on: app.db).count() == 0)
        }
    }

    @Test func ingestWritesNotApplicableWhenStage4HasDocButValueIsNil() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            // Stage 4 は当該 docID を計算済みだが自己株式取得なし（buybackMillionYen 省略）。
            try await seedFinancials(code: "7203", docID: "S1", eps: 100, db: app.db)

            let summary = try await runStatementNotesIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                noteType: statementNoteTypeTreasuryStockAcquisition,
                resolve: StatementNotesFinancialsPassthroughResolvers.treasuryStockAcquisition(db: app.db))

            #expect(summary.notApplicable == 1)
            let key = CompanyStatementNote.compositeID(
                docID: "S1", noteType: statementNoteTypeTreasuryStockAcquisition)
            let row = try #require(try await CompanyStatementNote.find(key, on: app.db))
            #expect(row.source == statementNoteSourceNotApplicable)
            #expect(row.notApplicableReason == statementNoteNotApplicableNotFound)
            #expect(row.needsReview == false)
        }
    }

    // MARK: - 汎用機構（代表として research_and_development resolver で検証、Stage 6/7 と同型）
    //
    // per_share_information はXBRL直接抽出（`StatementNotesResolver.resolvePerShareInformation`）へ
    // 置き換え済みのため、Stage4単一値passthroughのままの research_and_development を代表に使う
    // （2026-08-02、`SwiftTests/BlueTickerTests/RealXbrlStatementNotesTests.swift` にgolden回帰あり）。

    @Test func ingestSkipsWhenStoredAtCurrentVersion() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedFinancials(code: "7203", docID: "S1", rdMillionYen: 100, db: app.db)
            let pre = CompanyStatementNote(docID: "S1", noteType: statementNoteTypeResearchAndDevelopment)
            pre.code = "7203"
            pre.submitDateTime = "2025-06-20 09:00"
            pre.payload = StatementNotePayload(value: 100 * Financial.millionYen, unit: "yen")
            pre.needsReview = false
            pre.source = statementNoteSourceXbrlFacts
            pre.contentHash = "\(100 * Financial.millionYen)"
            pre.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypeResearchAndDevelopment)
            try await pre.create(on: app.db)

            let summary = try await runStatementNotesIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                noteType: statementNoteTypeResearchAndDevelopment
            ) { _, _ in
                Issue.record("resolver must not run for an up-to-date document")
                return .failed
            }

            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
        }
    }

    @Test func ingestReattemptsXbrlFactsRowWhenVersionStale() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "72030", db: app.db)
            try await seedFinancials(code: "7203", docID: "S1", rdMillionYen: 200, db: app.db)
            let stale = CompanyStatementNote(docID: "S1", noteType: statementNoteTypeResearchAndDevelopment)
            stale.code = "7203"
            stale.submitDateTime = "2025-06-20 09:00"
            stale.payload = StatementNotePayload(value: 100 * Financial.millionYen, unit: "yen")
            stale.needsReview = false
            stale.source = statementNoteSourceXbrlFacts
            stale.contentHash = "\(100 * Financial.millionYen)"
            stale.cacheVersion = "notes-rd-v0"
            try await stale.create(on: app.db)

            let summary = try await runStatementNotesIngest(
                db: app.db, listedCodes: ["7203"], years: 3, limit: nil,
                noteType: statementNoteTypeResearchAndDevelopment,
                resolve: StatementNotesFinancialsPassthroughResolvers.researchAndDevelopment(db: app.db))

            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let key = CompanyStatementNote.compositeID(
                docID: "S1", noteType: statementNoteTypeResearchAndDevelopment)
            let row = try #require(try await CompanyStatementNote.find(key, on: app.db))
            #expect(row.payload.value == 200 * Financial.millionYen)
            #expect(
                row.cacheVersion == statementNoteCacheVersion(forType: statementNoteTypeResearchAndDevelopment))
        }
    }

    // MARK: - read 経路（loadStoredStatementNote）

    @Test func loadByCodeReturnsLatestDocument() async throws {
        try await withMigratedApp { app in
            let old = CompanyStatementNote(docID: "S24", noteType: statementNoteTypePerShareInformation)
            old.code = "7203"
            old.submitDateTime = "2024-06-20 09:00"
            old.payload = StatementNotePayload(value: 90, unit: "yen_per_share")
            old.needsReview = false
            old.source = statementNoteSourceXbrlFacts
            old.contentHash = "90.0"
            old.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypePerShareInformation)
            try await old.create(on: app.db)

            let latest = CompanyStatementNote(docID: "S25", noteType: statementNoteTypePerShareInformation)
            latest.code = "7203"
            latest.submitDateTime = "2025-06-20 09:00"
            latest.payload = StatementNotePayload(value: 123.45, unit: "yen_per_share")
            latest.needsReview = false
            latest.source = statementNoteSourceXbrlFacts
            latest.contentHash = "123.45"
            latest.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypePerShareInformation)
            try await latest.create(on: app.db)

            let result = try await loadStoredStatementNote(
                code: "7203", docId: nil, noteType: statementNoteTypePerShareInformation, db: app.db)
            guard case .found(let json) = result else {
                Issue.record("expected .found, got \(result)")
                return
            }
            #expect(json["doc_id"] as? String == "S25")
            #expect(json["code"] as? String == "7203")
            #expect(json["note_type"] as? String == statementNoteTypePerShareInformation)
            let note = try #require(json["note"] as? [String: Any])
            #expect(note["value"] as? Double == 123.45)
        }
    }

    @Test func loadByDocIdReturnsThatDocument() async throws {
        try await withMigratedApp { app in
            let row = CompanyStatementNote(docID: "S1", noteType: statementNoteTypePerShareInformation)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = StatementNotePayload(value: 100, unit: "yen_per_share")
            row.needsReview = false
            row.source = statementNoteSourceXbrlFacts
            row.contentHash = "100.0"
            row.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypePerShareInformation)
            try await row.create(on: app.db)

            let result = try await loadStoredStatementNote(
                code: "7203", docId: "S1", noteType: statementNoteTypePerShareInformation, db: app.db)
            guard case .found(let json) = result else {
                Issue.record("expected .found, got \(result)")
                return
            }
            #expect(json["doc_id"] as? String == "S1")
        }
    }

    @Test func loadByDocIdRejectsMismatchedCode() async throws {
        try await withMigratedApp { app in
            let row = CompanyStatementNote(docID: "S1", noteType: statementNoteTypePerShareInformation)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = StatementNotePayload(value: 100, unit: "yen_per_share")
            row.needsReview = false
            row.source = statementNoteSourceXbrlFacts
            row.contentHash = "100.0"
            row.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypePerShareInformation)
            try await row.create(on: app.db)

            let result = try await loadStoredStatementNote(
                code: "6758", docId: "S1", noteType: statementNoteTypePerShareInformation, db: app.db)
            guard case .absent = result else {
                Issue.record("expected .absent, got \(result)")
                return
            }
        }
    }

    /// 未知の note_type は行の有無に関わらず absent（将来 note_type 追加時の安全側デフォルト）。
    @Test func loadRejectsUnknownNoteType() async throws {
        try await withMigratedApp { app in
            let row = CompanyStatementNote(docID: "S1", noteType: statementNoteTypePerShareInformation)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = StatementNotePayload(value: 100, unit: "yen_per_share")
            row.needsReview = false
            row.source = statementNoteSourceXbrlFacts
            row.contentHash = "100.0"
            row.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypePerShareInformation)
            try await row.create(on: app.db)

            let result = try await loadStoredStatementNote(
                code: "7203", docId: nil, noteType: "unknown_note_type", db: app.db)
            guard case .absent = result else {
                Issue.record("expected .absent, got \(result)")
                return
            }
        }
    }

    @Test func loadReturnsNotApplicableReasonWhenRowIsNotApplicable() async throws {
        try await withMigratedApp { app in
            let row = CompanyStatementNote(docID: "S1", noteType: statementNoteTypeDividends)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = StatementNotePayload(needsReview: false, warnings: [])
            row.needsReview = false
            row.source = statementNoteSourceNotApplicable
            row.contentHash = ""
            row.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypeDividends)
            row.notApplicableReason = statementNoteNotApplicableNotFound
            try await row.create(on: app.db)

            let result = try await loadStoredStatementNote(
                code: "7203", docId: nil, noteType: statementNoteTypeDividends, db: app.db)
            guard case .notApplicable(let reason) = result else {
                Issue.record("expected .notApplicable, got \(result)")
                return
            }
            #expect(reason == statementNoteNotApplicableNotFound)
        }
    }

    @Test func loadReturnsAbsentWhenXbrlFactsRowBelowFloor() async throws {
        try await withMigratedApp { app in
            let row = CompanyStatementNote(docID: "S1", noteType: statementNoteTypePerShareInformation)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = StatementNotePayload(value: 100, unit: "yen_per_share")
            row.needsReview = false
            row.source = statementNoteSourceXbrlFacts
            row.contentHash = "100.0"
            row.cacheVersion = "notes-eps-v0"
            try await row.create(on: app.db)

            let result = try await loadStoredStatementNote(
                code: "7203", docId: nil, noteType: statementNoteTypePerShareInformation, db: app.db)
            guard case .absent = result else {
                Issue.record("expected .absent, got \(result)")
                return
            }
        }
    }

    // MARK: - servable/unservable 集計

    @Test func countServableStatementNotesSplitsByReadFloor() async throws {
        try await withMigratedApp { app in
            let servable = CompanyStatementNote(docID: "S1", noteType: statementNoteTypePerShareInformation)
            servable.code = "7203"
            servable.submitDateTime = "2025-06-20 09:00"
            servable.payload = StatementNotePayload(value: 100, unit: "yen_per_share")
            servable.needsReview = false
            servable.source = statementNoteSourceXbrlFacts
            servable.contentHash = "100.0"
            servable.cacheVersion = statementNoteCacheVersion(forType: statementNoteTypePerShareInformation)
            try await servable.create(on: app.db)

            let unservable = CompanyStatementNote(docID: "S2", noteType: statementNoteTypePerShareInformation)
            unservable.code = "6758"
            unservable.submitDateTime = "2025-06-20 09:00"
            unservable.payload = StatementNotePayload(value: 50, unit: "yen_per_share")
            unservable.needsReview = false
            unservable.source = statementNoteSourceXbrlFacts
            unservable.contentHash = "50.0"
            unservable.cacheVersion = "notes-eps-v0"
            try await unservable.create(on: app.db)

            let coverage = try await countServableStatementNotes(db: app.db)
            #expect(coverage.servable == 1)
            #expect(coverage.unservable == 1)
        }
    }
}
