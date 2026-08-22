// REST トランスポート層（Routes.swift）の仕様。
// 認証（Cloudflare Access モード・無認証モード）、エラー封筒
// （{"error":...,"status":N}）、DB 非接続時の 503、格納済みデータなしの 404 を、
// インメモリ Application + responder 直叩きで（ネットワーク非依存に）検証する。
// ファサード呼び出しが必要なエンドポイント（companies / filings のライブ探索）は
// EDINET 依存のため対象外とし、DB ゲートで完結するパスのみを見る。

import Fluent
import FluentSQLiteDriver
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import Vapor

@testable import BlueTickerCore
@testable import BltServerCore

private struct StubRoutesEsefTransport: EsefHTTPTransport {
    var handler: @Sendable (URLRequest) throws -> (Data, URLResponse)
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try handler(request)
    }
}

private func makeContext() -> BltServerContext {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("blt-routes-tests-\(UUID().uuidString)", isDirectory: true)
    let chatClient = ChatCompletionClient(
        endpoint: ChatCompletionEndpoint(baseURL: "", apiKey: "", model: ""))
    return BltServerContext(
        apiKey: "test-key", cacheDir: dir, businessChatClient: chatClient,
        geographyChatClient: chatClient)
}

/// ルート登録済みの Application を作って body を実行する。
/// databases=true でインメモリ SQLite をマイグレーションし、DB ありの経路を有効にする。
private func withApp(
    databases: Bool = false,
    cfAccessTeamDomain: String? = nil,
    feedTrendSink: (any FeedTrendSink)? = nil,
    feedTrendQuery: (any FeedTrendQueryClient)? = nil,
    _ body: (Application) async throws -> Void
) async throws {
    let app = try await Application.make(.testing)
    do {
        if databases {
            app.databases.use(.sqlite(.memory), as: .sqlite)
            app.migrations.add(CreateEdinetDocument())
            app.migrations.add(CreateCompanyFinancials())
            app.migrations.add(CreateCompanyHalfFinancials())
            app.migrations.add(AddHighWaterToCompanyFinancials())
            app.migrations.add(AddAssemblyFingerprintToCompanyFinancials())
            app.migrations.add(CreateCompanyFilingSections())
            app.migrations.add(CreateCompanySegmentBreakdowns())
            app.migrations.add(RenameCompanySegmentBreakdownsToCompanyBreakdowns())
            app.migrations.add(AddNotApplicableReasonToCompanyBreakdowns())
            app.migrations.add(CreateCompanyIcons())
            try await app.autoMigrate()
        }
        if feedTrendSink != nil || feedTrendQuery != nil {
            setFeedTrendServices(
                app,
                sink: feedTrendSink ?? NoopFeedTrendSink(),
                query: feedTrendQuery ?? UnconfiguredFeedTrendQueryClient())
        }
        try await registerRoutes(
            app, context: makeContext(), cfAccessTeamDomain: cfAccessTeamDomain)
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

/// responder 経由でリクエストを送り、ステータスとデコード済み JSON を返す。
private func send(
    _ app: Application, _ path: String, origin: String? = nil
) async throws -> (status: HTTPResponseStatus, json: [String: Any]?) {
    let (status, json, _) = try await sendWithHeaders(app, path, origin: origin)
    return (status, json)
}

/// responder 経由でリクエストを送り、ステータス・デコード済み JSON・レスポンスヘッダーを返す
/// （CORS ヘッダーの検証用に origin を指定できる）。
private func sendWithHeaders(
    _ app: Application, _ path: String, origin: String? = nil
) async throws -> (status: HTTPResponseStatus, json: [String: Any]?, headers: HTTPHeaders) {
    var headers = HTTPHeaders()
    if let origin { headers.add(name: .origin, value: origin) }
    let request = Request(
        application: app, method: .GET, url: URI(string: path), headers: headers,
        on: app.eventLoopGroup.next())
    let response = try await app.responder.respond(to: request).get()
    var json: [String: Any]? = nil
    if let string = response.body.string, let data = string.data(using: .utf8) {
        json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    return (response.status, json, response.headers)
}

/// 公開契約 FinancialsResponse を JSON 経由で構築する（FinancialsIngestTests.makeResponse と同型）。
private func makeDemoFinancialsResponse(code: String, years: Int) throws -> FinancialsResponse {
    let yrs = (0..<years).map { ["fy_end": "20\(20 + $0)-03-31"] }
    let dict: [String: Any] = [
        "schema_version": 2, "code": code, "name": "テスト",
        "sector": "", "market": "", "currency": "JPY", "unit": "百万円",
        "years": yrs,
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(FinancialsResponse.self, from: data)
}

@Suite struct RoutesTests {

    // MARK: - healthz（認証不要）

    @Test func healthzRespondsWithoutAuthAndExposesCacheVersions() async throws {
        try await withApp { app in
            let (status, json) = try await send(app, "/healthz")
            #expect(status == .ok)
            #expect(json?["status"] as? String == "ok")
            let versions = json?["cache_versions"] as? [String: Any]
            #expect(versions?["xbrl_facts"] as? String == xbrlFactsCacheVersion)
            #expect(versions?["company_financials"] as? String == companyFinancialsCacheVersion)
            #expect(versions?["company_financials_min_servable"] as? Int == companyFinancialsMinServableVersion)
            #expect(versions?["filing_sections"] as? String == filingSectionsCacheVersion)
            #expect(versions?["filing_sections_min_servable"] as? Int == filingSectionsMinServableVersion)
            #expect(versions?["breakdown_business"] as? String == businessBreakdownCacheVersion)
            #expect(versions?["breakdown_business_min_servable"] as? Int == businessBreakdownMinServableVersion)
            #expect(versions?["breakdown_geography"] as? String == geographyBreakdownCacheVersion)
            #expect(versions?["breakdown_geography_min_servable"] as? Int == geographyBreakdownMinServableVersion)
        }
    }

    // MARK: - 認証（Cloudflare Access モード・無認証モード）

    @Test func cfAccessModeDoesNotVerifyAtOrigin() async throws {
        // エッジ信頼モードでは origin はトークンを検証しない（Tunnel 経由限定が前提）
        try await withApp(cfAccessTeamDomain: "example.cloudflareaccess.com") { app in
            let (status, _) = try await send(app, "/v1/companies/7203/financials")
            #expect(status == .serviceUnavailable)
        }
    }

    @Test func noAuthModeAllowsAccess() async throws {
        try await withApp { app in
            let (status, _) = try await send(app, "/v1/companies/7203/financials")
            #expect(status == .serviceUnavailable)
        }
    }

    // MARK: - エラー封筒

    @Test func unknownPathReturnsContractErrorEnvelope() async throws {
        // Vapor 既定の {"error":true,"reason":...} ではなく公開契約の封筒で返る
        try await withApp { app in
            let (status, json) = try await send(app, "/nonexistent")
            #expect(status == .notFound)
            #expect(json?["error"] is String)
            #expect(json?["status"] as? Int == 404)
        }
    }

    // MARK: - DB 非接続時の 503（財務系はライブ計算へフォールバックしない）

    @Test func financialsEndpointsReturn503WithoutDatabase() async throws {
        try await withApp { app in
            for path in [
                "/v1/companies/7203/financials",
                "/v1/companies/7203/waterfall",
                "/v1/companies/7203/filing-content",
            ] {
                let (status, json) = try await send(app, path)
                #expect(status == .serviceUnavailable)
                #expect(json?["error"] as? String == "財務データベースに接続できません")
                #expect(json?["status"] as? Int == 503)
            }
        }
    }

    // MARK: - DB 接続・未格納時の 404

    @Test func financialsReturns404WhenNotStored() async throws {
        try await withApp(databases: true) { app in
            let (status, json) = try await send(app, "/v1/companies/7203/financials")
            #expect(status == .notFound)
            #expect(json?["error"] as? String == "財務データは未集計です")
            #expect(json?["status"] as? Int == 404)
            // errorResponse の reason 引数は breakdown 専用の拡張（issue #132）。
            // 他エンドポイントの 404 ボディへ漏れ出さないことを確認する。
            #expect(json?["reason"] == nil)
        }
    }

    @Test func waterfallReturns404WhenNotStored() async throws {
        try await withApp(databases: true) { app in
            let (status, json) = try await send(app, "/v1/companies/7203/waterfall")
            #expect(status == .notFound)
            #expect(json?["error"] as? String == "財務データは未集計です")
        }
    }

    @Test func filingContentReturns404WhenNotStored() async throws {
        try await withApp(databases: true) { app in
            let (status, json) = try await send(app, "/v1/companies/7203/filing-content")
            #expect(status == .notFound)
            #expect(json?["error"] as? String == "書類本文は未抽出です")
        }
    }

    @Test func breakdownReturns404WhenNotStored() async throws {
        try await withApp(databases: true) { app in
            let (status, json) = try await send(app, "/v1/companies/7203/breakdown")
            #expect(status == .notFound)
            #expect(json?["error"] as? String == "事業別内訳は未算出です")
            #expect(json?["reason"] == nil)
        }
    }

    /// issue #132: business 軸が解決できなかった場合、404 のステータスは維持したまま
    /// ボディへ E/F/unknown の reason を追加する（エッジ課金はステータス単位でメーターするため）。
    @Test func breakdownReturns404WithReasonWhenNotApplicable() async throws {
        try await withApp(databases: true) { app in
            let row = CompanyBreakdown(docID: "S1", axis: breakdownAxisBusiness)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = BreakdownSnapshotPayload(
                axis: "business", denominator: 0, denominatorTag: "", rows: [],
                sourceKind: breakdownSourceNotApplicable, needsReview: false, warnings: [])
            row.needsReview = false
            row.source = breakdownSourceNotApplicable
            row.contentHash = ""
            row.cacheVersion = businessBreakdownCacheVersion
            row.notApplicableReason = breakdownNotApplicableGeographyOnly
            try await row.create(on: app.db)

            let (status, json) = try await send(app, "/v1/companies/7203/breakdown")
            #expect(status == .notFound)
            #expect(json?["error"] as? String == "事業別内訳は未算出です")
            #expect(json?["reason"] as? String == "geography_only")
        }
    }

    /// 2026-07-27 品質ゲート通過後、axis=geography も business と同型で格納済みデータを返す。
    @Test func breakdownReturnsGeographyAxisWhenStored() async throws {
        try await withApp(databases: true) { app in
            let row = CompanyBreakdown(docID: "S1", axis: breakdownAxisGeography)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = BreakdownSnapshotPayload(
                axis: breakdownAxisGeography, denominator: 1_000_000,
                denominatorTag: "income_statement.sales",
                rows: [
                    BreakdownRowPayload(labelRaw: "日本", label: "日本", amount: 600_000, profit: nil, rowKind: "segment")
                ],
                sourceKind: breakdownSourceGeographyLLM, needsReview: false, warnings: [])
            row.needsReview = false
            row.source = breakdownSourceGeographyLLM
            row.contentHash = ""
            row.cacheVersion = geographyBreakdownCacheVersion
            try await row.create(on: app.db)

            let (status, json) = try await send(app, "/v1/companies/7203/breakdown?axis=geography")
            #expect(status == .ok)
            #expect(json?["axis"] as? String == breakdownAxisGeography)
        }
    }

    /// axis=geography 未算出時は business と別文言（「地域別内訳は未算出です」）で 404 になる。
    @Test func breakdownReturns404WithGeographyMessageWhenNotStored() async throws {
        try await withApp(databases: true) { app in
            let (status, json) = try await send(app, "/v1/companies/7203/breakdown?axis=geography")
            #expect(status == .notFound)
            #expect(json?["error"] as? String == "地域別内訳は未算出です")
        }
    }

    @Test func financialsWithInvalidYearsReturns404() async throws {
        // years <= 0 は無効要求として 404（空 years の 200 を返さない）
        try await withApp(databases: true) { app in
            let (status, _) = try await send(app, "/v1/companies/7203/financials?years=0")
            #expect(status == .notFound)
        }
    }

    // MARK: - skills（使用方法カタログ）

    @Test func skillsListReturnsCatalogWithOverview() async throws {
        try await withApp { app in
            let (status, json) = try await send(app, "/v1/skills")
            #expect(status == .ok)
            #expect(json?["schema_version"] as? Int == apiSkillsSchemaVersion)
            #expect((json?["overview"] as? String)?.isEmpty == false)
            let skills = json?["skills"] as? [[String: Any]]
            let ids = Set((skills ?? []).compactMap { $0["id"] as? String })
            #expect(ids == Set(apiSkillsCatalog().map(\.id)))
            #expect(skills?.contains { $0["mcp_tool"] as? String == "search_companies" } == true)
        }
    }

    @Test func skillsDetailReturnsParametersAndInstructions() async throws {
        try await withApp { app in
            let (status, json) = try await send(app, "/v1/skills/get-financials")
            #expect(status == .ok)
            #expect(json?["id"] as? String == "get-financials")
            #expect(json?["path"] as? String == "/v1/companies/{code}/financials")
            #expect(json?["mcp_tool"] as? String == "get_financial_summary")
            #expect((json?["instructions"] as? String)?.contains("Summary") == true)
            let parameters = json?["parameters"] as? [[String: Any]]
            #expect(parameters?.contains { $0["name"] as? String == "years" } == true)
        }
    }

    @Test func skillsDetailUnknownIdReturns404() async throws {
        try await withApp { app in
            let (status, json) = try await send(app, "/v1/skills/does-not-exist")
            #expect(status == .notFound)
            #expect(json?["status"] as? Int == 404)
        }
    }

    // MARK: - /v1/demo（子サイト実データデモ専用。company_breakdowns 格納銘柄限定）

    @Test func demoCompaniesReturns503WithoutDatabase() async throws {
        try await withApp { app in
            let (status, json) = try await send(app, "/v1/demo/companies?q=トヨタ")
            #expect(status == .serviceUnavailable)
            #expect(json?["error"] as? String == "検索データベースに接続できません")
        }
    }

    @Test func demoFinancialsReturns503WithoutDatabase() async throws {
        try await withApp { app in
            let (status, json) = try await send(app, "/v1/demo/companies/7203/financials")
            #expect(status == .serviceUnavailable)
            #expect(json?["error"] as? String == "財務データベースに接続できません")
        }
    }

    @Test func demoFinancialsReturns404WhenCodeNotInBreakdownPopulation() async throws {
        // company_breakdowns に行が無い銘柄（母集団外）は、company_financials の有無に関わらず対象外。
        try await withApp(databases: true) { app in
            let (status, json) = try await send(app, "/v1/demo/companies/7203/financials")
            #expect(status == .notFound)
            #expect(json?["error"] as? String == "デモ対象外の銘柄コードです")
        }
    }

    @Test func demoFinancialsReturns404WhenEligibleButFinancialsNotStored() async throws {
        try await withApp(databases: true) { app in
            let row = CompanyBreakdown(docID: "S100VWVY", axis: breakdownAxisBusiness)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = BreakdownSnapshotPayload(
                axis: "business", denominator: 0, denominatorTag: "", rows: [],
                sourceKind: "xbrl_facts", needsReview: false, warnings: [])
            row.needsReview = false
            row.source = "xbrl_facts"
            row.contentHash = ""
            row.cacheVersion = businessBreakdownCacheVersion
            try await row.create(on: app.db)

            let (status, json) = try await send(app, "/v1/demo/companies/7203/financials")
            #expect(status == .notFound)
            #expect(json?["error"] as? String == "財務データは未集計です")
        }
    }

    @Test func demoFinancialsReturns200WhenEligibleAndStored() async throws {
        try await withApp(databases: true) { app in
            let breakdown = CompanyBreakdown(docID: "S100VWVY", axis: breakdownAxisBusiness)
            breakdown.code = "7203"
            breakdown.submitDateTime = "2025-06-20 09:00"
            breakdown.payload = BreakdownSnapshotPayload(
                axis: "business", denominator: 0, denominatorTag: "", rows: [],
                sourceKind: "xbrl_facts", needsReview: false, warnings: [])
            breakdown.needsReview = false
            breakdown.source = "xbrl_facts"
            breakdown.contentHash = ""
            breakdown.cacheVersion = businessBreakdownCacheVersion
            try await breakdown.create(on: app.db)

            let financials = CompanyFinancials()
            financials.id = "7203"
            financials.response = try makeDemoFinancialsResponse(
                code: "7203", years: Api.financialsYearsDefault)
            financials.cacheVersion = companyFinancialsCacheVersion
            financials.requestedYears = Api.financialsYearsDefault
            financials.highWater = "2025-06-20 09:00"
            try await financials.create(on: app.db)

            let (status, json) = try await send(app, "/v1/demo/companies/7203/financials")
            #expect(status == .ok)
            #expect(json?["code"] as? String == "7203")
        }
    }

    @Test func demoFinancialsHonorsYearsQueryLikeMainFinancialsRoute() async throws {
        try await withApp(databases: true) { app in
            let breakdown = CompanyBreakdown(docID: "S100VWVY", axis: breakdownAxisBusiness)
            breakdown.code = "7203"
            breakdown.submitDateTime = "2025-06-20 09:00"
            breakdown.payload = BreakdownSnapshotPayload(
                axis: "business", denominator: 0, denominatorTag: "", rows: [],
                sourceKind: "xbrl_facts", needsReview: false, warnings: [])
            breakdown.needsReview = false
            breakdown.source = "xbrl_facts"
            breakdown.contentHash = ""
            breakdown.cacheVersion = businessBreakdownCacheVersion
            try await breakdown.create(on: app.db)

            let financials = CompanyFinancials()
            financials.id = "7203"
            financials.response = try makeDemoFinancialsResponse(code: "7203", years: 5)
            financials.cacheVersion = companyFinancialsCacheVersion
            financials.requestedYears = 5
            financials.highWater = "2025-06-20 09:00"
            try await financials.create(on: app.db)

            let (status, json) = try await send(app, "/v1/demo/companies/7203/financials?years=1")
            #expect(status == .ok)
            let years = try #require(json?["years"] as? [[String: Any]])
            #expect(years.count == 1)
        }
    }

    @Test func demoCompaniesReturnsEmptyArrayWhenQueryMissing() async throws {
        try await withApp(databases: true) { app in
            let (status, json) = try await send(app, "/v1/demo/companies")
            #expect(status == .ok)
            #expect((json?["companies"] as? [[String: Any]])?.isEmpty == true)
        }
    }

    @Test func demoCompaniesFiltersOutMatchesNotInBreakdownPopulation() async throws {
        // EDINET マスタ CSV には実データが載っており「トヨタ」で 7203 がヒットするが、
        // company_breakdowns に行が無ければ母集団外として除外され 200・空配列になる。
        try await withApp(databases: true) { app in
            let (status, json) = try await send(app, "/v1/demo/companies?q=トヨタ")
            #expect(status == .ok)
            #expect((json?["companies"] as? [[String: Any]])?.isEmpty == true)
        }
    }

    @Test func demoCompaniesReturnsMatchInBreakdownPopulation() async throws {
        try await withApp(databases: true) { app in
            let breakdown = CompanyBreakdown(docID: "S100VWVY", axis: breakdownAxisBusiness)
            breakdown.code = "7203"
            breakdown.submitDateTime = "2025-06-20 09:00"
            breakdown.payload = BreakdownSnapshotPayload(
                axis: "business", denominator: 0, denominatorTag: "", rows: [],
                sourceKind: "xbrl_facts", needsReview: false, warnings: [])
            breakdown.needsReview = false
            breakdown.source = "xbrl_facts"
            breakdown.contentHash = ""
            breakdown.cacheVersion = businessBreakdownCacheVersion
            try await breakdown.create(on: app.db)

            let (status, json) = try await send(app, "/v1/demo/companies?q=トヨタ")
            #expect(status == .ok)
            let companies = try #require(json?["companies"] as? [[String: Any]])
            #expect(companies.contains { $0["code"] as? String == "7203" })
        }
    }

    @Test func demoCompaniesIconUrlIsNullWhenNotStored() async throws {
        try await withApp(databases: true) { app in
            let breakdown = CompanyBreakdown(docID: "S100VWVY", axis: breakdownAxisBusiness)
            breakdown.code = "7203"
            breakdown.submitDateTime = "2025-06-20 09:00"
            breakdown.payload = BreakdownSnapshotPayload(
                axis: "business", denominator: 0, denominatorTag: "", rows: [],
                sourceKind: "xbrl_facts", needsReview: false, warnings: [])
            breakdown.needsReview = false
            breakdown.source = "xbrl_facts"
            breakdown.contentHash = ""
            breakdown.cacheVersion = businessBreakdownCacheVersion
            try await breakdown.create(on: app.db)

            let (status, json) = try await send(app, "/v1/demo/companies?q=トヨタ")
            #expect(status == .ok)
            let companies = try #require(json?["companies"] as? [[String: Any]])
            let toyota = try #require(companies.first { $0["code"] as? String == "7203" })
            #expect(toyota["icon_url"] is NSNull)
        }
    }

    @Test func demoCompaniesIncludesCorsHeaderForAllowedOrigin() async throws {
        // sollahiro.com（静的サイト）から api.sollahiro.com への別オリジン fetch を
        // ブラウザに許可させるため、許可オリジンからのリクエストには
        // Access-Control-Allow-Origin を返す必要がある。
        try await withApp(databases: true) { app in
            let (status, _, headers) = try await sendWithHeaders(
                app, "/v1/demo/companies?q=トヨタ", origin: Api.demoAllowedOrigin)
            #expect(status == .ok)
            #expect(headers[.accessControlAllowOrigin].first == Api.demoAllowedOrigin)
        }
    }

    @Test func demoCompaniesOmitsCorsHeaderForDisallowedOrigin() async throws {
        try await withApp(databases: true) { app in
            let (status, _, headers) = try await sendWithHeaders(
                app, "/v1/demo/companies?q=トヨタ", origin: "https://evil.example")
            #expect(status == .ok)
            #expect(headers[.accessControlAllowOrigin].isEmpty)
        }
    }

    @Test func demoFinancialsIncludesCorsHeaderForAllowedOrigin() async throws {
        // /v1/demo/companies だけでなく /v1/demo/companies/{code}/financials も同じ demo
        // グループに属するため、こちらにも CORS ヘッダーが付くことを確認する。
        try await withApp(databases: true) { app in
            let breakdown = CompanyBreakdown(docID: "S100VWVY", axis: breakdownAxisBusiness)
            breakdown.code = "7203"
            breakdown.submitDateTime = "2025-06-20 09:00"
            breakdown.payload = BreakdownSnapshotPayload(
                axis: "business", denominator: 0, denominatorTag: "", rows: [],
                sourceKind: "xbrl_facts", needsReview: false, warnings: [])
            breakdown.needsReview = false
            breakdown.source = "xbrl_facts"
            breakdown.contentHash = ""
            breakdown.cacheVersion = businessBreakdownCacheVersion
            try await breakdown.create(on: app.db)

            let financials = CompanyFinancials()
            financials.id = "7203"
            financials.response = try makeDemoFinancialsResponse(
                code: "7203", years: Api.financialsYearsDefault)
            financials.cacheVersion = companyFinancialsCacheVersion
            financials.requestedYears = Api.financialsYearsDefault
            financials.highWater = "2025-06-20 09:00"
            try await financials.create(on: app.db)

            let (status, _, headers) = try await sendWithHeaders(
                app, "/v1/demo/companies/7203/financials", origin: Api.demoAllowedOrigin)
            #expect(status == .ok)
            #expect(headers[.accessControlAllowOrigin].first == Api.demoAllowedOrigin)
        }
    }

    @Test func nonDemoRouteOmitsCorsHeaderEvenForAllowedOrigin() async throws {
        // CORS は /v1/demo/* グループにのみ適用する。他の /v1 パスに漏れていないことを確認する
        // （sollahiro.com からの Origin であっても、demo 以外は Cloudflare Access 経由のみを想定）。
        try await withApp(databases: true) { app in
            let (status, _, headers) = try await sendWithHeaders(
                app, "/v1/companies?q=7203", origin: Api.demoAllowedOrigin)
            #expect(status == .ok)
            #expect(headers[.accessControlAllowOrigin].isEmpty)
        }
    }

    @Test func euCompaniesSearchEmptyQueryReturnsOkArray() async throws {
        // GET /v1/eu/companies は EU/ESEF preview（skills 未掲載）。空クエリはネットワークなしで []。
        try await withApp { app in
            let request = Request(
                application: app, method: .GET, url: URI(string: "/v1/eu/companies?q="),
                on: app.eventLoopGroup.next())
            let response = try await app.responder.respond(to: request).get()
            #expect(response.status == .ok)
            let body = response.body.string ?? ""
            let data = Data(body.utf8)
            let rows = try JSONSerialization.jsonObject(with: data) as? [Any]
            #expect(rows?.isEmpty == true)
        }
    }

    @Test func euCompaniesSearchReturnsSeededIdentifierHit() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blt-eu-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transport = StubRoutesEsefTransport { _ in
            throw EsefFilingsAPIError.httpStatus(500)
        }
        let client = EsefFilingsAPIClient(transport: transport)
        let esefSearch = EsefSearchService(client: client, cacheDir: dir)
        await esefSearch.seedIndex([
            EsefEntity(identifier: "213800T8PC8Q4FYJZR07", name: "ATLAS COPCO AKTIEBOLAG"),
        ])

        let chatClient = ChatCompletionClient(
            endpoint: ChatCompletionEndpoint(baseURL: "", apiKey: "", model: ""))
        let context = BltServerContext(
            apiKey: "test-key", cacheDir: dir, businessChatClient: chatClient,
            geographyChatClient: chatClient, esefSearch: esefSearch)

        let app = try await Application.make(.testing)
        do {
            try await registerRoutes(app, context: context, cfAccessTeamDomain: nil)
            let request = Request(
                application: app, method: .GET,
                url: URI(string: "/v1/eu/companies?q=213800T8PC8Q4FYJZR07"),
                on: app.eventLoopGroup.next())
            let response = try await app.responder.respond(to: request).get()
            #expect(response.status == .ok)
            let data = Data((response.body.string ?? "").utf8)
            let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            #expect(rows?.count == 1)
            #expect(rows?.first?["identifier"] as? String == "213800T8PC8Q4FYJZR07")
            #expect(rows?.first?["region"] as? String == "EU")
            #expect(rows?.first?["source"] as? String == "ESEF")
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    // MARK: - iconURLs（company_icons バッチ lookup）

    @Test func iconURLsReturnsEmptyWhenPublicBaseURLMissing() async throws {
        try await withApp(databases: true) { app in
            let icon = CompanyIcon(
                code: "7203", sourceURL: "https://global.toyota",
                r2ObjectKey: "company-icons/7203.png", contentType: "image/png",
                cacheVersion: companyIconsCacheVersion)
            try await icon.create(on: app.db)

            let result = await iconURLs(for: ["7203"], db: app.db, environment: [:])
            #expect(result.isEmpty)
        }
    }

    @Test func iconURLsBuildsPublicURLFromOnlyPublicBaseURLWhenStored() async throws {
        // read 経路は BLT_R2_PUBLIC_BASE_URL のみで組み立てる（アップロード用秘密鍵は不要・
        // 最小権限。BLT_R2_ACCOUNT_ID 等を渡さなくても icon_url が組み立てられることを確認する）。
        try await withApp(databases: true) { app in
            let icon = CompanyIcon(
                code: "7203", sourceURL: "https://global.toyota",
                r2ObjectKey: "company-icons/7203.png", contentType: "image/png",
                cacheVersion: companyIconsCacheVersion)
            try await icon.create(on: app.db)

            let env = ["BLT_R2_PUBLIC_BASE_URL": "https://icons.example.com"]
            let result = await iconURLs(for: ["7203", "6758"], db: app.db, environment: env)
            #expect(result["7203"] == "https://icons.example.com/company-icons/7203.png")
            #expect(result["6758"] == nil)
        }
    }

    // MARK: - Feed Update

    @Test func feedUpdatesReturn503WithoutDatabase() async throws {
        try await withApp { app in
            let (status, json) = try await send(app, "/v1/feed/updates")
            #expect(status == .serviceUnavailable)
            #expect(json?["error"] as? String == "財務データベースに接続できません")
        }
    }

    @Test func feedUpdatesReturnsEmptyItemsWhenNoDocuments() async throws {
        try await withApp(databases: true) { app in
            let (status, json) = try await send(app, "/v1/feed/updates")
            #expect(status == .ok)
            #expect(json?["schema_version"] as? Int == Api.feedSchemaVersion)
            #expect(json?["days"] as? Int == 7)
            #expect(json?["date"] as? String == feedDateString())
            let total = json?["total"] as? [String: Any]
            #expect(total?["day"] as? Int == 0)
            #expect(total?["week"] as? Int == 0)
            let items = json?["items"] as? [[String: Any]]
            #expect(items?.isEmpty == true)
        }
    }

    @Test func feedUpdatesReturnsListedFilingsNewestFirst() async throws {
        try await withApp(databases: true) { app in
            try await seedFeedDocument(
                app, id: "S-old", secCode: "72030", filer: "トヨタ自動車株式会社",
                type: "120", submit: "2099-01-01 09:00")
            try await seedFeedDocument(
                app, id: "S-new", secCode: "67580", filer: "ソニーグループ株式会社",
                type: "120", submit: "2099-01-20 09:00")
            try await seedFeedDocument(
                app, id: "S-unlisted", secCode: nil, filer: "某ファンド",
                type: "120", submit: "2099-01-21 09:00")
            try await seedFeedDocument(
                app, id: "S-half", secCode: "99840", filer: "ソフトバンクグループ株式会社",
                type: "160", submit: "2099-01-22 09:00")
            try await seedFeedDocument(
                app, id: "S-ancient", secCode: "72030", filer: "トヨタ自動車株式会社",
                type: "120", submit: "2000-01-01 09:00")

            let (status, json) = try await send(app, "/v1/feed/updates?limit=10")
            #expect(status == .ok)
            #expect(json?["days"] as? Int == 7)
            let items = json?["items"] as? [[String: Any]]
            #expect(items?.compactMap { $0["doc_id"] as? String } == ["S-new", "S-old"])
            let total = json?["total"] as? [String: Any]
            #expect(total?["day"] as? Int == 0)
            #expect(total?["week"] as? Int == 2)
            #expect(items?.first?["code"] as? String == "6758")
            #expect(items?.first?["icon_url"] is NSNull)

            let filtered = try await send(app, "/v1/feed/updates?doc_type=160")
            let half = filtered.json?["items"] as? [[String: Any]]
            #expect(half?.compactMap { $0["doc_id"] as? String } == ["S-half"])
        }
    }

    @Test func feedUpdatesTotalsCountTodayAndPastWeek() async throws {
        try await withApp(databases: true) { app in
            let now = Date()
            let today = feedDateString(now)
            let yesterday = feedDateString(
                utcCalendar.date(byAdding: .day, value: -1, to: now)!)
            let inWeek = feedInclusiveCutoffDateString(days: Api.feedUpdateWeekDays, now: now)
            let outside = feedDateString(
                utcCalendar.date(byAdding: .day, value: -8, to: now)!)
            try await seedFeedDocument(
                app, id: "D-today-1", secCode: "72030", filer: "トヨタ自動車株式会社",
                type: "120", submit: "\(today) 09:00")
            try await seedFeedDocument(
                app, id: "D-today-2", secCode: "67580", filer: "ソニーグループ株式会社",
                type: "120", submit: "\(today) 11:00")
            try await seedFeedDocument(
                app, id: "D-yday", secCode: "99840", filer: "ソフトバンクグループ株式会社",
                type: "120", submit: "\(yesterday) 09:00")
            try await seedFeedDocument(
                app, id: "D-week", secCode: "80350", filer: "東京エレクトロン株式会社",
                type: "120", submit: "\(inWeek) 09:00")
            try await seedFeedDocument(
                app, id: "D-old", secCode: "68610", filer: "キーエンス",
                type: "120", submit: "\(outside) 09:00")

            let (status, json) = try await send(app, "/v1/feed/updates?limit=10")
            #expect(status == .ok)
            #expect(json?["date"] as? String == today)
            let total = json?["total"] as? [String: Any]
            #expect(total?["day"] as? Int == 2)
            #expect(total?["week"] as? Int == 4)
            let items = json?["items"] as? [[String: Any]]
            let ids = items?.compactMap { $0["doc_id"] as? String } ?? []
            #expect(ids.contains("D-today-1"))
            #expect(ids.contains("D-today-2"))
            #expect(ids.contains("D-yday"))
            #expect(ids.contains("D-week"))
            #expect(ids.contains("D-old") == false)
        }
    }

    // MARK: - Feed Trend

    @Test func feedTrendReturns503WhenUnconfigured() async throws {
        try await withApp { app in
            let (status, json) = try await send(app, "/v1/feed/trend")
            #expect(status == .serviceUnavailable)
            #expect(json?["error"] as? String == feedTrendUnavailableMessage)
        }
    }

    @Test func feedTrendReturnsRankingFromStubWithoutHittingNetwork() async throws {
        let stub = StubFeedTrendQueryClient(
            ranking: FeedTrendRanking(items: [
                FeedTrendBucket(code: "7203", count: 9),
                FeedTrendBucket(code: "6758", count: 2),
            ]))
        try await withApp(feedTrendQuery: stub) { app in
            let (status, json) = try await send(app, "/v1/feed/trend?limit=10")
            #expect(status == .ok)
            #expect(json?["schema_version"] as? Int == Api.feedTrendSchemaVersion)
            #expect(json?["days"] as? Int == 7)
            let items = json?["items"] as? [[String: Any]]
            #expect(items?.compactMap { $0["code"] as? String } == ["7203", "6758"])
            #expect(items?.first?["count"] as? Int == 9)
            #expect(items?.first?["icon_url"] is NSNull)
            #expect(json?["by_tool"] == nil)
        }
    }

    @Test func feedTrendCodeFilterIncludesBreakdowns() async throws {
        let stub = StubFeedTrendQueryClient(
            ranking: FeedTrendRanking(
                items: [FeedTrendBucket(code: "7203", count: 4)],
                byTool: [FeedTrendLabelCount(label: "search_companies", count: 3)],
                bySurface: [FeedTrendLabelCount(label: "rest", count: 4)],
                byQuery: [FeedTrendLabelCount(label: "トヨタ", count: 3)]
            ))
        try await withApp(feedTrendQuery: stub) { app in
            let (status, json) = try await send(app, "/v1/feed/trend?code=7203")
            #expect(status == .ok)
            #expect(json?["code"] as? String == "7203")
            let byTool = json?["by_tool"] as? [[String: Any]]
            #expect(byTool?.first?["tool"] as? String == "search_companies")
        }
    }

    @Test func feedTrendRejectsInvalidCode() async throws {
        try await withApp(feedTrendQuery: StubFeedTrendQueryClient(ranking: FeedTrendRanking(items: [])))
        { app in
            let (status, json) = try await send(app, "/v1/feed/trend?code=72030")
            #expect(status == .badRequest)
            #expect(json?["error"] as? String == "code は4桁の銘柄コードです")
        }
    }

    @Test func restSearchAndFinancialsRecordTrendButFeedDoesNot() async throws {
        let sink = RecordingFeedTrendSink()
        try await withApp(feedTrendSink: sink) { app in
            _ = try await send(app, "/v1/companies?q=7203")
            _ = try await send(app, "/v1/companies/6758/financials")
            _ = try await send(app, "/v1/feed/updates")
            _ = try await send(app, "/healthz")
        }
        let tools = sink.events.map(\.tool)
        #expect(tools.contains("search_companies"))
        #expect(tools.contains("get_financial_summary"))
        #expect(tools.contains("get_feed_updates") == false)
        let search = try #require(sink.events.first { $0.tool == "search_companies" })
        #expect(search.surface == "rest")
        #expect(search.code == "7203")
        let financials = try #require(sink.events.first { $0.tool == "get_financial_summary" })
        #expect(financials.code == "6758")
        #expect(financials.q == nil)
    }
}

private func seedFeedDocument(
    _ app: Application, id: String, secCode: String?, filer: String, type: String, submit: String
) async throws {
    let doc = EdinetDocument()
    doc.id = id
    doc.edinetCode = "E00001"
    doc.secCode = secCode
    doc.filerName = filer
    doc.docTypeCode = type
    doc.periodEnd = "2025-03-31"
    doc.submitDateTime = submit
    try await doc.create(on: app.db)
}
