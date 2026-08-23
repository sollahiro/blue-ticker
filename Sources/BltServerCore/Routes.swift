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
    app.middleware.use(AccessLogMiddleware())
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
                "filing_sections": filingSectionsCacheVersion,
                "filing_sections_min_servable": filingSectionsMinServableVersion,
                "breakdown_business": businessBreakdownCacheVersion,
                "breakdown_business_min_servable": businessBreakdownMinServableVersion,
                "breakdown_geography": geographyBreakdownCacheVersion,
                "breakdown_geography_min_servable": geographyBreakdownMinServableVersion,
                "statement": statementCacheVersion,
                "statement_min_servable": statementMinServableVersion,
            ],
        ], status: .ok)
    }

    // /v1 配下の認証モードを env から決める（docs/api-auth.md / docs/deploy.md）。
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

    // DB（Neon）接続の有無。財務系（financials）は格納済みデータのみを返し、
    // 未接続なら 503・未格納なら 404 とする（ライブ計算へは落とさない＝OOM 回避）。
    // filings は軽量な EDINET 一覧取得のため未格納時のライブ取得を許容する。
    let dbAvailable = !app.databases.ids().isEmpty
    installFeedTrendDefaults(app)

    // GET /v1/companies?q={query}
    // icon_url は company_icons（R2格納済み favicon）のバッチ lookup で合成する（未格納・R2未設定・
    // DB未接続時は null）。searchCompanies 自体は DB 非依存のファサード（BlueTickerCore）のため、
    // ここ（BltServerCore・DB 接続を持つ層）で合成する。
    v1.get("companies") { req async -> Response in
        let q = req.query[String.self, at: "q"] ?? ""
        recordFeedTrend(req.application, surface: "rest", tool: "search_companies", q: q)
        let response = await context.searchCompanies(q: q)
        guard case .ok(let results as [[String: Any]]) = response else {
            return makeResponse(response)
        }
        let codes = results.compactMap { $0["code"] as? String }
        let icons = dbAvailable ? await iconURLs(for: codes, db: req.db) : [:]
        let merged = results.map { row -> [String: Any] in
            var r = row
            r["icon_url"] = icons[row["code"] as? String ?? ""] ?? NSNull()
            return r
        }
        return jsonResponse(merged, status: .ok)
    }

    // GET /v1/eu/companies?q={query}
    // Region EU · Source ESEF の Meta Search（preview）。`/v1/skills`・MCP には未掲載。
    // Icon 保留。entity index 全件運用は ESAP（目安 2027-07）まで保留（roadmap）。
    // 当面は LEI / fxo_id / 名称完全一致（live）。
    v1.get("eu", "companies") { req async -> Response in
        let q = req.query[String.self, at: "q"] ?? ""
        return makeResponse(await context.searchEuCompanies(q: q))
    }

    // GET /v1/skills: MCP tools/list に相当する「いつ使うか／どう呼ぶか」カタログ（一覧）。
    // 正本は BlueTickerCore の apiSkillsCatalog（MCP ツール説明と共有）。
    v1.get("skills") { _ async -> Response in
        jsonResponse(apiSkillsListJSON(), status: .ok)
    }

    // GET /v1/skills/{id}: 1 能力の詳細（parameters / instructions）。
    v1.get("skills", ":id") { req async -> Response in
        let id = req.parameters.get("id") ?? ""
        guard let skill = apiSkill(id: id) else {
            return errorResponse(.notFound, message: "unknown skill: \(id)")
        }
        return jsonResponse(apiSkillDetailJSON(skill), status: .ok)
    }

    // GET /v1/companies/{code}/filings?max_years=5
    // DB（書類同期 `edinet_documents`）に同期済みの書類があればそれを読んで返す
    // （ライブ EDINET 探索なし＝OOM 回避）。未同期銘柄のみライブ探索へフォールバックする。
    v1.get("companies", ":code", "filings") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        recordFeedTrend(req.application, surface: "rest", tool: "get_filings", code: code)
        let maxYears = req.query[Int.self, at: "max_years"] ?? Api.filingsMaxYearsDefault
        return makeResponse(
            await serveFilings(
                code: code, maxYears: maxYears, db: dbAvailable ? req.db : nil,
                logger: req.logger, context: context))
    }

    // GET /v1/companies/{code}/financials?years=5
    // DB（財務取り込み derived キャッシュ company_financials）の格納済み結果のみを返す。
    // 重い XBRL 取得・計算はローカル ingest→Neon に閉じ込め、サーバーは読むだけにして OOM を防ぐ。
    // 未格納・古い・年数不足は 404（バックフィルが追いつけば warm read になる）。
    // ライブ計算へはフォールバックしない（1リクエストでサーバー全体を OOM 落ちさせる地雷を断つ）。
    v1.get("companies", ":code", "financials") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        recordFeedTrend(req.application, surface: "rest", tool: "get_financial_summary", code: code)
        let years = req.query[Int.self, at: "years"] ?? Api.financialsYearsDefault
        return makeStoredDataResponse(
            await serveStoredFinancials(
                code: code, years: years, db: dbAvailable ? req.db : nil, logger: req.logger),
            notFoundMessage: "財務データは未集計です")
    }

    // GET /v1/companies/{code}/waterfall?years=5
    // Waterfall（`docs/feature-tiers.md`）。DB（財務取り込み derived キャッシュ company_financials、
    // financials と同じ格納行）から増減分解フィールド（事業利益ウォーターフォール・ROIC/ROE分解・
    // ネットキャッシュ差分・運転資本/CCC差分）を含めて返す。未格納・古い・年数不足は 404。
    v1.get("companies", ":code", "waterfall") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        recordFeedTrend(req.application, surface: "rest", tool: "get_waterfall", code: code)
        let years = req.query[Int.self, at: "years"] ?? Api.financialsYearsDefault
        return makeStoredDataResponse(
            await serveStoredAnalysis(
                code: code, years: years, db: dbAvailable ? req.db : nil, logger: req.logger),
            notFoundMessage: "財務データは未集計です")
    }

    // GET /v1/companies/{code}/filing-content?doc_id=...&sections=a,b
    // DB（有報セクション取り込み company_filing_sections）の格納済みセクション本文のみを返す。
    // 有報のライブ抽出（9MB DL＋SwiftSoup）は大企業で 1GB OOM を実測したため撤去し、重い抽出は
    // ingest（有報セクション取り込み）へ閉じ込めた。未抽出は 404・DB 非接続は 503（financials と同型・フォールバックなし）。
    v1.get("companies", ":code", "filing-content") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        recordFeedTrend(req.application, surface: "rest", tool: "get_filing_content", code: code)
        let docId = req.query[String.self, at: "doc_id"]
        let sections = req.query[String.self, at: "sections"]
            .map { $0.split(separator: ",").map(String.init) }
        return makeStoredDataResponse(
            await serveStoredFilingSections(
                code: code, docId: docId, sections: sections, db: dbAvailable ? req.db : nil,
                logger: req.logger),
            notFoundMessage: "書類本文は未抽出です")
    }

    // GET /v1/companies/{code}/breakdown?axis=business&doc_id=...
    // DB（内訳取り込み company_breakdowns）の格納済み内訳のみを返す。
    // axis は business / geography / 決定論指標軸（省略時 business）。
    // 内訳取り込み: business/geography は上場全体、決定論指標軸は日経225（docs/breakdown.md）。
    v1.get("companies", ":code", "breakdown") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        recordFeedTrend(req.application, surface: "rest", tool: "get_breakdown", code: code)
        let docId = req.query[String.self, at: "doc_id"]
        let axis = req.query[String.self, at: "axis"] ?? breakdownAxisBusiness
        return makeBreakdownResponse(
            await serveStoredBreakdown(
                code: code, docId: docId, axis: axis, db: dbAvailable ? req.db : nil,
                logger: req.logger),
            notFoundMessage: breakdownNotFoundMessage(axis: axis))
    }

    // GET /v1/companies/{code}/statement?years=5&doc_id=...
    // DB（Statement 取り込み company_statements）の格納済み BS/PL/CF/SS のみを返す。ライブ抽出へはフォールバック
    // しない（filing-sections/breakdowns と同型）。Statement 取り込み の対象母集団は上場全体（日経225は処理順のみ。
    // ingest 側の制約。docs/statement.md）。
    v1.get("companies", ":code", "statement") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        recordFeedTrend(req.application, surface: "rest", tool: "get_statement", code: code)
        let docId = req.query[String.self, at: "doc_id"]
        let years = req.query[Int.self, at: "years"] ?? Api.statementYearsDefault
        return makeStoredDataResponse(
            await serveStoredStatement(
                code: code, docId: docId, years: years, db: dbAvailable ? req.db : nil,
                logger: req.logger),
            notFoundMessage: "財務諸表は未抽出です")
    }

    // GET /v1/companies/{code}/statement/notes?note_type=policy_holding_securities&doc_id=...
    // DB（財務諸表注記取り込み company_statement_notes）の格納済み注記のみを返す。note_type 省略時は 400。
    // `statement` 本体とは別エンドポイント（バージョニング独立。docs/feature-tiers.md）。
    // 財務諸表注記取り込み の対象母集団は日経225構成銘柄のみ（ingest 側の制約）。
    v1.get("companies", ":code", "statement", "notes") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        recordFeedTrend(req.application, surface: "rest", tool: "get_statement_notes", code: code)
        let docId = req.query[String.self, at: "doc_id"]
        guard let noteType = req.query[String.self, at: "note_type"], !noteType.isEmpty else {
            return errorResponse(.badRequest, message: "note_type は必須です")
        }
        return makeStatementNoteResponse(
            await serveStoredStatementNote(
                code: code, docId: docId, noteType: noteType, db: dbAvailable ? req.db : nil,
                logger: req.logger),
            notFoundMessage: "指定された note_type の注記は未算出です")
    }

    // GET /v1/feed/updates?limit=50&doc_type=120
    // 銘柄横断の直近提出書類。sync 済み edinet_documents のみ（ライブ EDINET なし）。
    v1.get("feed", "updates") { req async -> Response in
        let limit = parseFeedLimit(req.query[Int.self, at: "limit"])
        let days = parseFeedDays(req.query[Int.self, at: "days"])
        let docTypes = parseFeedDocTypes(req.query[String.self, at: "doc_type"])
        return await feedJSONResponse(
            await serveFeedUpdates(
                limit: limit, days: days, docTypes: docTypes, db: dbAvailable ? req.db : nil,
                logger: req.logger),
            db: dbAvailable ? req.db : nil)
    }

    // GET /v1/feed/trend?limit=50&days=7&code=
    // 匿名の検索・ツールヒット件数ランキング（Cloudflare Analytics Engine）。書類件数ではない。
    v1.get("feed", "trend") { req async -> Response in
        let limit = parseFeedLimit(req.query[Int.self, at: "limit"])
        let days = parseFeedDays(req.query[Int.self, at: "days"])
        let codeParam = parseFeedTrendCodeParam(req.query[String.self, at: "code"])
        return await feedTrendJSONResponse(
            await serveFeedTrend(
                limit: limit, days: days, codeParam: codeParam,
                client: feedTrendBox(for: req.application).query, logger: req.logger),
            db: dbAvailable ? req.db : nil)
    }

    // POST /（MCP プロトコル。/v1 と同じ認証グループ配下。ルートパスの理由は MCPRoute.swift 参照）
    try await registerMcpRoute(
        authenticated, app: app, context: context, dbAvailable: dbAvailable)

    // /v1/demo/* は sollahiro.com（別オリジンの静的サイト）から直接 fetch されるため、
    // このグループにだけ CORS を許可する（他の /v1 パスは Cloudflare Access 経由のみを想定し、
    // ブラウザからの直接クロスオリジン読み取りを許可しない）。
    let demo = v1.grouped(
        CORSMiddleware(
            configuration: .init(
                allowedOrigin: .any([Api.demoAllowedOrigin]),
                allowedMethods: [.GET],
                allowedHeaders: [.accept, .contentType, .origin]
            )))

    // GET /v1/demo/companies?q=...
    // sollahiro.com/demo（子サイト）の実データ検索専用。company_breakdowns に格納済みの銘柄
    // （内訳取り込み対象＝上場のうち格納済み）に絞って返す。銘柄一覧そのものは
    // 全件列挙エンドポイントを設けず、クエリ必須にして検索窓の候補に留める。
    // このパスは Cloudflare Access の対象外（Bypass ポリシー）にして無認証公開する想定。
    demo.get("demo", "companies") { req async -> Response in
        let q = (req.query[String.self, at: "q"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            return jsonResponse(["companies": []], status: .ok)
        }
        guard dbAvailable else {
            return errorResponse(.serviceUnavailable, message: "検索データベースに接続できません")
        }
        guard case .ok(let candidates as [[String: Any]]) = await context.searchCompanies(q: q)
        else {
            return jsonResponse(["companies": []], status: .ok)
        }
        do {
            let candidateCodes = candidates.compactMap { $0["code"] as? String }
            let eligible = try await demoEligibleCodes(among: candidateCodes, db: req.db)
            let filtered =
                candidates
                .filter { eligible.contains($0["code"] as? String ?? "") }
                .prefix(Api.demoSearchResultLimit)
            let filteredCodes = filtered.compactMap { $0["code"] as? String }
            let icons = await iconURLs(for: filteredCodes, db: req.db)
            let results = filtered.map {
                [
                    "code": $0["code"] ?? "", "name": $0["name"] ?? "",
                    "icon_url": icons[$0["code"] as? String ?? ""] ?? NSNull(),
                ] as [String: Any]
            }
            return jsonResponse(["companies": Array(results)], status: .ok)
        } catch {
            return errorResponse(.serviceUnavailable, message: "検索データベースに接続できません")
        }
    }

    // GET /v1/demo/companies/{code}/financials?years=5
    // sollahiro.com/demo の実データ検索専用。company_breakdowns に格納済みの銘柄（上記と同じ
    // 母集団）限定で通期財務サマリーを返す。半期は対象外。中身は既存 /v1/companies/{code}/financials
    // と同じ格納データを返し、years クエリ（省略時既定値）にも対応する。
    demo.get("demo", "companies", ":code", "financials") { req async -> Response in
        let code = req.parameters.get("code") ?? ""
        let years = req.query[Int.self, at: "years"] ?? Api.financialsYearsDefault
        guard dbAvailable else {
            return errorResponse(.serviceUnavailable, message: "財務データベースに接続できません")
        }
        do {
            guard try await isDemoEligibleCode(code, db: req.db) else {
                return errorResponse(.notFound, message: "デモ対象外の銘柄コードです")
            }
        } catch {
            return errorResponse(.serviceUnavailable, message: "財務データベースに接続できません")
        }
        return makeStoredDataResponse(
            await serveStoredFinancials(
                code: code, years: years, db: req.db, logger: req.logger),
            notFoundMessage: "財務データは未集計です")
    }
}

// MARK: - /v1/demo 専用: company_breakdowns を対象母集団ゲートに使う

/// 候補コード集合のうち company_breakdowns に格納済みの銘柄コードを返す。
/// 対象母集団を単独で全件列挙できるエンドポイントは設けない。
private func demoEligibleCodes(among candidates: [String], db: Database) async throws -> Set<String> {
    guard !candidates.isEmpty else { return [] }
    let rows = try await CompanyBreakdown.query(on: db)
        .filter(\.$code ~~ candidates)
        .all()
    return Set(rows.map { $0.code })
}

/// 単一の銘柄コードが company_breakdowns に格納済みか判定する。
private func isDemoEligibleCode(_ code: String, db: Database) async throws -> Bool {
    try await CompanyBreakdown.query(on: db).filter(\.$code == code).first() != nil
}

/// Feed 応答に REST 専用の `icon_url` を載せる（companies 検索と同じ合成。MCP には出さない）。
private func feedJSONResponse(_ result: StoredDataServeResult, db: Database?) async -> Response {
    switch result {
    case .ok(var body):
        if let db, var items = body["items"] as? [[String: Any]] {
            let codes = items.compactMap { $0["code"] as? String }
            let icons = await iconURLs(for: codes, db: db)
            items = items.map { row in
                var next = row
                next["icon_url"] = icons[row["code"] as? String ?? ""] ?? NSNull()
                return next
            }
            body["items"] = items
        }
        return jsonResponse(body, status: .ok)
    case .notFound:
        return errorResponse(.notFound, message: "フィードを組み立てできません")
    case .dbUnavailable:
        return errorResponse(.serviceUnavailable, message: "財務データベースに接続できません")
    }
}

/// Trend 応答。未設定・Worker 失敗は 503（財務 DB とは別メッセージ）。空ランキングは 200。
private func feedTrendJSONResponse(_ result: FeedTrendServeResult, db: Database?) async -> Response {
    switch result {
    case .ok(var body):
        if let db, var items = body["items"] as? [[String: Any]] {
            let codes = items.compactMap { $0["code"] as? String }
            let icons = await iconURLs(for: codes, db: db)
            items = items.map { row in
                var next = row
                next["icon_url"] = icons[row["code"] as? String ?? ""] ?? NSNull()
                return next
            }
            body["items"] = items
        } else if var items = body["items"] as? [[String: Any]] {
            items = items.map { row in
                var next = row
                next["icon_url"] = NSNull()
                return next
            }
            body["items"] = items
        }
        return jsonResponse(body, status: .ok)
    case .badRequest(let message):
        return errorResponse(.badRequest, message: message)
    case .unavailable:
        return errorResponse(.serviceUnavailable, message: feedTrendUnavailableMessage)
    }
}

/// 候補 code に対応する会社アイコンの公開URLをバッチ取得する。`BLT_R2_PUBLIC_BASE_URL` 未設定・
/// DB クエリ失敗時は空辞書（呼び出し側は該当 code を icon_url: null として扱う）。
/// read 経路のためアップロード用秘密鍵（`R2Config`）は要求しない（`R2PublicURLConfig` のみ使用）。
/// `environment` はテスト注入用（既定はプロセス環境。`resolveBreakdownLLMEndpoint` と同型）。
func iconURLs(
    for codes: [String], db: Database,
    environment: [String: String] = ProcessInfo.processInfo.environment
) async -> [String: String] {
    guard !codes.isEmpty, let urlConfig = R2PublicURLConfig.resolveFromEnvironment(environment) else {
        return [:]
    }
    guard let rows = try? await CompanyIcon.query(on: db).filter(\.$id ~~ codes).all() else {
        return [:]
    }
    var result: [String: String] = [:]
    for row in rows {
        guard let code = row.id else { continue }
        result[code] = urlConfig.publicURL(forKey: row.r2ObjectKey)
    }
    return result
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

/// `waterfall`（Waterfall・年次）の DB 読み取り共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
func serveStoredAnalysis(
    code: String, years: Int, db: Database?, logger: Logger
) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let stored = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadStoredAnalysis(code: code, years: years, db: db)
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

/// `statement` の DB 読み取り共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
/// ライブ抽出へのフォールバックは行わない（有報セクション取り込み と同じ理由。決定論のみだが EDINET DL 自体は重い）。
func serveStoredStatement(
    code: String, docId: String?, years: Int, db: Database?, logger: Logger
) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let stored = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadStoredStatement(code: code, docId: docId, years: years, db: db)
        }
        guard let stored else { return .notFound }
        return .ok(stored)
    } catch {
        return .dbUnavailable
    }
}

/// `breakdown` 専用の DB 読み取り結果。E/F/unknown の reason を 404 応答へ載せるため、他の
/// エンドポイントが共有する `StoredDataServeResult` とは別に持つ（影響範囲を breakdown に限定。issue #132）。
enum BreakdownServeResult {
    /// 成功。JSON 値（`[String: Any]`）。
    case ok([String: Any])
    /// 行はあるが business 軸が解決できなかった（`breakdownNotApplicable*` のいずれか）。404 だが理由を返す。
    case notApplicable(reason: String)
    /// 未格納（404 相当。reason 無し）。
    case notFound
    /// DB 未接続・読み取り失敗（503 相当）。
    case dbUnavailable
}

/// `breakdown` 404 応答の軸別メッセージ（REST/MCP 共用）。
func breakdownNotFoundMessage(axis: String) -> String {
    switch axis {
    case breakdownAxisGeography: return "地域別内訳は未算出です"
    case breakdownAxisEmployees: return "従業員数の内訳は未算出です"
    case breakdownAxisResearchAndDevelopment: return "研究開発費の内訳は未算出です"
    case breakdownAxisGoodwill: return "のれんのセグメント別内訳は未算出です"
    case breakdownAxisSegmentAssets: return "セグメント資産の内訳は未算出です"
    case breakdownAxisDepreciationAndAmortization: return "減価償却費及び償却費の内訳は未算出です"
    case breakdownAxisGoodwillAmortization: return "のれんの償却額の内訳は未算出です"
    case breakdownAxisImpairmentLoss: return "減損損失の内訳は未算出です"
    case breakdownAxisEquityMethodInvestments: return "持分法会計処理される投資の内訳は未算出です"
    case breakdownAxisCapitalExpenditures: return "資本的支出の内訳は未算出です"
    case breakdownAxisCapitalExpendituresOverview: return "設備投資等の概要の内訳は未算出です"
    case breakdownAxisNoncurrentAssetAdditions: return "非流動性資産への追加額の内訳は未算出です"
    default: return "事業別内訳は未算出です"
    }
}

/// `breakdown` の DB 読み取り共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
/// ライブ解決へのフォールバックは行わない（有報セクション取り込み と同じ理由。LLM 呼び出しを serving 経路に持ち込まない）。
func serveStoredBreakdown(
    code: String, docId: String?, axis: String, db: Database?, logger: Logger
) async -> BreakdownServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let stored = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadStoredBreakdown(code: code, docId: docId, axis: axis, db: db)
        }
        switch stored {
        case .found(let value): return .ok(value)
        case .notApplicable(let reason): return .notApplicable(reason: reason)
        case .absent: return .notFound
        }
    } catch {
        return .dbUnavailable
    }
}

/// `statement/notes` 専用の DB 読み取り結果。`BreakdownServeResult` と同型（対象外 reason を
/// 404 応答へ載せるため、他エンドポイントが共有する `StoredDataServeResult` とは別に持つ）。
enum StatementNoteServeResult {
    /// 成功。JSON 値（`[String: Any]`）。
    case ok([String: Any])
    /// 行はあるが当該 note_type が対象外だった（`statementNoteNotApplicable*` のいずれか）。404 だが理由を返す。
    case notApplicable(reason: String)
    /// 未格納（404 相当。reason 無し）。
    case notFound
    /// DB 未接続・読み取り失敗（503 相当）。
    case dbUnavailable
}

/// `statement/notes` の DB 読み取り共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
/// ライブ解決へのフォールバックは行わない（有報セクション取り込み・内訳取り込み・Statement取り込み と同型）。
func serveStoredStatementNote(
    code: String, docId: String?, noteType: String, db: Database?, logger: Logger
) async -> StatementNoteServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let stored = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadStoredStatementNote(code: code, docId: docId, noteType: noteType, db: db)
        }
        switch stored {
        case .found(let value): return .ok(value)
        case .notApplicable(let reason): return .notApplicable(reason: reason)
        case .absent: return .notFound
        }
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

// MARK: - アクセスログミドルウェア

/// リクエストごとの処理時間を構造化ログ（1行）で記録する。Cloudflare Tunnel区間とアプリ処理区間の
/// 切り分け用（MCP速度実測で個別リクエストのサーバー内訳が取れなかったことへの対応）。
/// Authorization・Cookie 等の認証情報はログに含めない（メソッド・パス・ステータス・所要時間のみ）。
private struct AccessLogMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let start = DispatchTime.now()
        let response = try await next.respond(to: request)
        let durationMs = (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        request.logger.notice(
            "http_access",
            metadata: [
                "event": "http_access",
                "method": .string(request.method.rawValue),
                "path": .string(request.url.path),
                "status": .stringConvertible(response.status.code),
                "duration_ms": .stringConvertible(durationMs),
            ])
        return response
    }
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

/// `BreakdownServeResult` を HTTP レスポンスへ変換する。ステータスは 404 のまま維持し
/// （エッジ課金がステータス単位でメーターするため、issue #132 のコメント参照）、notApplicable の
/// ときのみ 404 ボディへ `reason` を追加する。
private func makeBreakdownResponse(
    _ result: BreakdownServeResult, notFoundMessage: String
) -> Response {
    switch result {
    case .ok(let value):
        return jsonResponse(value, status: .ok)
    case .notApplicable(let reason):
        return errorResponse(.notFound, message: notFoundMessage, reason: reason)
    case .notFound:
        return errorResponse(.notFound, message: notFoundMessage)
    case .dbUnavailable:
        return errorResponse(.serviceUnavailable, message: "財務データベースに接続できません")
    }
}

/// `StatementNoteServeResult` を HTTP レスポンスへ変換する。`makeBreakdownResponse` と同型
/// （ステータスは 404 のまま維持し、notApplicable のときのみ 404 ボディへ `reason` を追加する）。
private func makeStatementNoteResponse(
    _ result: StatementNoteServeResult, notFoundMessage: String
) -> Response {
    switch result {
    case .ok(let value):
        return jsonResponse(value, status: .ok)
    case .notApplicable(let reason):
        return errorResponse(.notFound, message: notFoundMessage, reason: reason)
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

/// `{"error": "...", "status": N}` 形式のエラーレスポンス。`reason` を渡すと同じボディに
/// `"reason"` キーを追加する（breakdown の notApplicable 応答用。issue #132）。
private func errorResponse(_ status: HTTPResponseStatus, message: String, reason: String? = nil) -> Response {
    var body: [String: Any] = ["error": message, "status": Int(status.code)]
    if let reason { body["reason"] = reason }
    let data =
        (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    let response = Response(status: status)
    response.headers.contentType = .json
    response.body = .init(data: data)
    return response
}
