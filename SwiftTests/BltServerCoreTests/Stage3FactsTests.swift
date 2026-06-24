// Stage 3 マイグレーション・JSONB round-trip の検証。
// edinet_xbrl_facts に書類単位の fact インデックスを格納し、ネストマップ（tag→ctx→fact）・
// 配列メタ・nil メタが欠落なく往復することを確認する（本番は JSONB、テストは SQLite の TEXT）。

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
        app.migrations.add(CreateEdinetXbrlFacts())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

@Suite struct Stage3FactsTests {
    @Test func factsPayloadRoundTripsNestedMapAndMeta() async throws {
        try await withMigratedApp { app in
            let payload: XbrlFactIndexPayload = [
                "NetSales": [
                    "CurrentYearDuration": XbrlFactRecord(
                        value: 1234.5, consolidation: "consolidated", unitRef: "JPY",
                        decimals: "-6", role: nil, section: "PL",
                        roles: ["r1", "r2"], sections: ["PL"], label: "売上高", sourceFile: "f.xml"),
                ],
                "TotalAssets": [
                    "CurrentYearInstant": XbrlFactRecord(value: 9999, consolidation: "consolidated"),
                ],
            ]

            let row = EdinetXbrlFacts()
            row.id = "S100ABCD"
            row.facts = payload
            row.cacheVersion = "26.6.10"
            try await row.create(on: app.db)

            let fetched = try #require(try await EdinetXbrlFacts.find("S100ABCD", on: app.db))
            #expect(fetched.facts == payload)  // ネストマップ・配列・nil まで完全一致
            #expect(fetched.cacheVersion == "26.6.10")

            let sales = try #require(fetched.facts["NetSales"]?["CurrentYearDuration"])
            #expect(sales.value == 1234.5)
            #expect(sales.roles == ["r1", "r2"])
            #expect(sales.role == nil)
        }
    }

    @Test func factsUpdateReplacesPayloadByDocID() async throws {
        try await withMigratedApp { app in
            let row = EdinetXbrlFacts()
            row.id = "S1"
            row.facts = ["A": ["c": XbrlFactRecord(value: 1, consolidation: "consolidated")]]
            row.cacheVersion = "26.6.10"
            try await row.create(on: app.db)

            // 再パース相当: 同 docID で payload とバージョンを差し替える。
            let updated = try #require(try await EdinetXbrlFacts.find("S1", on: app.db))
            updated.facts = ["B": ["c": XbrlFactRecord(value: 2, consolidation: "nonconsolidated")]]
            updated.cacheVersion = "26.7.0"
            try await updated.update(on: app.db)

            let total = try await EdinetXbrlFacts.query(on: app.db).count()
            #expect(total == 1)
            let fetched = try #require(try await EdinetXbrlFacts.find("S1", on: app.db))
            #expect(fetched.facts["A"] == nil)
            #expect(fetched.facts["B"]?["c"]?.value == 2)
            #expect(fetched.cacheVersion == "26.7.0")
        }
    }
}
