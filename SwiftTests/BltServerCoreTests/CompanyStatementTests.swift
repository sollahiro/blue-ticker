// Stage 7 の永続化スキーマ（company_statements）が意図どおり動くかを検証する。
// docs/statement-normalization-concept.md「実装方針」参照。モデル・マイグレーションのみを見る
// （ingest/read の実配線の検証は Stage7IngestTests.swift）。

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
        app.migrations.add(CreateCompanyStatements())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private func fakeYear(docID: String) -> StatementYear {
    StatementYear(
        fyEnd: "2025-03-31", financialPeriod: "通期", docId: docID,
        balanceSheet: [
            StatementLineItem(tag: "TotalAssets", label: "資産合計", value: 4_624_727, unit: "JPY", order: nil)
        ],
        incomeStatement: [
            StatementLineItem(tag: "NetSales", label: "売上高", value: 1_000_000, unit: "JPY", order: nil)
        ],
        cashFlow: [])
}

@Suite struct CompanyStatementTests {

    @Test func createAndFindRoundTripsPayload() async throws {
        try await withMigratedApp { app in
            let row = CompanyStatement()
            row.id = "S100XTLJ"
            row.code = "7203"
            row.submitDateTime = "2026-03-25 00:00"
            row.payload = fakeYear(docID: "S100XTLJ")
            row.cacheVersion = statementCacheVersion
            try await row.create(on: app.db)

            let found = try #require(try await CompanyStatement.find("S100XTLJ", on: app.db))
            #expect(found.code == "7203")
            #expect(found.cacheVersion == statementCacheVersion)
            #expect(found.payload.balanceSheet.count == 1)
            #expect(found.payload.balanceSheet[0].tag == "TotalAssets")
            #expect(found.payload.incomeStatement[0].value == 1_000_000)
            #expect(found.payload.cashFlow.isEmpty)
        }
    }

    @Test func docIDIsThePrimaryKey() async throws {
        try await withMigratedApp { app in
            let row = CompanyStatement()
            row.id = "S1"
            row.code = "7203"
            row.submitDateTime = "2025-01-01 00:00"
            row.payload = fakeYear(docID: "S1")
            row.cacheVersion = statementCacheVersion
            try await row.create(on: app.db)

            // 同一 docID の2件目 create は PK 制約違反で throw する（合成キーではなく docID 単独が主キー）。
            let duplicate = CompanyStatement()
            duplicate.id = "S1"
            duplicate.code = "9999"
            duplicate.submitDateTime = "2025-01-01 00:00"
            duplicate.payload = fakeYear(docID: "S1")
            duplicate.cacheVersion = statementCacheVersion
            await #expect(throws: (any Error).self) {
                try await duplicate.create(on: app.db)
            }
        }
    }

    @Test func multipleDocsForSameCodeCoexist() async throws {
        try await withMigratedApp { app in
            for docID in ["S1", "S2", "S3"] {
                let row = CompanyStatement()
                row.id = docID
                row.code = "7203"
                row.submitDateTime = "2025-01-01 00:00"
                row.payload = fakeYear(docID: docID)
                row.cacheVersion = statementCacheVersion
                try await row.create(on: app.db)
            }

            let count = try await CompanyStatement.query(on: app.db).filter(\.$code == "7203").count()
            #expect(count == 3)
        }
    }
}
