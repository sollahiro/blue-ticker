// Screen（screen_index）の派生更新・rebuild・read 経路（GET /v1/screen）を
// インメモリ SQLite で検証する（BLT-49）。

import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import Vapor

@testable import BlueTickerCore
@testable import BltServerCore

private func makeContext() -> BltServerContext {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("blt-screen-tests-\(UUID().uuidString)", isDirectory: true)
    let chatClient = ChatCompletionClient(
        endpoint: ChatCompletionEndpoint(baseURL: "", apiKey: "", model: ""))
    return BltServerContext(
        apiKey: "test-key", cacheDir: dir, businessChatClient: chatClient,
        geographyChatClient: chatClient)
}

private func withApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateEdinetDocument())
        app.migrations.add(CreateCompanyFinancials())
        app.migrations.add(CreateCompanyHalfFinancials())
        app.migrations.add(AddHighWaterToCompanyFinancials())
        app.migrations.add(AddAssemblyFingerprintToCompanyFinancials())
        app.migrations.add(CreateScreenIndex())
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
    latest: [String: Any], prior: [String: Any]? = nil
) throws -> FinancialsResponse {
    var years: [[String: Any]] = [latest.merging(["fy_end": "2025-03-31"]) { $1 }]
    if let prior { years.append(prior.merging(["fy_end": "2024-03-31"]) { $1 }) }
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
                code: "6758", latest: ["sales": 1200.0, "roic": 12.0], prior: ["sales": 1000.0])
            try await upsertScreenIndex(code: "6758", response: resp, db: app.db)
            let row = try #require(try await ScreenIndex.find("6758", on: app.db))
            #expect(row.periodEnd == "2025-03-31")
            #expect(row.roic == 12)
            #expect(row.salesGrowth.map { abs($0 - 20) < 1e-9 } == true)

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
                app, "/v1/screen?sector=%E9%9B%BB%E6%B0%97%E6%A9%9F%E5%99%A8&sales_min=10000&net_de_max=1")
            #expect(status == .ok)
            #expect(codes(json) == ["0001"])
            #expect(json?["matched"] as? Int == 1)
            let item = (json?["items"] as? [[String: Any]])?.first
            #expect(item?["sales"] as? Double == 50000)
            #expect(item?["roic"] as? Double == 20)
            #expect(item?["net_de"] as? Double == 0.2)
            #expect(item?["roe"] == nil)

            let (_, all) = try await send(app, "/v1/screen?limit=2")
            #expect(codes(all) == ["0004", "0002"])
            #expect(all?["returned"] as? Int == 2)
            #expect(all?["matched"] as? Int == 4)

            let (_, asc) = try await send(app, "/v1/screen?sort=sales&order=asc&limit=2")
            #expect(codes(asc) == ["0002", "0001"])
        }
    }

    @Test func screenEndpointRejectsUnknownKeysAndServes503WithoutDb() async throws {
        try await withApp { app in
            let (emptyStatus, emptyJson) = try await send(app, "/v1/screen")
            #expect(emptyStatus == .notFound)
            #expect(emptyJson?["status"] as? Int == 404)

            let (status, json) = try await send(app, "/v1/screen?ccc_min=1")
            #expect(status == .badRequest)
            #expect(json?["status"] as? Int == 400)
        }
        let app = try await Application.make(.testing)
        try await registerRoutes(app, context: makeContext())
        let (status, _) = try await send(app, "/v1/screen")
        #expect(status == .serviceUnavailable)
        try await app.asyncShutdown()
    }
}
