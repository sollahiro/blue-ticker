// 会社アイコン取り込み マイグレーションの検証。
// インメモリ SQLite に migration を実走させ、company_icons のスキーマがモデルと整合し、
// 行が round-trip することを確認する（本番は Postgres）。

import Fluent
import FluentSQLiteDriver
import Testing
import Vapor

@testable import BltServerCore

private func withMigratedApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateCompanyIcons())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

@Suite struct CompanyIconMigrationTests {
    @Test func companyIconRoundTripsAllFieldsAndSetsFetchedAtOnCreate() async throws {
        try await withMigratedApp { app in
            let icon = CompanyIcon(
                code: "7203", sourceURL: "https://global.toyota",
                r2ObjectKey: "company-icons/7203.png", contentType: "image/png",
                cacheVersion: "icons-v1"
            )
            try await icon.create(on: app.db)

            let fetched = try #require(try await CompanyIcon.find("7203", on: app.db))
            #expect(fetched.sourceURL == "https://global.toyota")
            #expect(fetched.r2ObjectKey == "company-icons/7203.png")
            #expect(fetched.contentType == "image/png")
            #expect(fetched.cacheVersion == "icons-v1")
            #expect(fetched.fetchedAt != nil)
        }
    }

    @Test func companyIconUpdateRefreshesFetchedAt() async throws {
        try await withMigratedApp { app in
            let icon = CompanyIcon(
                code: "6758", sourceURL: "https://www.sony.com",
                r2ObjectKey: "company-icons/6758.png", contentType: "image/png",
                cacheVersion: "icons-v1"
            )
            try await icon.create(on: app.db)
            let firstFetchedAt = try #require(icon.fetchedAt)

            icon.cacheVersion = "icons-v2"
            try await icon.update(on: app.db)

            let fetched = try #require(try await CompanyIcon.find("6758", on: app.db))
            #expect(fetched.cacheVersion == "icons-v2")
            #expect(try #require(fetched.fetchedAt) >= firstFetchedAt)
        }
    }
}
