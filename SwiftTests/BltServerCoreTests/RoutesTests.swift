// REST トランスポート層（Routes.swift）の仕様。
// 認証（Bearer 検証・Cloudflare Access モード・無認証モード）、エラー封筒
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
    return BltServerContext(apiKey: "test-key", cacheDir: dir)
}

/// ルート登録済みの Application を作って body を実行する。
/// databases=true でインメモリ SQLite をマイグレーションし、DB ありの経路を有効にする。
private func withApp(
    databases: Bool = false,
    cfAccessTeamDomain: String? = nil,
    bltAuthToken: String? = nil,
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
            try await app.autoMigrate()
        }
        registerRoutes(
            app, context: makeContext(),
            cfAccessTeamDomain: cfAccessTeamDomain, bltAuthToken: bltAuthToken)
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

/// responder 経由でリクエストを送り、ステータスとデコード済み JSON を返す。
private func send(
    _ app: Application, _ path: String, bearer: String? = nil
) async throws -> (status: HTTPResponseStatus, json: [String: Any]?) {
    var headers = HTTPHeaders()
    if let bearer { headers.bearerAuthorization = BearerAuthorization(token: bearer) }
    let request = Request(
        application: app, method: .GET, url: URI(string: path), headers: headers,
        on: app.eventLoopGroup.next())
    let response = try await app.responder.respond(to: request).get()
    var json: [String: Any]? = nil
    if let string = response.body.string, let data = string.data(using: .utf8) {
        json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    return (response.status, json)
}

@Suite struct RoutesTests {

    // MARK: - healthz（認証不要）

    @Test func healthzRespondsWithoutAuthAndExposesCacheVersions() async throws {
        try await withApp(bltAuthToken: "secret-token") { app in
            let (status, json) = try await send(app, "/healthz")
            #expect(status == .ok)
            #expect(json?["status"] as? String == "ok")
            let versions = json?["cache_versions"] as? [String: Any]
            #expect(versions?["xbrl_facts"] as? String == xbrlFactsCacheVersion)
            #expect(versions?["company_financials"] as? String == companyFinancialsCacheVersion)
            #expect(versions?["company_financials_min_servable"] as? Int == companyFinancialsMinServableVersion)
            #expect(versions?["company_half_financials"] as? String == companyHalfFinancialsCacheVersion)
            #expect(versions?["filing_sections"] as? String == filingSectionsCacheVersion)
            #expect(versions?["filing_sections_min_servable"] as? Int == filingSectionsMinServableVersion)
        }
    }

    // MARK: - 認証（静的 Bearer モード）

    @Test func v1RejectsMissingTokenWith401Envelope() async throws {
        try await withApp(bltAuthToken: "secret-token") { app in
            let (status, json) = try await send(app, "/v1/companies/7203/financials")
            #expect(status == .unauthorized)
            #expect(json?["error"] as? String == "認証が必要です")
            #expect(json?["status"] as? Int == 401)
        }
    }

    @Test func v1RejectsWrongTokenEvenWithSameLength() async throws {
        try await withApp(bltAuthToken: "secret-token") { app in
            let (status, _) = try await send(
                app, "/v1/companies/7203/financials", bearer: "secret-tokem")
            #expect(status == .unauthorized)
        }
    }

    @Test func v1AcceptsCorrectToken() async throws {
        // 認証通過後、DB 非接続の financials は 503 になる（401 でないことが通過の証明）
        try await withApp(bltAuthToken: "secret-token") { app in
            let (status, json) = try await send(
                app, "/v1/companies/7203/financials", bearer: "secret-token")
            #expect(status == .serviceUnavailable)
            #expect(json?["status"] as? Int == 503)
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
        }
    }

    @Test func halfFinancialsReturns404WhenNotStored() async throws {
        try await withApp(databases: true) { app in
            let (status, json) = try await send(app, "/v1/companies/7203/half-financials")
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

    @Test func financialsWithInvalidYearsReturns404() async throws {
        // years <= 0 は無効要求として 404（空 years の 200 を返さない）
        try await withApp(databases: true) { app in
            let (status, _) = try await send(app, "/v1/companies/7203/financials?years=0")
            #expect(status == .notFound)
        }
    }
}
