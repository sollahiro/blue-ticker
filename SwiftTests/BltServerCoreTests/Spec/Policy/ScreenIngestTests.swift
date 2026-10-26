// Screen（screen_index）の派生更新・rebuild・read 経路（GET /v1/screen）を
// インメモリ SQLite で検証する（BLT-49）。

import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import Vapor

@testable import BlueTickerCore
@testable import BltServerCore
@testable import BltStoreCore
@testable import BltIngestCore

private func makeContext() -> BltServerContext {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("blt-screen-tests-\(UUID().uuidString)", isDirectory: true)
    return BltServerContext(
        apiKey: "test-key", cacheDir: dir)
}

private func withApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateEdinetDocument())
        app.migrations.add(AddParentDocIDToEdinetDocuments())
        app.migrations.add(CreateCompanyFinancials())
        app.migrations.add(CreateCompanyHalfFinancials())
        app.migrations.add(AddHighWaterToCompanyFinancials())
        app.migrations.add(AddAssemblyFingerprintToCompanyFinancials())
        app.migrations.add(AddLlmAuditToCompanyFinancials())
        app.migrations.add(CreateScreenIndex())
        app.migrations.add(ReplaceScreenIndexGrowthWithCagr())
        app.migrations.add(AddCacheVersionToScreenIndex())
        app.migrations.add(AddScreenV3MetricsToScreenIndex())
        app.migrations.add(AddScreenCagrMetricsToScreenIndex())
        app.migrations.add(AddScreenPayoutRatio3yToScreenIndex())
        try await app.autoMigrate()
        try await registerRoutes(app, context: makeContext())
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private func send(_ app: Application, _ path: String) async throws -> (HTTPResponseStatus, [String: Any]?) {
    let request = Request(
        application: app, method: .GET, url: URI(string: path), on: app.eventLoopGroup.next())
    let response = try await app.responder.respond(to: request).get()
    var json: [String: Any]? = nil
    if let string = response.body.string, let data = string.data(using: .utf8) {
        json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    return (response.status, json)
}

private func makeResponse(
    code: String, sector: String = "電気機器", market: String = "プライム",
    latest: [String: Any], prior: [String: Any]? = nil, older: [String: Any]? = nil
) throws -> FinancialsResponse {
    var years: [[String: Any]] = [latest.merging(["fy_end": "2025-03-31"]) { $1 }]
    if let prior { years.append(prior.merging(["fy_end": "2024-03-31"]) { $1 }) }
    if let older { years.append(older.merging(["fy_end": "2023-03-31"]) { $1 }) }
    let dict: [String: Any] = [
        "schema_version": 2, "code": code, "name": "会社\(code)", "sector": sector,
        "market": market, "currency": "JPY", "unit": "百万円", "years": years,
    ]
    return try JSONDecoder().decode(
        FinancialsResponse.self, from: JSONSerialization.data(withJSONObject: dict))
}

private func seedFinancials(
    _ response: FinancialsResponse, cacheVersion: String = companyFinancialsCacheVersion, db: Database
) async throws {
    let model = CompanyFinancials()
    model.id = response.code
    model.response = response
    model.cacheVersion = cacheVersion
    model.requestedYears = 5
    try await model.create(on: db)
}

private func codes(_ json: [String: Any]?) -> [String] {
    (json?["items"] as? [[String: Any]])?.compactMap { $0["code"] as? String } ?? []
}

@Suite struct ScreenIngestTests {

    @Test func upsertWritesLatestFyAndRemovesPlaceholder() async throws {
        try await withApp { app in
            let resp = try makeResponse(
                code: "6758", latest: ["sales": 1210.0, "roic": 12.0],
                prior: ["sales": 1100.0], older: ["sales": 1000.0])
            try await upsertScreenIndex(code: "6758", response: resp, db: app.db)
            let row = try #require(try await ScreenIndex.find("6758", on: app.db))
            #expect(row.periodEnd == "2025-03-31")
            #expect(row.roic == 12)
            #expect(row.salesCagr3y.map { abs($0 - 10) < 1e-9 } == true)
            #expect(row.cacheVersion == screenIndexVersion)

            try await upsertScreenIndex(
                code: "6759",
                response: try makeResponse(
                    code: "6759", latest: ["sales": 1210.0], prior: ["sales": 1000.0]),
                db: app.db)
            #expect(try await ScreenIndex.find("6759", on: app.db)?.salesCagr3y == nil)

            try await upsertScreenIndex(
                code: "6758", response: .notApplicablePlaceholder(code: "6758"), db: app.db)
            #expect(try await ScreenIndex.find("6758", on: app.db) == nil)
        }
    }

    @Test func rebuildProjectsServableRowsAndDropsOrphans() async throws {
        try await withApp { app in
            try await seedFinancials(try makeResponse(code: "0001", latest: ["roic": 5.0]), db: app.db)
            try await seedFinancials(
                try makeResponse(code: "0002", latest: ["roic": 9.0]), cacheVersion: "fin-v1", db: app.db)
            try await seedFinancials(.notApplicablePlaceholder(code: "0003"), db: app.db)
            let orphan = ScreenIndex()
            orphan.apply(
                ScreenRow(
                    code: "9999", name: "", market: "プライム", sector: "", periodEnd: "2025-03-31",
                    metrics: [:]))
            try await orphan.create(on: app.db)

            let summary = try await rebuildScreenIndex(db: app.db, pageSize: 2)
            #expect(summary == ScreenRebuildSummary(scanned: 3, indexed: 1, removed: 3))
            let remaining = try await ScreenIndex.query(on: app.db).all().compactMap(\.id)
            #expect(remaining == ["0001"])
        }
    }

    @Test func rebuildLimitStopsBeforeOrphanCleanup() async throws {
        try await withApp { app in
            try await seedFinancials(
                try makeResponse(
                    code: "0001", latest: ["sales": 1210.0, "roic": 5.0],
                    prior: ["sales": 1100.0], older: ["sales": 1000.0]),
                db: app.db)
            try await seedFinancials(
                try makeResponse(
                    code: "0002", latest: ["sales": 1210.0, "roic": 9.0],
                    prior: ["sales": 1100.0], older: ["sales": 1000.0]),
                db: app.db)
            let orphan = ScreenIndex()
            orphan.apply(
                ScreenRow(
                    code: "9999", name: "", market: "プライム", sector: "", periodEnd: "2025-03-31",
                    metrics: [:]))
            try await orphan.create(on: app.db)

            let summary = try await rebuildScreenIndex(db: app.db, pageSize: 2, limit: 1)
            #expect(summary == ScreenRebuildSummary(scanned: 1, indexed: 1, removed: 0))
            let row = try #require(try await ScreenIndex.find("0001", on: app.db))
            #expect(row.cacheVersion == screenIndexVersion)
            #expect(row.salesCagr3y.map { abs($0 - 10) < 1e-9 } == true)
            #expect(try await ScreenIndex.find("0002", on: app.db) == nil)
            #expect(try await ScreenIndex.find("9999", on: app.db) != nil)
        }
    }

    @Test func ingestSkipBackfillsMissingScreenIndex() async throws {
        try await withApp { app in
            let doc = EdinetDocument()
            doc.id = "S1"
            doc.edinetCode = "E00001"
            doc.secCode = "67580"
            doc.filerName = "テスト"
            doc.docTypeCode = "120"
            doc.ordinanceCode = Api.ordinanceCompanyDisclosure
            doc.formCode = "030000"
            doc.submitDateTime = "2025-06-20 09:00"
            try await doc.create(on: app.db)

            let fin = CompanyFinancials()
            fin.id = "6758"
            fin.response = try makeResponse(
                code: "6758", latest: ["sales": 1200.0, "roic": 12.0])
            fin.cacheVersion = companyFinancialsCacheVersion
            fin.requestedYears = 5
            fin.highWater = "2025-06-20 09:00"
            fin.assemblyFingerprint = financialsAssemblyFingerprint()
            try await fin.create(on: app.db)
            #expect(try await ScreenIndex.find("6758", on: app.db) == nil)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run for a current company")
                return .failed
            }
            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
            let row = try #require(try await ScreenIndex.find("6758", on: app.db))
            #expect(row.roic == 12)
            #expect(row.sales == 1200)
            #expect(row.cacheVersion == screenIndexVersion)
        }
    }

    @Test func ingestSkipRebuildsStaleScreenIndexAndDerivesSalesCagr3y() async throws {
        try await withApp { app in
            let doc = EdinetDocument()
            doc.id = "S1"
            doc.edinetCode = "E00001"
            doc.secCode = "67580"
            doc.filerName = "テスト"
            doc.docTypeCode = "120"
            doc.ordinanceCode = Api.ordinanceCompanyDisclosure
            doc.formCode = "030000"
            doc.submitDateTime = "2025-06-20 09:00"
            try await doc.create(on: app.db)

            let fin = CompanyFinancials()
            fin.id = "6758"
            fin.response = try makeResponse(
                code: "6758", latest: ["sales": 1210.0, "roic": 12.0],
                prior: ["sales": 1100.0], older: ["sales": 1000.0])
            fin.cacheVersion = companyFinancialsCacheVersion
            fin.requestedYears = 5
            fin.highWater = "2025-06-20 09:00"
            fin.assemblyFingerprint = financialsAssemblyFingerprint()
            try await fin.create(on: app.db)

            try await upsertScreenIndex(code: "6758", response: fin.response, db: app.db)
            let stale = try #require(try await ScreenIndex.find("6758", on: app.db))
            stale.cacheVersion = nil
            stale.salesCagr3y = nil
            try await stale.update(on: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run for a current company")
                return .failed
            }
            #expect(summary.skipped == 1)
            #expect(summary.attempted == 0)
            let row = try #require(try await ScreenIndex.find("6758", on: app.db))
            #expect(row.cacheVersion == screenIndexVersion)
            #expect(row.salesCagr3y.map { abs($0 - 10) < 1e-9 } == true)
        }
    }

    @Test func ingestProjectsScreenCagrFromServableNonCurrentFinancials() async throws {
        try await withApp { app in
            try await seedFinancials(
                try makeResponse(
                    code: "6758", latest: ["sales": 1210.0, "roic": 12.0],
                    prior: ["sales": 1100.0], older: ["sales": 1000.0]),
                cacheVersion: "fin-v4", db: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run without documents")
                return .failed
            }
            #expect(summary.skipped == 0)
            #expect(summary.attempted == 0)
            let row = try #require(try await ScreenIndex.find("6758", on: app.db))
            #expect(row.cacheVersion == screenIndexVersion)
            #expect(row.salesCagr3y.map { abs($0 - 10) < 1e-9 } == true)
        }
    }

    @Test func ingestDoesNotIndexUnservableFinancials() async throws {
        try await withApp { app in
            try await seedFinancials(
                try makeResponse(
                    code: "6758", latest: ["sales": 1210.0, "roic": 12.0],
                    prior: ["sales": 1100.0], older: ["sales": 1000.0]),
                cacheVersion: "fin-v1", db: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run without documents")
                return .failed
            }
            #expect(summary.attempted == 0)
            #expect(try await ScreenIndex.find("6758", on: app.db) == nil)
        }
    }

    @Test func ingestSkipLeavesCurrentScreenIndexUntouched() async throws {
        try await withApp { app in
            let doc = EdinetDocument()
            doc.id = "S1"
            doc.edinetCode = "E00001"
            doc.secCode = "67580"
            doc.filerName = "テスト"
            doc.docTypeCode = "120"
            doc.ordinanceCode = Api.ordinanceCompanyDisclosure
            doc.formCode = "030000"
            doc.submitDateTime = "2025-06-20 09:00"
            try await doc.create(on: app.db)

            let fin = CompanyFinancials()
            fin.id = "6758"
            fin.response = try makeResponse(
                code: "6758", latest: ["sales": 1210.0, "roic": 12.0],
                prior: ["sales": 1100.0], older: ["sales": 1000.0])
            fin.cacheVersion = companyFinancialsCacheVersion
            fin.requestedYears = 5
            fin.highWater = "2025-06-20 09:00"
            fin.assemblyFingerprint = financialsAssemblyFingerprint()
            try await fin.create(on: app.db)

            try await upsertScreenIndex(code: "6758", response: fin.response, db: app.db)
            let current = try #require(try await ScreenIndex.find("6758", on: app.db))
            current.salesCagr3y = 99
            try await current.update(on: app.db)

            let summary = try await runFinancialsIngest(db: app.db, years: 5, limit: nil) { _ in
                Issue.record("computer must not run for a current company")
                return .failed
            }
            #expect(summary.skipped == 1)
            let row = try #require(try await ScreenIndex.find("6758", on: app.db))
            #expect(row.cacheVersion == screenIndexVersion)
            #expect(row.salesCagr3y == 99)
        }
    }

    @Test func ingestSkipBackfillPagesServableFinancials() async throws {
        try await withApp { app in
            try await seedFinancials(
                try makeResponse(
                    code: "0001", latest: ["sales": 1210.0, "roic": 5.0],
                    prior: ["sales": 1100.0], older: ["sales": 1000.0]),
                db: app.db)
            try await seedFinancials(
                try makeResponse(
                    code: "0002", latest: ["sales": 1210.0, "roic": 9.0],
                    prior: ["sales": 1100.0], older: ["sales": 1000.0]),
                db: app.db)
            try await seedFinancials(
                try makeResponse(code: "0003", latest: ["roic": 7.0]), cacheVersion: "fin-v1",
                db: app.db)

            await backfillScreenIndexForServableFinancials(db: app.db, pageSize: 1, logger: nil)
            let first = try #require(try await ScreenIndex.find("0001", on: app.db))
            let second = try #require(try await ScreenIndex.find("0002", on: app.db))
            #expect(first.cacheVersion == screenIndexVersion)
            #expect(second.cacheVersion == screenIndexVersion)
            #expect(first.salesCagr3y.map { abs($0 - 10) < 1e-9 } == true)
            #expect(second.salesCagr3y.map { abs($0 - 10) < 1e-9 } == true)
            #expect(try await ScreenIndex.find("0003", on: app.db) == nil)
        }
    }

    @Test func ingestSkipBackfillRebuildsStaleStampOnLaterPage() async throws {
        try await withApp { app in
            try await seedFinancials(
                try makeResponse(
                    code: "0001", latest: ["sales": 1210.0, "roic": 5.0],
                    prior: ["sales": 1100.0], older: ["sales": 1000.0]),
                db: app.db)
            try await seedFinancials(
                try makeResponse(
                    code: "0002", latest: ["sales": 1210.0, "roic": 9.0],
                    prior: ["sales": 1100.0], older: ["sales": 1000.0]),
                db: app.db)
            try await upsertScreenIndex(
                code: "0002",
                response: try makeResponse(code: "0002", latest: ["sales": 1210.0, "roic": 9.0]),
                db: app.db)
            let stale = try #require(try await ScreenIndex.find("0002", on: app.db))
            stale.cacheVersion = nil
            stale.salesCagr3y = nil
            try await stale.update(on: app.db)

            await backfillScreenIndexForServableFinancials(db: app.db, pageSize: 1, logger: nil)
            let first = try #require(try await ScreenIndex.find("0001", on: app.db))
            let second = try #require(try await ScreenIndex.find("0002", on: app.db))
            #expect(first.cacheVersion == screenIndexVersion)
            #expect(second.cacheVersion == screenIndexVersion)
            #expect(first.salesCagr3y.map { abs($0 - 10) < 1e-9 } == true)
            #expect(second.salesCagr3y.map { abs($0 - 10) < 1e-9 } == true)
        }
    }

    @Test func screenEndpointReturnsEmptyOkWhenIndexHasRowsButNoMatch() async throws {
        try await withApp { app in
            try await upsertScreenIndex(
                code: "0001",
                response: try makeResponse(code: "0001", latest: ["roic": 5.0]),
                db: app.db)
            let (status, json) = try await send(app, "/v1/screen?sector=%E8%BC%B8%E9%80%81%E7%94%A8%E6%A9%9F%E5%99%A8")
            #expect(status == .ok)
            #expect(codes(json) == [])
            #expect(json?["matched"] as? Int == 0)
        }
    }

    @Test func screenEndpointFiltersSortsAndLimits() async throws {
        try await withApp { app in
            let rows: [(String, String, [String: Any])] = [
                ("0001", "電気機器", ["sales": 50000.0, "roic": 20.0, "net_de": 0.2]),
                ("0002", "電気機器", ["sales": 5000.0, "roic": 25.0, "net_de": 0.1]),
                ("0003", "電気機器", ["sales": 80000.0, "roic": 10.0, "net_de": 1.5]),
                ("0004", "輸送用機器", ["sales": 90000.0, "roic": 30.0, "net_de": 0.5]),
                ("0005", "電気機器", ["sales": 70000.0, "net_de": 0.3]),
            ]
            for (code, sector, latest) in rows {
                try await upsertScreenIndex(
                    code: code, response: try makeResponse(code: code, sector: sector, latest: latest),
                    db: app.db)
            }

            let (status, json) = try await send(
                app, "/v1/screen?sector=%E9%9B%BB%E6%B0%97%E6%A9%9F%E5%99%A8&sales_min=10000000000&net_de_max=1")
            #expect(status == .ok)
            #expect(codes(json) == ["0001"])
            #expect(json?["matched"] as? Int == 1)
            let item = (json?["items"] as? [[String: Any]])?.first
            #expect(item?["sales"] as? Double == 50_000_000_000)
            #expect(item?["roic"] as? Double == 20)
            #expect(item?["net_de"] as? Double == 0.2)
            #expect(item?["operating_margin"] is NSNull)
            #expect(item?["sales_cagr_3y"] is NSNull)
            #expect(item?["roe"] == nil)

            let (_, all) = try await send(app, "/v1/screen?limit=2")
            #expect(codes(all) == ["0004", "0002"])
            #expect(all?["returned"] as? Int == 2)
            #expect(all?["matched"] as? Int == 4)

            let (_, asc) = try await send(app, "/v1/screen?sort=sales&order=asc&limit=2")
            #expect(codes(asc) == ["0002", "0001"])
        }
    }

    @Test func upsertDerivesScreenV3Metrics() async throws {
        try await withApp { app in
            let resp = try makeResponse(
                code: "6758",
                latest: [
                    "sales": 2000.0, "cfo": 300.0, "capex": 100.0,
                    "operating_margin": 12.0, "roic": 14.0,
                    "dividend_ss": 90.0, "net_profit": 200.0,
                ],
                prior: ["operating_margin": 9.0, "roic": 11.0,
                        "dividend_ss": 50.0, "net_profit": 200.0],
                older: ["operating_margin": 6.0, "roic": 8.0,
                        "dividend_ss": 40.0, "net_profit": 200.0])
            try await upsertScreenIndex(code: "6758", response: resp, db: app.db)
            let row = try #require(try await ScreenIndex.find("6758", on: app.db))
            #expect(row.cfo == 300)
            #expect(row.cfoMargin == 15)
            #expect(row.fcf == 200)
            #expect(row.operatingMarginCagr3y == 3)
            #expect(row.roicCagr3y == 3)
            #expect(row.payoutRatio == 30)
            #expect(row.payoutRatioY1 == 20)
            #expect(row.payoutRatioY2 == 25)
            #expect(row.payoutRatioY3 == 45)
        }
    }

    @Test func upsertLeavesScreenV3MetricsNullWhenInputsMissing() async throws {
        try await withApp { app in
            let resp = try makeResponse(
                code: "6758", latest: ["sales": 2000.0, "roic": 10.0, "net_profit": -50.0])
            try await upsertScreenIndex(code: "6758", response: resp, db: app.db)
            let row = try #require(try await ScreenIndex.find("6758", on: app.db))
            #expect(row.cfo == nil)
            #expect(row.cfoMargin == nil)
            #expect(row.fcf == nil)
            // 3 期に満たない・配当行が無く、赤字期は性向を定義しない。
            #expect(row.operatingMarginCagr3y == nil)
            #expect(row.roicCagr3y == nil)
            #expect(row.payoutRatio == nil)
            #expect(row.payoutRatioY1 == nil)
            #expect(row.payoutRatioY2 == nil)
            #expect(row.payoutRatioY3 == nil)
        }
    }

    @Test func screenEndpointFiltersScreenV3Metrics() async throws {
        try await withApp { app in
            let rows: [(String, [String: Any])] = [
                ("0001", ["sales": 2000.0, "cfo": 300.0, "capex": 100.0, "roic": 20.0,
                          "dividend_ss": 60.0, "net_profit": 200.0]),
                ("0002", ["sales": 2000.0, "cfo": 100.0, "capex": 150.0, "roic": 25.0,
                          "dividend_ss": 10.0, "net_profit": 100.0]),
                ("0003", ["sales": 1000.0]),
            ]
            for (code, latest) in rows {
                let dividend = latest["dividend_ss"] as? Double
                let profit = latest["net_profit"] as? Double
                var prior: [String: Any] = ["roic": 14.0]
                var older: [String: Any] = ["roic": 10.0]
                if let dividend, let profit {
                    prior["dividend_ss"] = dividend
                    prior["net_profit"] = profit
                    older["dividend_ss"] = dividend
                    older["net_profit"] = profit
                }
                try await upsertScreenIndex(
                    code: code,
                    response: try makeResponse(
                        code: code, latest: latest, prior: prior, older: older),
                    db: app.db)
            }

            // 高CF: cfo_margin ≥ 10 かつ fcf > 0。
            let (status, json) = try await send(
                app, "/v1/screen?cfo_margin_min=10&fcf_min=0&sort=fcf&order=desc")
            #expect(status == .ok)
            #expect(codes(json) == ["0001"])
            let item = (json?["items"] as? [[String: Any]])?.first
            #expect(item?["cfo_margin"] as? Double == 15)
            #expect(item?["fcf"] as? Double == 200_000_000)
            #expect(item?["payout_ratio"] == nil)

            // 高還元: payout_ratio（3 年平均）≥ 20 → 0001 のみ（0002 は 10、0003 は null）。
            let (_, payout) = try await send(app, "/v1/screen?payout_ratio_min=20")
            #expect(codes(payout) == ["0001"])
            let payoutItem = (payout?["items"] as? [[String: Any]])?.first
            #expect(payoutItem?["payout_ratio"] as? Double == 30)
            let series = payoutItem?["payout_ratio_3y"] as? [Any]
            #expect(series?.count == 3)
            #expect(series?[0] as? Double == 30)
            #expect(series?[1] as? Double == 30)
            #expect(series?[2] as? Double == 30)

            // 改善: roic_cagr_3y ≥ +3pp/年 → 0001 (+5) と 0002 (+7.5)。0003 は 3 期に満たない。
            let (_, improving) = try await send(
                app, "/v1/screen?roic_cagr_3y_min=3&sort=roic_cagr_3y&order=desc")
            #expect(codes(improving) == ["0002", "0001"])
        }
    }

    @Test func screenEndpointFiltersSalesCagr3y() async throws {
        try await withApp { app in
            try await upsertScreenIndex(
                code: "0001",
                response: try makeResponse(
                    code: "0001", latest: ["sales": 1210.0, "roic": 20.0],
                    prior: ["sales": 1100.0], older: ["sales": 1000.0]),
                db: app.db)
            try await upsertScreenIndex(
                code: "0002",
                response: try makeResponse(
                    code: "0002", latest: ["sales": 1050.0, "roic": 25.0],
                    prior: ["sales": 1030.0], older: ["sales": 1000.0]),
                db: app.db)
            try await upsertScreenIndex(
                code: "0003",
                response: try makeResponse(code: "0003", latest: ["sales": 1210.0, "roic": 30.0]),
                db: app.db)

            let (status, json) = try await send(app, "/v1/screen?sales_cagr_3y_min=10")
            #expect(status == .ok)
            #expect(codes(json) == ["0001"])
            let cagr = try #require((json?["items"] as? [[String: Any]])?.first?["sales_cagr_3y"] as? Double)
            #expect(abs(cagr - 10) < 1e-9)
        }
    }

    @Test func screenEndpointFiltersMultipleSectorsWithIn() async throws {
        try await withApp { app in
            let rows: [(String, String, [String: Any])] = [
                ("0001", "電気機器", ["roic": 20.0]),
                ("0002", "輸送用機器", ["roic": 25.0]),
                ("0003", "小売業", ["roic": 30.0]),
            ]
            for (code, sector, latest) in rows {
                try await upsertScreenIndex(
                    code: code, response: try makeResponse(code: code, sector: sector, latest: latest),
                    db: app.db)
            }

            // `sector=A,B` のカンマ区切りは OR（IN 検索）になる。
            let (status, json) = try await send(
                app,
                "/v1/screen?sector=%E9%9B%BB%E6%B0%97%E6%A9%9F%E5%99%A8,%E8%BC%B8%E9%80%81%E7%94%A8%E6%A9%9F%E5%99%A8&sort=roic&order=desc")
            #expect(status == .ok)
            #expect(codes(json) == ["0002", "0001"])
            #expect(json?["matched"] as? Int == 2)

            // `sector=A&sector=B` のキー重複も同じ OR になる。
            let (repeatStatus, repeatJson) = try await send(
                app,
                "/v1/screen?sector=%E9%9B%BB%E6%B0%97%E6%A9%9F%E5%99%A8&sector=%E5%B0%8F%E5%A3%B2%E6%A5%AD")
            #expect(repeatStatus == .ok)
            #expect(codes(repeatJson) == ["0003", "0001"])
            #expect(repeatJson?["matched"] as? Int == 2)
        }
    }

    @Test func screenSnapshotReturnsAllRowsInColumnsAndRevalidates() async throws {
        try await withApp { app in
            let (emptyStatus, _) = try await send(app, "/v1/screen/snapshot")
            #expect(emptyStatus == .notFound)

            try await upsertScreenIndex(
                code: "0002",
                response: try makeResponse(
                    code: "0002", sector: "輸送用機器", latest: ["roic": 12.345678, "net_de": 0.25]),
                db: app.db)
            try await upsertScreenIndex(
                code: "0001",
                response: try makeResponse(code: "0001", latest: ["sales": 50000.0, "roic": 20.0]),
                db: app.db)

            let request = Request(
                application: app, method: .GET, url: URI(string: "/v1/screen/snapshot"),
                on: app.eventLoopGroup.next())
            let response = try await app.responder.respond(to: request).get()
            #expect(response.status == .ok)
            #expect(response.headers.first(name: .cacheControl) == "private, no-cache")
            let etag = try #require(response.headers.first(name: .eTag))
            #expect(etag.hasPrefix("\"") && etag.hasSuffix("\""))
            let data = try #require(response.body.string?.data(using: .utf8))
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["schema_version"] as? Int == screenSnapshotSchemaVersion)
            #expect(json["screen_version"] as? String == screenIndexVersion)
            #expect(json["count"] as? Int == 2)
            #expect(json["code"] as? [String] == ["0001", "0002"])
            #expect(json["sector"] as? [String] == ["電気機器", "輸送用機器"])
            let metrics = try #require(json["metrics"] as? [String: [Any]])
            #expect(Set(metrics.keys) == Set(ScreenMetric.allCases.map(\.rawValue)))
            #expect(metrics["roic"]?[0] as? Double == 20)
            #expect(metrics["roic"]?[1] as? Double == 12.3457)
            #expect(metrics["sales"]?[1] is NSNull)
            #expect((json["payout_ratio_3y"] as? [[Any]])?.map(\.count) == [3, 3])

            let conditional = Request(
                application: app, method: .GET, url: URI(string: "/v1/screen/snapshot"),
                headers: ["If-None-Match": "\"stale\", W/\(etag)"], on: app.eventLoopGroup.next())
            let notModified = try await app.responder.respond(to: conditional).get()
            #expect(notModified.status == .notModified)
            #expect(notModified.headers.first(name: .eTag) == etag)
            #expect((notModified.body.string ?? "").isEmpty)

            // 作り置きは作り直しまで変わらない（リクエストは DB を読まない）。
            try await upsertScreenIndex(
                code: "0003", response: try makeResponse(code: "0003", latest: ["roic": 5.0]),
                db: app.db)
            func revalidateWithFirstTag() async throws -> Response {
                let request = Request(
                    application: app, method: .GET, url: URI(string: "/v1/screen/snapshot"),
                    headers: ["If-None-Match": etag], on: app.eventLoopGroup.next())
                return try await app.responder.respond(to: request).get()
            }
            #expect(try await revalidateWithFirstTag().status == .notModified)

            let cache = try #require(app.storage[ScreenSnapshotCacheKey.self])
            #expect(await refreshScreenSnapshot(cache: cache, db: app.db, logger: app.logger))
            let refreshed = try await revalidateWithFirstTag()
            #expect(refreshed.status == .ok)
            #expect(refreshed.headers.first(name: .eTag) != etag)
            let refreshedData = try #require(refreshed.body.string?.data(using: .utf8))
            let refreshedJson = try #require(
                try JSONSerialization.jsonObject(with: refreshedData) as? [String: Any])
            #expect(refreshedJson["count"] as? Int == 3)

            // 索引が空になったら作り置きを捨てて 404 に戻す。
            try await ScreenIndex.query(on: app.db).delete()
            #expect(!(await refreshScreenSnapshot(cache: cache, db: app.db, logger: app.logger)))
            let (goneStatus, _) = try await send(app, "/v1/screen/snapshot")
            #expect(goneStatus == .notFound)
        }
        let app = try await Application.make(.testing)
        try await registerRoutes(app, context: makeContext())
        let (status, _) = try await send(app, "/v1/screen/snapshot")
        #expect(status == .serviceUnavailable)
        try await app.asyncShutdown()
    }

    @Test func screenSnapshotPagesThroughAllRows() async throws {
        try await withApp { app in
            for code in ["0003", "0001", "0005", "0002", "0004"] {
                try await upsertScreenIndex(
                    code: code, response: try makeResponse(code: code, latest: ["roic": 5.0]),
                    db: app.db)
            }
            let body = try #require(try await loadScreenSnapshot(db: app.db, pageSize: 2))
            #expect(body["code"] as? [String] == ["0001", "0002", "0003", "0004", "0005"])
            #expect(body["count"] as? Int == 5)
        }
    }

    @Test func entityTagMatchingAcceptsListsWildcardAndWeakTags() {
        #expect(entityTagMatches("\"abc\"", etag: "\"abc\""))
        #expect(entityTagMatches("\"x\", W/\"abc\"", etag: "\"abc\""))
        #expect(entityTagMatches("*", etag: "\"abc\""))
        #expect(!entityTagMatches("\"abd\"", etag: "\"abc\""))
        #expect(!entityTagMatches("", etag: "\"abc\""))
    }

    @Test func screenEndpointRejectsUnknownKeysAndServes503WithoutDb() async throws {
        try await withApp { app in
            let (emptyStatus, emptyJson) = try await send(app, "/v1/screen")
            #expect(emptyStatus == .notFound)
            #expect(emptyJson?["status"] as? Int == 404)

            let (status, json) = try await send(app, "/v1/screen?ccc_min=1")
            #expect(status == .badRequest)
            #expect(json?["status"] as? Int == 400)

            let (growthStatus, growthJson) = try await send(app, "/v1/screen?sales_growth_min=1")
            #expect(growthStatus == .badRequest)
            #expect(growthJson?["status"] as? Int == 400)
        }
        let app = try await Application.make(.testing)
        try await registerRoutes(app, context: makeContext())
        let (status, _) = try await send(app, "/v1/screen")
        #expect(status == .serviceUnavailable)
        try await app.asyncShutdown()
    }
}
