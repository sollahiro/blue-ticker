// REST API のルート定義（トランスポート層）。
// パスごとに BltServerContext ファサードを呼び、その BltServerResponse を Vapor の Response へ変換する。
// 公開エンドポイント・レスポンス契約は NIO 実装時と不変（docs/blt-server-roadmap.md 参照）。

import BlueTickerCore
import BltMcpServerCore
import Fluent
import Foundation
import Logging
import Vapor

// MARK: - ルート登録

/// `/v1/` 配下の REST API ルートと MCP プロトコル（ルートパス `POST /`）を Application へ登録する。
/// 認証設定は既定で env（CF_ACCESS_TEAM_DOMAIN）から読む。
/// テストからは引数で注入する（プロセス環境の書き換えは並列実行と競合するため）。
/// `/v1` と MCP は同じ認証グループ配下に置く（同一の認証ポリシーを適用する）。
func registerRoutes(
    _ app: Application,
    context: BltServerContext,
    cfAccessTeamDomain: String? = Environment.get("CF_ACCESS_TEAM_DOMAIN")
) async throws {
    // Vapor デフォルトの ErrorMiddleware（`{"error":true,"reason":...}`）を、
    // 公開契約のエラー封筒（`{"error":"...","status":N}`）に置き換える。
    // 未知パスの 404・メソッド不一致の 405 もこの形式で返る。
    app.middleware = .init()
    app.middleware.use(BltErrorMiddleware())

    // GET /healthz: 認証不要のヘルスチェック（Fly.io / ロードバランサ用）。
    // /v1 の認証より前に、認証グループの外へ登録する。
    // cache_versions は「今このイメージが話す derived キャッシュバージョン」を外部から確認するための情報
    // （キャッシュバージョンバンプ後に fly deploy を忘れていないかを curl 一発で判定できるようにする）。
    app.get("healthz") { _ async -> Response in
        jsonResponse([
            "status": "ok",
            "cache_versions": [
                "xbrl_facts": xbrlFactsCacheVersion,
                "company_financials": companyFinancialsCacheVersion,
                "company_financials_min_servable": companyFinancialsMinServableVersion,
                "company_half_financials": companyHalfFinancialsCacheVersion,
                "company_half_financials_min_servable": companyHalfFinancialsMinServableVersion,
                "filing_sections": filingSectionsCacheVersion,
                "filing_sections_min_servable": filingSectionsMinServableVersion,
            ],
        ], status: .ok)
    }

    // /v1 配下の認証モードを env から決める（docs/blt-server-roadmap.md「認証」参照）。
    // 優先順位:
    //   1. CF_ACCESS_TEAM_DOMAIN 設定 → Cloudflare Access モード（エッジ信頼 / 方式 A）。
    //      Tunnel + Access がエッジで認証済みのため origin は検証しない。
    //      ※安全要件: 公開ポートを閉じ Cloudflare Tunnel 経由限定にすること（origin 非公開が前提）。
    //   2. 未設定 → 無認証（ローカル開発専用。公開デプロイでは危険なため警告を出す）。
    let authenticated: RoutesBuilder = app
    if cfAccessTeamDomain?.isEmpty == false {
        app.logger.notice(
            "認証モード: Cloudflare Access（エッジ信頼）。Tunnel 経由・公開ポート閉鎖が前提です。")
    } else {
        app.logger.warning("認証モード: 無認証。/v1・MCP は保護されていません（ローカル開発専用）。")
    }
    let v1 = authenticated.grouped("v1")

    // DB（Neon）接続の有無。財務系（financials / half-financials）は格納済みデータのみを返し、
    // 未接続なら 503・未格納なら 404 とする（ライブ計算へは落とさない＝OOM 回避）。
    // filings は軽量な EDINET 一覧取得のため未格納時のライブ取得を許容する。
    let dbAvailable = !app.databases.ids().isEmpty

    // GET /v1/companies?q={query}
    v1.get("companies") { req async -> Response in
        let q = req.query[String.self, at: "q"] ?? ""
        return makeResponse(await context.searchCompanies(q: q))
    }

    // GET /v1/sectors/{sector}/companies?limit=20
    v1.get("sectors", ":sector", "companies") { req async -> Response in
        let sector = req.parameters.get("sector") ?? ""
        let limit = req.query[Int.self, at: "limit"] ?? Api.sectorCompaniesLimitDefault
        return makeResponse(await context.searchBySector(sector: sector, limit: limit))
    }

    // GET /v1/companies/{code}/filings?max_years=5
    // DB（Stage 1 `edinet_documents`）に同期済みの書類があればそれを読んで返す
    // （ライブ EDINET 探索なし＝OOM 回避）。未同期銘柄のみライブ探索へフォールバックする。
    v1.get("companies", ":code", "filings") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        let maxYears = req.query[Int.self, at: "max_years"] ?? Api.filingsMaxYearsDefault
        return makeResponse(
            await serveFilings(
                code: code, maxYears: maxYears, db: dbAvailable ? req.db : nil,
                logger: req.logger, context: context))
    }

    // GET /v1/companies/{code}/financials?years=5
    // DB（Stage 4 derived キャッシュ company_financials）の格納済み結果のみを返す。
    // 重い XBRL 取得・計算はローカル ingest→Neon に閉じ込め、サーバーは読むだけにして OOM を防ぐ。
    // 未格納・古い・年数不足は 404（バックフィルが追いつけば warm read になる）。
    // ライブ計算へはフォールバックしない（1リクエストでサーバー全体を OOM 落ちさせる地雷を断つ）。
    v1.get("companies", ":code", "financials") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        let years = req.query[Int.self, at: "years"] ?? Api.financialsYearsDefault
        return makeStoredDataResponse(
            await serveStoredFinancials(
                code: code, years: years, db: dbAvailable ? req.db : nil, logger: req.logger),
            notFoundMessage: "財務データは未集計です")
    }

    // GET /v1/companies/{code}/half-financials?years=3
    // 半期財務サマリ。DB（半期 Stage 4 derived キャッシュ company_half_financials）の格納済み結果のみ
    // を返す（read で years を半期上限へクランプ）。financials と同じく未格納・古いは 404、ライブ計算へは
    // フォールバックしない。
    v1.get("companies", ":code", "half-financials") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        let years = req.query[Int.self, at: "years"] ?? Api.halfFinancialsYearsDefault
        return makeStoredDataResponse(
            await serveStoredHalfFinancials(
                code: code, years: years, db: dbAvailable ? req.db : nil, logger: req.logger),
            notFoundMessage: "半期財務データは未集計です")
    }

    // GET /v1/companies/{code}/filing-content?doc_id=...&sections=a,b
    // DB（Stage 5 company_filing_sections）の格納済みセクション本文のみを返す。
    // 有報のライブ抽出（9MB DL＋SwiftSoup）は大企業で 1GB OOM を実測したため撤去し、重い抽出は
    // ingest（Stage 5）へ閉じ込めた。未抽出は 404・DB 非接続は 503（financials と同型・フォールバックなし）。
    v1.get("companies", ":code", "filing-content") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        let docId = req.query[String.self, at: "doc_id"]
        let sections = req.query[String.self, at: "sections"]
            .map { $0.split(separator: ",").map(String.init) }
        return makeStoredDataResponse(
            await serveStoredFilingSections(
                code: code, docId: docId, sections: sections, db: dbAvailable ? req.db : nil,
                logger: req.logger),
            notFoundMessage: "書類本文は未抽出です")
    }

    // POST /（MCP プロトコル。/v1 と同じ認証グループ配下。ルートパスの理由は MCPRoute.swift 参照）
    try await registerMcpRoute(
        authenticated, app: app, context: context, dbAvailable: dbAvailable)
}

// MARK: - 格納済みデータ提供ロジック（REST ルートと MCP ツールディスパッチの共通処理）

/// DB 格納済みデータ提供の結果。Vapor に依存しないため MCP ディスパッチからも直接呼べる。
enum StoredDataServeResult {
    /// 成功。JSON 値（`[String: Any]`）。
    case ok([String: Any])
    /// 未格納・未抽出（404 相当）。
    case notFound
    /// DB 未接続・読み取り失敗（503 相当）。
    case dbUnavailable
}

/// `financials` の DB 読み取り共通ロジック。ライブ計算へのフォールバックは行わない（OOM 回避）。
/// `db` は DB 未接続時 `nil` を渡す（`Database` の取得自体が未接続時に fatalError するため、
/// 呼び出し側で dbAvailable ガード済みの値のみ渡すこと。呼び出し例は Routes.swift 内を参照）。
func serveStoredFinancials(
    code: String, years: Int, db: Database?, logger: Logger
) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let stored = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadStoredFinancials(code: code, years: years, db: db)
        }
        guard let stored else { return .notFound }
        return .ok(stored)
    } catch {
        return .dbUnavailable
    }
}

/// `half-financials` の DB 読み取り共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
func serveStoredHalfFinancials(
    code: String, years: Int, db: Database?, logger: Logger
) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let stored = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadStoredHalfFinancials(code: code, years: years, db: db)
        }
        guard let stored else { return .notFound }
        return .ok(stored)
    } catch {
        return .dbUnavailable
    }
}

/// `filing-content` の DB 読み取り共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
func serveStoredFilingSections(
    code: String, docId: String?, sections: [String]?, db: Database?,
    logger: Logger
) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let stored = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadStoredFilingSections(
                code: code, docId: docId, sections: sections, db: db)
        }
        guard let stored else { return .notFound }
        return .ok(stored)
    } catch {
        return .dbUnavailable
    }
}

/// `filings` の DB 優先＋ライブ探索フォールバック共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
func serveFilings(
    code: String, maxYears: Int, db: Database?, logger: Logger,
    context: BltServerContext
) async -> BltServerResponse {
    if let db {
        do {
            let records = try await withDbRetry(
                maxAttempts: Api.dbReadRetryMaxAttempts,
                maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
                logger: logger
            ) {
                try await loadStoredFilingRecords(code: code, db: db)
            }
            if !records.isEmpty {
                return await context.getFilingsFromRecords(
                    code: code, records: records, maxYears: maxYears)
            }
        } catch {
            logger.warning("DB からの filing 取得に失敗、ライブ探索へフォールバック: \(error)")
        }
    }
    return await context.getFilings(code: code, maxYears: maxYears)
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
            request.logger.error("Unhandled error: \(error)")
            return errorResponse(.internalServerError, message: "Internal server error")
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

/// `StoredDataServeResult` を HTTP レスポンスへ変換する。
/// ステータス対応: ok→200 / notFound→404 / dbUnavailable→503。
private func makeStoredDataResponse(
    _ result: StoredDataServeResult, notFoundMessage: String
) -> Response {
    switch result {
    case .ok(let value):
        return jsonResponse(value, status: .ok)
    case .notFound:
        return errorResponse(.notFound, message: notFoundMessage)
    case .dbUnavailable:
        return errorResponse(.serviceUnavailable, message: "財務データベースに接続できません")
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
