// 手動 XBRL 上書きテーブルのマイグレーションと CLI ストア（インメモリ SQLite）。

import BlueTickerCore
import Fluent
import FluentSQLiteDriver
import Testing
import Vapor

@testable import BltServerCore

private func withOverrideApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateEdinetDocument())
        app.migrations.add(AddParentDocIDToEdinetDocuments())
        app.migrations.add(CreateCompanyFinancials())
        app.migrations.add(CreateCompanyHalfFinancials())
        app.migrations.add(AddHighWaterToCompanyFinancials())
        app.migrations.add(AddAssemblyFingerprintToCompanyFinancials())
        app.migrations.add(CreateCompanyStatementNotes())
        app.migrations.add(CreateManualXbrlOverrides())
        app.migrations.add(RestrictManualXbrlOverridesToCapex())
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private func sampleCapexRecord() -> ManualXbrlOverrideRecord {
    ManualXbrlOverrideRecord(
        edinetCode: "E03614", periodEnd: "2025-03-31", item: .capex,
        payload: .capex(CapexManualOverridePayload(value: 370_500, unit: "JPY", scale: 6)),
        sourceDocID: "S100WRZH", sourcePage: "設備の状況", reason: "decimals -6 vs 億円",
        createdBy: "sorahiro")
}

@Suite struct ManualXbrlOverrideMigrationTests {
    @Test func roundTripsActiveRowAndPartialUnique() async throws {
        try await withOverrideApp { app in
            let record = sampleCapexRecord()
            let row = try await insertManualXbrlOverride(record, on: app.db)
            #expect(row.id != nil)
            let loaded = try await loadActiveManualXbrlOverrides(on: app.db)
            #expect(loaded.count == 1)
            #expect(loaded[0].edinetCode == "E03614")
            guard case .capex(let capex) = loaded[0].payload else {
                Issue.record("expected capex")
                return
            }
            #expect(capex.millionYen == 370_500)

            do {
                _ = try await insertManualXbrlOverride(record, on: app.db)
                Issue.record("second active insert must fail")
            } catch ManualXbrlOverrideCommandError.activeExists {
            }

            let revoked = try await revokeManualXbrlOverride(id: try #require(row.id), on: app.db)
            #expect(revoked.revokedAt != nil)
            #expect(try await loadActiveManualXbrlOverrides(on: app.db).isEmpty)

            let replaced = try await insertManualXbrlOverride(record, on: app.db)
            #expect(replaced.id != row.id)
            #expect(try await loadActiveManualXbrlOverrides(on: app.db).count == 1)
        }
    }

    @Test func dryRunDiffReadsCurrentFinancialsWithoutWriting() async throws {
        try await withOverrideApp { app in
            let doc = EdinetDocument()
            doc.id = "S100W0S7"
            doc.edinetCode = "E03614"
            doc.secCode = "83160"
            doc.filerName = "SMFG"
            doc.docTypeCode = Api.docTypeAnnualReport
            doc.periodEnd = "2025-03-31"
            doc.submitDateTime = "2025-06-20 09:00"
            try await doc.create(on: app.db)

            let dict: [String: Any] = [
                "schema_version": 2, "code": "8316", "name": "SMFG",
                "sector": "", "market": "", "currency": "JPY", "unit": "百万円",
                "years": [["fy_end": "2025-03-31", "capex": 3705.0]],
            ]
            let data = try JSONSerialization.data(withJSONObject: dict)
            let response = try JSONDecoder().decode(FinancialsResponse.self, from: data)
            let fin = CompanyFinancials()
            fin.id = "8316"
            fin.response = response
            fin.cacheVersion = companyFinancialsCacheVersion
            fin.requestedYears = 1
            try await fin.create(on: app.db)

            let record = sampleCapexRecord()
            let diff = try await manualXbrlOverrideDiff(record: record, on: app.db)
            #expect(diff["current_capex_million_yen"] as? Double == 3_705)
            #expect(diff["override_capex_million_yen"] as? Double == 370_500)
            #expect(try await loadActiveManualXbrlOverrides(on: app.db).isEmpty)
        }
    }
}
