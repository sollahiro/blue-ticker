// 関係取り込み（stage `relations`）の DB ロジック（対象選定・skip 判定・会社単位の差し替え・
// 書き込み時の名前解決・子会社索引・unresolved / ambiguous だけの解き直し）を検証する。
// 抽出はフェイクを注入してネットワーク非依存で見る。

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
        app.migrations.add(CreateCompanyRelations())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private func seedDoc(_ docID: String, secCode: String, submit: String = "2026-06-20 09:00", db: Database)
    async throws
{
    let model = EdinetDocument()
    model.id = docID
    model.edinetCode = "E00001"
    model.secCode = secCode
    model.filerName = "テスト株式会社"
    model.docTypeCode = Api.docTypeAnnualReport
    model.ordinanceCode = Api.ordinanceCompanyDisclosure
    model.formCode = "030000"
    model.submitDateTime = submit
    try await model.create(on: db)
}

private let directory = RelationNameDirectory(filers: [
    EdinetFilerName(edinetCode: "E04760", name: "株式会社電通グループ", nameEn: "DENTSU GROUP INC.", listedCode: "4324"),
    EdinetFilerName(edinetCode: "E01952", name: "株式会社大真空", nameEn: "DAISHINKU CORP.", listedCode: "6962"),
])

private func extraction(_ rows: [CompanyRelationDraft], warnings: [String] = []) -> CompanyRelationsResolveResult {
    .extracted(CompanyRelationsExtraction(rows: rows, fyEnd: "2026-03-31", warnings: warnings))
}

private func customer(_ name: String, position: Int = 0) -> CompanyRelationDraft {
    CompanyRelationDraft(section: relationSectionMainCustomers, kind: relationKindCustomer, position: position, nameRaw: name)
}

private func subsidiary(_ name: String) -> CompanyRelationDraft {
    CompanyRelationDraft(section: relationSectionAffiliatedEntities, kind: relationKindSubsidiary, position: 0, nameRaw: name)
}

private func rows(_ code: String, _ db: Database) async throws -> [CompanyRelation] {
    try await CompanyRelation.query(on: db).filter(\.$code == code).sort(\.$position).all()
}

@Suite struct RelationsIngestTests {

    @Test func storesRowsAndResolvesNames() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S6384", secCode: "63840", db: app.db)
            let summary = try await runRelationsIngest(
                db: app.db, listedCodes: ["6384"], limit: nil, directory: directory
            ) { _, _ in
                extraction([customer("株式会社大真空"), customer("Largan Precision Co.,Ltd.", position: 1)])
            }
            #expect(summary.attempted == 1)
            #expect(summary.stored == 1)
            let stored = try await rows("6384", app.db)
            #expect(stored.map(\.relatedCode) == ["6962", nil])
            #expect(stored.map(\.resolution) == [relationResolutionNameExact, relationResolutionUnresolved])
            #expect(stored.allSatisfy { $0.docID == "S6384" && $0.cacheVersion == companyRelationsCacheVersion })
        }
    }

    @Test func skipsSameDocAndReplacesOnNewDoc() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S_OLD", secCode: "63840", submit: "2025-06-20 09:00", db: app.db)
            _ = try await runRelationsIngest(
                db: app.db, listedCodes: ["6384"], limit: nil, directory: directory
            ) { _, _ in extraction([customer("旧顧客"), customer("旧顧客2", position: 1)]) }
            let again = try await runRelationsIngest(
                db: app.db, listedCodes: ["6384"], limit: nil, directory: directory
            ) { _, _ in extraction([customer("呼ばれない")]) }
            #expect(again.skipped == 1)
            #expect(again.attempted == 0)

            try await seedDoc("S_NEW", secCode: "63840", submit: "2026-06-20 09:00", db: app.db)
            let replaced = try await runRelationsIngest(
                db: app.db, listedCodes: ["6384"], limit: nil, directory: directory
            ) { _, _ in extraction([customer("新顧客")]) }
            #expect(replaced.stored == 1)
            let stored = try await rows("6384", app.db)
            #expect(stored.map(\.nameRaw) == ["新顧客"])
            #expect(stored.map(\.docID) == ["S_NEW"])
        }
    }

    @Test func failedExtractionWritesNothing() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "63840", db: app.db)
            let summary = try await runRelationsIngest(
                db: app.db, listedCodes: ["6384"], limit: nil, directory: directory
            ) { _, _ in .failed }
            #expect(summary.failed == 1)
            #expect(try await rows("6384", app.db).isEmpty)
        }
    }

    @Test func subsidiaryIndexLinksCustomerViaListedParentAndReresolves() async throws {
        try await withMigratedApp { app in
            // 先に顧客側（9409）だけを取り込む → ㈱電通は unresolved。
            try await seedDoc("S9409", secCode: "94090", db: app.db)
            _ = try await runRelationsIngest(
                db: app.db, listedCodes: ["9409"], limit: nil, directory: directory
            ) { _, _ in extraction([customer("㈱電通")]) }
            #expect(try await rows("9409", app.db).first?.resolution == relationResolutionUnresolved)

            // 親（4324）の関係会社表に ㈱電通 が載ると、9409 の行が解き直される。
            try await seedDoc("S4324", secCode: "43240", db: app.db)
            let summary = try await runRelationsIngest(
                db: app.db, listedCodes: ["9409", "4324"], limit: nil, directory: directory
            ) { _, code in code == "4324" ? extraction([subsidiary("株式会社電通")]) : extraction([customer("呼ばれない")]) }
            #expect(summary.reresolved == 1)
            let customerRow = try #require(try await rows("9409", app.db).first)
            #expect(customerRow.relatedCode == "4324")
            #expect(customerRow.resolution == relationResolutionViaListedParent)
        }
    }

    @Test func directoryChangeReresolvesStoredRows() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S6384", secCode: "63840", db: app.db)
            let before = RelationNameDirectory(filers: [
                EdinetFilerName(edinetCode: "E01952", name: "株式会社大真空", nameEn: "", listedCode: nil)
            ])
            _ = try await runRelationsIngest(
                db: app.db, listedCodes: ["6384"], limit: nil, directory: before
            ) { _, _ in extraction([customer("株式会社大真空")]) }
            #expect(try await rows("6384", app.db).first?.resolution == relationResolutionEdinetUnlisted)

            // コードリストが更新されて上場になった → 同じ書類のまま（skip）でも解き直される。
            let summary = try await runRelationsIngest(
                db: app.db, listedCodes: ["6384"], limit: nil, directory: directory
            ) { _, _ in extraction([customer("呼ばれない")]) }
            #expect(summary.skipped == 1)
            #expect(summary.reresolved == 1)
            let row = try #require(try await rows("6384", app.db).first)
            #expect(row.relatedCode == "6962")
            #expect(row.resolverKey == directory.fingerprint)

            // 名簿が同じなら何も書かない。
            let again = try await runRelationsIngest(
                db: app.db, listedCodes: ["6384"], limit: nil, directory: directory
            ) { _, _ in extraction([customer("呼ばれない")]) }
            #expect(again.reresolved == 0)
        }
    }

    @Test func overlayRegressionSubsidiaryRowsAreNotIndexed() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S9409", secCode: "94090", db: app.db)
            try await seedDoc("S4324", secCode: "43240", db: app.db)
            _ = try await runRelationsIngest(
                db: app.db, listedCodes: ["9409", "4324"], limit: nil, directory: directory
            ) { _, code in
                code == "4324"
                    ? extraction([subsidiary("株式会社電通")], warnings: ["overlay_regression:x:S2:orig=S4324"])
                    : extraction([customer("㈱電通")])
            }
            #expect(try await rows("9409", app.db).first?.relatedCode == nil)
        }
    }

    @Test func jevPendingIsNotRetriedWithoutDecider() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "11110", db: app.db)
            let pending = CompanyRelationDraft(
                section: relationSectionAffiliatedEntities, kind: relationKindUnclassified, position: 0,
                nameRaw: "株式会社保留", decidedBy: relationDecidedByJev, needsReview: true)
            _ = try await runRelationsIngest(
                db: app.db, listedCodes: ["1111"], limit: nil, directory: directory
            ) { _, _ in extraction([pending]) }
            let summary = try await runRelationsIngest(
                db: app.db, listedCodes: ["1111"], limit: nil, retryJevPending: false, directory: directory
            ) { _, _ in extraction([subsidiary("株式会社保留")]) }
            #expect(summary.attempted == 0)
            #expect(summary.skipped == 1)
        }
    }

    @Test func omittedSectionIsStoredAsStatusRow() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "11110", db: app.db)
            _ = try await runRelationsIngest(
                db: app.db, listedCodes: ["1111"], limit: nil, directory: directory
            ) { _, _ in
                extraction([.status(section: relationSectionMainCustomers, relationSectionStatusOmitted)])
            }
            let row = try #require(try await rows("1111", app.db).first)
            #expect(row.kind == relationKindNone)
            #expect(row.sectionStatus == relationSectionStatusOmitted)
            #expect(row.resolution == nil)
        }
    }

    @Test func jevPendingRowsAreRetriedOnSameDoc() async throws {
        try await withMigratedApp { app in
            try await seedDoc("S1", secCode: "11110", db: app.db)
            let pending = CompanyRelationDraft(
                section: relationSectionAffiliatedEntities, kind: relationKindUnclassified, position: 0,
                nameRaw: "株式会社保留", decidedBy: relationDecidedByJev, needsReview: true)
            _ = try await runRelationsIngest(
                db: app.db, listedCodes: ["1111"], limit: nil, directory: directory
            ) { _, _ in extraction([pending]) }
            #expect(try await rows("1111", app.db).first?.needsReview == true)
            let retry = try await runRelationsIngest(
                db: app.db, listedCodes: ["1111"], limit: nil, directory: directory
            ) { _, _ in extraction([subsidiary("株式会社保留")]) }
            #expect(retry.attempted == 1)
            #expect(try await rows("1111", app.db).first?.kind == relationKindSubsidiary)
        }
    }

    @Test func migrationRoundTripsAllColumns() async throws {
        try await withMigratedApp { app in
            let draft = CompanyRelationDraft(
                section: relationSectionMajorShareholders, kind: relationKindMajorShareholder, position: 0,
                nameRaw: "日本マスタートラスト信託銀行株式会社", shares: 1000, ratio: 0.128, rank: 1,
                address: "東京都港区")
            let row = CompanyRelation(
                code: "7203", docID: "S100Y8NY", submitDateTime: "2026-06-20 09:00", fyEnd: "2026-03-31",
                draft: draft, warning: nil)
            try await row.create(on: app.db)
            let fetched = try #require(try await rows("7203", app.db).first)
            #expect(fetched.rank == 1)
            #expect(fetched.ratio == 0.128)
            #expect(fetched.address == "東京都港区")
            #expect(fetched.nameNorm == "日本マスタートラスト信託銀行")
        }
    }
}
