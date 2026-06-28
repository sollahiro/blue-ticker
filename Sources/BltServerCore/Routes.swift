// REST API のルート定義（トランスポート層）。
// パスごとに BltServerContext ファサードを呼び、その BltServerResponse を Vapor の Response へ変換する。
// 公開エンドポイント・レスポンス契約は NIO 実装時と不変（docs/blt-server-roadmap.md 参照）。

import BlueTickerCore
import Foundation
import Vapor

// MARK: - ルート登録

/// `/v1/` 配下の REST API ルートを Application へ登録する。
func registerRoutes(_ app: Application, context: BltServerContext) {
    // Vapor デフォルトの ErrorMiddleware（`{"error":true,"reason":...}`）を、
    // 公開契約のエラー封筒（`{"error":"...","status":N}`）に置き換える。
    // 未知パスの 404・メソッド不一致の 405 もこの形式で返る。
    app.middleware = .init()
    app.middleware.use(BltErrorMiddleware())

    // GET /healthz: 認証不要のヘルスチェック（Fly.io / ロードバランサ用）。
    // /v1 の認証より前に、認証グループの外へ登録する。
    app.get("healthz") { _ async -> Response in
        jsonResponse(["status": "ok"], status: .ok)
    }

    // BLT_AUTH_TOKEN が設定されていれば /v1 配下を Bearer 認証で保護する。
    // 未設定なら認証なしで起動する（self-host / ローカル開発）。
    var v1 = app.grouped("v1")
    if let token = Environment.get("BLT_AUTH_TOKEN"), !token.isEmpty {
        v1 = v1.grouped(BltBearerAuthMiddleware(token: token))
    }

    // DB（Neon）接続の有無。接続時は Stage 1/4 の格納済みデータを読み（OOM 回避）、
    // 未接続・未格納のときのみライブ EDINET 取得へフォールバックする。
    let dbAvailable = !app.databases.ids().isEmpty

    // GET /v1/companies?q={query}
    v1.get("companies") { req async -> Response in
        let q = req.query[String.self, at: "q"] ?? ""
        return makeResponse(await context.searchCompanies(q: q))
    }

    // GET /v1/sectors/{sector}/companies?limit=20
    v1.get("sectors", ":sector", "companies") { req async -> Response in
        let sector = req.parameters.get("sector") ?? ""
        let limit = req.query[Int.self, at: "limit"] ?? 20
        return makeResponse(await context.searchBySector(sector: sector, limit: limit))
    }

    // GET /v1/companies/{code}/filings?max_years=5
    // DB（Stage 1 `edinet_documents`）に同期済みの書類があればそれを読んで返す
    // （ライブ EDINET 探索なし＝OOM 回避）。未同期銘柄のみライブ探索へフォールバックする。
    v1.get("companies", ":code", "filings") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        let maxYears = req.query[Int.self, at: "max_years"] ?? 5
        if dbAvailable,
            let records = try? await loadStoredFilingRecords(code: code, db: req.db),
            !records.isEmpty {
            return makeResponse(
                await context.getFilingsFromRecords(code: code, records: records, maxYears: maxYears))
        }
        return makeResponse(await context.getFilings(code: code, maxYears: maxYears))
    }

    // GET /v1/companies/{code}/financials?years=5
    // DB（Stage 4 derived キャッシュ）に現行バージョン・十分な年数で格納済みならそれを返す
    // （EDINET 取得・XBRL パースなし＝OOM 回避）。未格納・古い場合のみライブ計算へフォールバックする。
    v1.get("companies", ":code", "financials") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        let years = req.query[Int.self, at: "years"] ?? 5
        if dbAvailable,
            let stored = try? await loadStoredFinancials(code: code, years: years, db: req.db) {
            return jsonResponse(stored, status: .ok)
        }
        return makeResponse(await context.getFinancials(code: code, years: years))
    }

    // GET /v1/companies/{code}/half-financials?years=3
    // 半期財務サマリ。DB（半期 Stage 4 derived キャッシュ company_half_financials）に現行
    // バージョン・十分な年数で格納済みならそれを返す（EDINET 取得・XBRL パースなし＝OOM 回避）。
    // 未格納・古い場合のみライブ計算へフォールバックする。
    v1.get("companies", ":code", "half-financials") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        let years = req.query[Int.self, at: "years"] ?? 3
        if dbAvailable,
            let stored = try? await loadStoredHalfFinancials(code: code, years: years, db: req.db) {
            return jsonResponse(stored, status: .ok)
        }
        return makeResponse(await context.getHalfFinancials(code: code, years: years))
    }

    // GET /v1/companies/{code}/filing-content?doc_id=...&sections=a,b
    v1.get("companies", ":code", "filing-content") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        let docId = req.query[String.self, at: "doc_id"]
        let sections = req.query[String.self, at: "sections"]
            .map { $0.split(separator: ",").map(String.init) }
        return makeResponse(await context.getFilingContent(code: code, docId: docId, sections: sections))
    }
}

// MARK: - 認証ミドルウェア

/// Authorization: Bearer <token> を検証する。BLT_AUTH_TOKEN が設定されたときのみ /v1 へ適用する。
/// 失敗時は 401 を投げ、BltErrorMiddleware が公開契約のエラー封筒へ変換する。
private struct BltBearerAuthMiddleware: AsyncMiddleware {
    let token: String

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let presented = request.headers.bearerAuthorization?.token,
            constantTimeEquals(presented, token)
        else {
            throw Abort(.unauthorized, reason: "認証が必要です")
        }
        return try await next.respond(to: request)
    }
}

/// トークン比較のタイミング攻撃を避ける定数時間比較（長さの違いのみ早期に返す）。
private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let ab = Array(a.utf8)
    let bb = Array(b.utf8)
    guard ab.count == bb.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
    return diff == 0
}

// MARK: - エラーミドルウェア

/// 投げられたエラー（Vapor の Abort 含む）を公開契約のエラー封筒へ変換する。
/// 未知パス・メソッド不一致など、ルートに到達しないエラーもここで統一形式にする。
private struct BltErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let abort as AbortError {
            return errorResponse(abort.status, message: abort.reason)
        } catch {
            return errorResponse(.internalServerError, message: String(describing: error))
        }
    }
}

// MARK: - レスポンス変換

/// ファサードの戻り値パターン（BltServerResponse）を HTTP レスポンスへ変換する。
/// ステータス対応: ok→200 / notFound→404 / upstreamFailure→502。
private func makeResponse(_ response: BltServerResponse) -> Response {
    switch response {
    case .ok(let value):
        return jsonResponse(value, status: .ok)
    case .notFound(let message):
        return errorResponse(.notFound, message: message)
    case .upstreamFailure(let message):
        return errorResponse(.badGateway, message: message)
    }
}

/// JSON-serializable な値（`[String: Any]` / `[[String: Any]]`）を JSON レスポンスにする。
private func jsonResponse(_ value: Any, status: HTTPResponseStatus) -> Response {
    guard JSONSerialization.isValidJSONObject(value),
        let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
    else {
        return errorResponse(.internalServerError, message: "JSON serialization failed")
    }
    let response = Response(status: status)
    response.headers.contentType = .json
    response.body = .init(data: data)
    return response
}

/// `{"error": "...", "status": N}` 形式のエラーレスポンス。
private func errorResponse(_ status: HTTPResponseStatus, message: String) -> Response {
    let body: [String: Any] = ["error": message, "status": Int(status.code)]
    let data =
        (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    let response = Response(status: status)
    response.headers.contentType = .json
    response.body = .init(data: data)
    return response
}
