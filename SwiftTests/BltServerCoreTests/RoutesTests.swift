// REST トランスポート層（Routes.swift）の仕様。
// 認証（Cloudflare Access モード・無認証モード）、エラー封筒
// （{"error":...,"status":N}）、DB 非接続時の 503、格納済みデータなしの 404 を、
// インメモリ Application + responder 直叩きで（ネットワーク非依存に）検証する。
// ファサード呼び出しが必要なエンドポイント（companies / filings のライブ探索）は
// EDINET 依存のため対象外とし、DB ゲートで完結するパスのみを見る。

import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import Vapor

@testable import BlueTickerCore
@testable import BltServerCore

private func makeContext() -> BltServerContext {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("blt-routes-tests-\(UUID().uuidString)", isDirectory: true)
    let chatClient = ChatCompletionClient(
        endpoint: ChatCompletionEndpoint(baseURL: "", apiKey: "", model: ""))
    return BltServerContext(apiKey: "test-key", cacheDir: dir, chatClient: chatClient)
}

/// ルート登録済みの Application を作って body を実行する。
/// databases=true でインメモリ SQLite をマイグレーションし、DB ありの経路を有効にする。
private func withApp(
    databases: Bool = false,
    cfAccessTeamDomain: String? = nil,
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
            app.migrations.add(CreateCompanyFilingSections())
            app.migrations.add(CreateCompanySegmentBreakdowns())
            app.migrations.add(RenameCompanySegmentBreakdownsToCompanyBreakdowns())
            app.migrations.add(AddNotApplicableReasonToCompanyBreakdowns())
            try await app.autoMigrate()
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

/// 公開契約 FinancialsResponse を JSON 経由で構築する（Stage4IngestTests.makeResponse と同型）。
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
            #expect(versions?["company_half_financials"] as? String == companyHalfFinancialsCacheVersion)
            #expect(
                versions?["company_half_financials_min_servable"] as? Int
                    == companyHalfFinancialsMinServableVersion)
            #expect(versions?["filing_sections"] as? String == filingSectionsCacheVersion)
            #expect(versions?["filing_sections_min_servable"] as? Int == filingSectionsMinServableVersion)
            #expect(versions?["breakdown"] as? String == breakdownCacheVersion)
            #expect(versions?["breakdown_min_servable"] as? Int == breakdownMinServableVersion)
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
                "/v1/companies/7203/half-financials",
                "/v1/companies/7203/analysis",
                "/v1/companies/7203/half-analysis",
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

    @Test func halfFinancialsReturns404WhenNotStored() async throws {
        try await withApp(databases: true) { app in
            let (status, json) = try await send(app, "/v1/companies/7203/half-financials")
            #expect(status == .notFound)
            #expect(json?["error"] as? String == "半期財務データは未集計です")
        }
    }

    @Test func analysisReturns404WhenNotStored() async throws {
        try await withApp(databases: true) { app in
            let (status, json) = try await send(app, "/v1/companies/7203/analysis")
            #expect(status == .notFound)
            #expect(json?["error"] as? String == "財務データは未集計です")
        }
    }

    @Test func halfAnalysisReturns404WhenNotStored() async throws {
        try await withApp(databases: true) { app in
            let (status, json) = try await send(app, "/v1/companies/7203/half-analysis")
            #expect(status == .notFound)
            #expect(json?["error"] as? String == "半期財務データは未集計です")
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
            row.cacheVersion = breakdownCacheVersion
            row.notApplicableReason = breakdownNotApplicableGeographyOnly
            try await row.create(on: app.db)

            let (status, json) = try await send(app, "/v1/companies/7203/breakdown")
            #expect(status == .notFound)
            #expect(json?["error"] as? String == "事業別内訳は未算出です")
            #expect(json?["reason"] as? String == "geography_only")
        }
    }

    // MARK: - sectors（EDINET マスタ CSV 未配置でも 200・空配列で応答する）

    @Test func sectorsReturnsOkWithArrayBody() async throws {
        try await withApp { app in
            let headers = HTTPHeaders()
            let request = Request(
                application: app, method: .GET, url: URI(string: "/v1/sectors"), headers: headers,
                on: app.eventLoopGroup.next())
            let response = try await app.responder.respond(to: request).get()
            #expect(response.status == .ok)
            let string = try #require(response.body.string)
            let data = try #require(string.data(using: .utf8))
            let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            #expect(array != nil)
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
            #expect((json?["instructions"] as? String)?.contains("Summarize") == true)
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
            row.cacheVersion = breakdownCacheVersion
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
            breakdown.cacheVersion = breakdownCacheVersion
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

    @Test func demoCompaniesReturnsEmptyArrayWhenQueryMissing() async throws {
        try await withApp(databases: true) { app in
            let (status, json) = try await send(app, "/v1/demo/companies")
            #expect(status == .ok)
            #expect((json?["companies"] as? [[String: Any]])?.isEmpty == true)
        }
    }

    @Test func demoCompaniesReturnsOkWithArrayBodyForQuery() async throws {
        // EDINET マスタ CSV 未配置（テスト環境）では検索候補自体が空になるため、母集団フィルタ後も
        // 200・空配列で応答することを確認する（sectorsReturnsOkWithArrayBody と同型）。
        try await withApp(databases: true) { app in
            let (status, json) = try await send(app, "/v1/demo/companies?q=トヨタ")
            #expect(status == .ok)
            #expect(json?["companies"] is [[String: Any]])
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

    @Test func nonDemoRouteOmitsCorsHeaderEvenForAllowedOrigin() async throws {
        // CORS は /v1/demo/* グループにのみ適用する。他の /v1 パスに漏れていないことを確認する
        // （sollahiro.com からの Origin であっても、demo 以外は Cloudflare Access 経由のみを想定）。
        try await withApp(databases: true) { app in
            let (status, _, headers) = try await sendWithHeaders(
                app, "/v1/sectors", origin: Api.demoAllowedOrigin)
            #expect(status == .ok)
            #expect(headers[.accessControlAllowOrigin].isEmpty)
        }
    }
}
