// MCP プロトコルルート（ルートパス `POST /`）の配線。
// BltMcpServerCore が持つツールカタログ・transport を Vapor にアダプトする。
// ツールディスパッチは Routes.swift の共有関数（serveStoredFinancials 等）を呼び、
// REST と DB 読み取りロジックを重複させない。
//
// ルートパスに置く理由: Vapor のルーティングはホスト名では分岐しない（`api.<domain>` と
// `mcp.<domain>` は同じルートテーブルを共有し、Cloudflare Access のポリシーだけが異なる）。
// `mcp.<domain>` は MCP 専用サブドメインのため、パスを付けず `mcp.<domain>` そのもので
// 接続できるようにルートパスへ統一した（`/mcp` は廃止）。

import BlueTickerCore
import BltMcpServerCore
import Fluent
import Foundation
import Logging
import MCP
import Vapor

/// MCP プロトコルをルートグループのルートパス（`POST /`）へ登録する。`group` は Routes.swift 側で
/// 構成済みの認証グループを渡す（`/v1` と同じ認証ポリシーを適用するため）。
func registerMcpRoute(
    _ group: RoutesBuilder, app: Application, context: BltServerContext, dbAvailable: Bool
) async throws {
    // `app.db` は DB 未接続時に取得自体が fatalError するため、dbAvailable が true のときのみ
    // 一度だけ取得する（三項演算子は選択されない分岐を評価しない）。
    let db: Database? = dbAvailable ? app.db : nil
    let logger = app.logger

    let transport = try await makeBltMcpTransport(
        version: blueTickerVersion,
        callTool: { params in
            await dispatchMcpTool(params, context: context, db: db, logger: logger)
        }
    )

    group.post { req async -> Vapor.Response in
        let requestBody = bodyData(from: req)

        // ChatGPT のコネクタ追加・ツール一覧再取得フローは、実ハンドシェイク（initialize）の前に
        // method を持たない JSON の POST（空ボディ・`{}`・`[]`）を送ってくる場合がある。swift-sdk は
        // これを JSON-RPC パースエラー（400）として扱うが、ChatGPT はこの1件が失敗すると後続の
        // initialize/tools_list が成功してもコネクタ全体を失敗表示する。副作用のない疎通確認とみなし、
        // JSON-RPC パイプラインへは渡さず 200 を返す。
        guard let requestBody, !requestBody.isEmpty, !isConnectivityProbeBody(requestBody) else {
            return Vapor.Response(status: .ok)
        }

        // ChatGPT（OpenAI 製 MCP クライアント）は initialize の前に非標準の `server/discover`
        // （MCP 仕様にないメソッド）を送ってくる（実測 2026-08-11: 診断ログで
        // `{"jsonrpc":"2.0","id":"openai-mcp-discover","method":"server/discover",...}` を確認）。
        // swift-sdk はこのメソッドを認識せず JSON-RPC エラー封筒（-32601 methodNotFound、HTTP
        // ステータスは 200）を返す。これは意図的にそのまま返す（書き換えない）。実測 2026-08-11:
        // discover を `tools/list` として書き換えて 200 + 実ツール一覧を返しても、ChatGPT は
        // その結果を discover 専用のスキーマとして検証しているらしく、期待形と一致しないと判断して
        // 以降の initialize/tools_list を送らず `refresh_actions` が 424 で打ち切る（本番の生ログで
        // discover 失敗時に標準ハンドシェイクへフォールバックする挙動を確認済み。当時観測していた
        // 400 は discover 自体ではなく併発していた MCP-Protocol-Version ヘッダーの未サポート値が
        // 原因で、下記の別修正で解消済み）。したがって discover はエラーのまま素通しし、
        // フォールバックさせるのが正しい。
        //
        // ChatGPT は initialize リクエストの `params.capabilities.experimental` に非標準の値
        // （キーの値がオブジェクト。例: `{"openai/visibility":{"enabled":true}}`）を送ってくる。
        // swift-sdk の `Client.Capabilities.experimental` は `[String: String]?` に固定されており、
        // このデコードに失敗すると initialize 全体が `-32603 Internal error` になる
        // （実測 2026-08-11）。本サーバーはクライアント capabilities を利用しないため対象外。
        let dispatchedBody = sanitizeInitializeCapabilities(requestBody) ?? requestBody

        // dispatchedBody が元の requestBody と異なる長さになる場合（initialize の
        // capabilities.experimental 除去等）、元リクエストの Content-Length ヘッダーをそのまま
        // 引き継ぐと実際に送るボディの長さと食い違う。この呼び出し自体は Data を直接渡す
        // インプロセス呼び出しであり swift-sdk は Content-Length を読まないため実害はないが、
        // ヘッダーの整合性を保つため実際の長さへ補正する。
        let httpRequest = MCP.HTTPRequest(
            method: req.method.rawValue,
            headers: dispatchedHeaders(from: req.headers, bodyByteCount: dispatchedBody.count),
            body: dispatchedBody,
            path: req.url.path
        )
        do {
            let httpResponse = try await withOperationTimeout(
                label: "MCPリクエスト処理", seconds: Api.mcpRequestTimeoutSeconds
            ) {
                await transport.handleRequest(httpRequest)
            }
            let response =
                reinitializeShimResponse(requestBody: dispatchedBody, response: httpResponse, version: blueTickerVersion)
                ?? httpResponse
            return vaporResponse(from: response)
        } catch {
            return mcpTimeoutResponse(requestBody: dispatchedBody)
        }
    }
}

/// Vapor の元ヘッダーを SDK へ引き継ぐ辞書へ変換する。`Content-Length` は大文字小文字の異表記が
/// 残ると下流が古い値を読む恐れがあるため、既存の表記ゆれをすべて除去したうえで
/// `bodyByteCount`（実際に送るボディの長さ）で上書きする。
private func dispatchedHeaders(from headers: HTTPHeaders, bodyByteCount: Int) -> [String: String] {
    var result = Dictionary(
        headers.filter { $0.name.lowercased() != "content-length" }.map { ($0.name, $0.value) },
        uniquingKeysWith: { first, _ in first }
    )
    result["Content-Length"] = String(bodyByteCount)

    // ChatGPT は initialize 以外の全リクエスト（server/discover 由来の再送を含む）に
    // `MCP-Protocol-Version` ヘッダーを付与するが、値には initialize でネゴシエーション前に
    // 希望するバージョン（実測 2026-08-11: "2026-07-28"）をそのまま使うことがある。swift-sdk の
    // `ProtocolVersionValidator` はこの値を `MCP.Version.supported`（ハードコード済み既知集合）と
    // 突き合わせ、未知の値だと initialize 以外のリクエストを一律 400 Bad Request にする。ヘッダー
    // 自体が無ければ「デフォルトバージョンを仮定」して素通しする仕様のため、未サポート値のときは
    // ヘッダーごと落とす（値の付け替えはネゴシエーション結果を偽ることになるため行わない）。
    if let headerName = result.keys.first(where: {
        $0.caseInsensitiveCompare(HTTPHeaderName.protocolVersion) == .orderedSame
    }), let value = result[headerName], !MCP.Version.supported.contains(value) {
        result.removeValue(forKey: headerName)
    }
    return result
}

/// initialize リクエストの `params.capabilities.experimental` を、swift-sdk がデコード可能な形
/// （`[String: String]`）に整える。ChatGPT は値がオブジェクトの experimental を送ってくることが
/// あり（実測 2026-08-11: `{"openai/visibility":{"enabled":true}}`）、swift-sdk の
/// `Client.Capabilities.experimental: [String: String]?` はこれをデコードできず initialize
/// 全体が失敗する。本サーバーはクライアント capabilities を利用しないため、デコードできない
/// 形のときは experimental キーごと落として転送する。整形不要（対象外・既に妥当）なら nil を返す
/// （呼び出し側で元のボディへフォールバックする）。
private func sanitizeInitializeCapabilities(_ data: Data) -> Data? {
    guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        json["method"] as? String == Initialize.name,
        var params = json["params"] as? [String: Any],
        var capabilities = params["capabilities"] as? [String: Any],
        let experimental = capabilities["experimental"] as? [String: Any],
        !experimental.values.allSatisfy({ $0 is String })
    else { return nil }

    capabilities.removeValue(forKey: "experimental")
    params["capabilities"] = capabilities
    json["params"] = params
    return try? JSONSerialization.data(withJSONObject: json)
}

/// JSON としては解釈できるが JSON-RPC の `method` を持たない（＝呼び出しとして成立しない）ボディを
/// 疎通確認とみなす。`{}` はオブジェクトとして method 欠落、`[]` は要素なしのバッチとして判定する。
/// JSON として解釈できないボディ（真に壊れたリクエスト）は対象外とし、従来どおり JSON-RPC パースエラーを返す。
private func isConnectivityProbeBody(_ data: Data) -> Bool {
    guard let json = try? JSONSerialization.jsonObject(with: data) else { return false }
    if let object = json as? [String: Any] { return object["method"] == nil }
    if let array = json as? [Any] { return array.isEmpty }
    return false
}

/// MCP ルートの応答待ちが `Api.mcpRequestTimeoutSeconds` を超えたときの JSON-RPC エラーレスポンス。
/// 依存 `modelcontextprotocol/swift-sdk` の `StatelessHTTPServerTransport` に waiter deadline が
/// 実装されておらず（upstream issue #254 / #255、blue-ticker issue #84）、特定条件下で応答待ちの
/// continuation が永久に resume されないことへの緩和策。リクエストの `id` を可能な限り引き継ぎ、
/// JSON-RPC のエラー封筒として返す（`id` が取れない場合は `null`）。
func mcpTimeoutResponse(requestBody: Data?) -> Vapor.Response {
    let id: Any =
        requestBody
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["id"]
        ?? NSNull()
    let envelope: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "error": ["code": -32000, "message": "リクエスト処理がタイムアウトしました"],
    ]
    let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    let response = Vapor.Response(status: .internalServerError)
    response.headers.contentType = .json
    response.body = .init(data: data)
    return response
}

/// 一部の MCP クライアント（Grok 等）はツール呼び出しのたびに `initialize` を再送する。
/// swift-sdk の `Server` はプロセス生存期間で単一インスタンスを共有し、`isInitialized` を
/// 一度きりのフラグとして扱うため、2 回目以降の `initialize` は毎回
/// `-32600 Server is already initialized` で失敗する（`tools/list` / `tools/call` 自体は
/// `strict: false` のためこのフラグの影響を受けず成功する）。initialize の結果は
/// capabilities/serverInfo/title/instructions が固定・protocolVersion もネゴシエーションのみで
/// 決定的なため、このケースに限り成功レスポンスへ差し替える。
private func reinitializeShimResponse(
    requestBody: Data?, response: MCP.HTTPResponse, version: String
) -> MCP.HTTPResponse? {
    guard let requestBody,
        let request = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
        request["method"] as? String == Initialize.name,
        let id = request["id"]
    else { return nil }

    guard let responseBody = response.bodyData,
        let parsed = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
        let error = parsed["error"] as? [String: Any],
        (error["code"] as? Int) == -32600,
        (error["message"] as? String)?.contains("already initialized") == true
    else { return nil }

    let requestedVersion = (request["params"] as? [String: Any])?["protocolVersion"] as? String
    let negotiatedVersion =
        requestedVersion.map { MCP.Version.supported.contains($0) ? $0 : MCP.Version.latest }
        ?? MCP.Version.latest

    // capabilities/serverInfo/title/instructions は ServerFactory.swift の makeBltMcpTransport と
    // 同じ固定値を使う（BltMcpServerCore が公開する定数を再利用し、二重管理を避ける）。
    let initResult = Initialize.Result(
        protocolVersion: negotiatedVersion,
        capabilities: bltMcpServerCapabilities,
        serverInfo: Server.Info(name: bltMcpServerName, version: version, title: bltMcpServerTitle),
        instructions: bltMcpServerInstructions
    )
    guard let resultData = try? JSONEncoder().encode(initResult),
        let resultJSON = try? JSONSerialization.jsonObject(with: resultData)
    else { return nil }

    let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": resultJSON]
    guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
    return .data(data, headers: [HTTPHeaderName.contentType: "application/json"])
}

/// Vapor の `Request.body`（`ByteBuffer?`）を `Data?` へ変換する。
private func bodyData(from req: Vapor.Request) -> Data? {
    guard var buffer = req.body.data, buffer.readableBytes > 0 else { return nil }
    guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return nil }
    return Data(bytes)
}

/// SDK の `HTTPResponse` を Vapor の `Response` へ変換する。
private func vaporResponse(from httpResponse: MCP.HTTPResponse) -> Vapor.Response {
    let response = Vapor.Response(status: HTTPResponseStatus(statusCode: httpResponse.statusCode))
    for (name, value) in httpResponse.headers {
        response.headers.replaceOrAdd(name: name, value: value)
    }
    if let data = httpResponse.bodyData {
        response.body = .init(data: data)
    }
    return response
}

// MARK: - ツールディスパッチ

/// ツール名と引数から REST と共通の内部処理を呼び、結果を `CallTool.Result` へ変換する。
/// REST（Routes.swift）と同じ意味論（financials 系はライブ計算へフォールバックしない等）を踏襲する。
private func dispatchMcpTool(
    _ params: CallTool.Parameters, context: BltServerContext, db: Database?, logger: Logger
) async -> CallTool.Result {
    let args = params.arguments ?? [:]

    switch params.name {
    case "search_companies":
        let q = args["query"]?.stringValue ?? ""
        return mapBltResponse(await context.searchCompanies(q: q))

    case "get_filings":
        let code = args["code"]?.stringValue ?? ""
        let maxYears = args["max_years"]?.intValue ?? Api.filingsMaxYearsDefault
        return mapBltResponse(
            await serveFilings(
                code: code, maxYears: maxYears, db: db, logger: logger, context: context))

    case "get_financial_summary":
        let code = args["code"]?.stringValue ?? ""
        return mapStoredResult(
            await serveStoredFinancials(
                code: code, years: Api.financialsYearsDefault, db: db, logger: logger),
            notFoundMessage: "財務データは未集計です")

    case "get_waterfall":
        let code = args["code"]?.stringValue ?? ""
        return mapStoredResult(
            await serveStoredAnalysis(
                code: code, years: Api.financialsYearsDefault, db: db, logger: logger),
            notFoundMessage: "財務データは未集計です")

    case "get_filing_content":
        let code = args["code"]?.stringValue ?? ""
        let docId = args["doc_id"]?.stringValue
        let sections = args["sections"]?.arrayValue?.compactMap { $0.stringValue }
        return mapStoredResult(
            await serveStoredFilingSections(
                code: code, docId: docId, sections: sections, db: db, logger: logger),
            notFoundMessage: "書類本文は未抽出です")

    case "get_breakdown":
        let code = args["code"]?.stringValue ?? ""
        let docId = args["doc_id"]?.stringValue
        let axis = args["axis"]?.stringValue ?? breakdownAxisBusiness
        return mapBreakdownResult(
            await serveStoredBreakdown(code: code, docId: docId, axis: axis, db: db, logger: logger),
            notFoundMessage: breakdownNotFoundMessage(axis: axis))

    case "get_statement":
        let code = args["code"]?.stringValue ?? ""
        let docId = args["doc_id"]?.stringValue
        let years = args["years"]?.intValue ?? Api.statementYearsDefault
        return mapStoredResult(
            await serveStoredStatement(code: code, docId: docId, years: years, db: db, logger: logger),
            notFoundMessage: "財務諸表は未抽出です")

    case "get_statement_notes":
        let code = args["code"]?.stringValue ?? ""
        let docId = args["doc_id"]?.stringValue
        guard let noteType = args["note_type"]?.stringValue, !noteType.isEmpty else {
            return errorToolResult("note_type は必須です")
        }
        return mapStatementNoteResult(
            await serveStoredStatementNote(code: code, docId: docId, noteType: noteType, db: db, logger: logger),
            notFoundMessage: "指定された note_type の注記は未算出です")

    case "get_feed_updates":
        let limit = parseFeedLimit(args["limit"]?.intValue)
        let days = parseFeedDays(args["days"]?.intValue)
        let docTypes = parseFeedDocTypes(args["doc_type"]?.stringValue)
        return mapStoredResult(
            await serveFeedUpdates(
                limit: limit, days: days, docTypes: docTypes, db: db, logger: logger),
            notFoundMessage: "フィードを組み立てできません")

    default:
        return errorToolResult("Unknown tool: \(params.name)")
    }
}

private func mapBltResponse(_ response: BltServerResponse) -> CallTool.Result {
    switch response {
    case .ok(let value):
        return jsonToolResult(value)
    case .notFound(let message):
        return errorToolResult(message)
    case .upstreamFailure(let message):
        return errorToolResult(message)
    }
}

private func mapStoredResult(
    _ result: StoredDataServeResult, notFoundMessage: String
) -> CallTool.Result {
    switch result {
    case .ok(let value):
        return jsonToolResult(value)
    case .notFound:
        return errorToolResult(notFoundMessage)
    case .dbUnavailable:
        return errorToolResult("財務データベースに接続できません")
    }
}

/// `BreakdownServeResult` → `CallTool.Result`。REST の `makeBreakdownResponse` と同型
/// （notApplicable のときのみエラー本文に `reason` を添える。issue #132）。
private func mapBreakdownResult(
    _ result: BreakdownServeResult, notFoundMessage: String
) -> CallTool.Result {
    switch result {
    case .ok(let value):
        return jsonToolResult(value)
    case .notApplicable(let reason):
        return errorToolResult(notFoundMessage, reason: reason)
    case .notFound:
        return errorToolResult(notFoundMessage)
    case .dbUnavailable:
        return errorToolResult("財務データベースに接続できません")
    }
}

private func mapStatementNoteResult(
    _ result: StatementNoteServeResult, notFoundMessage: String
) -> CallTool.Result {
    switch result {
    case .ok(let value):
        return jsonToolResult(value)
    case .notApplicable(let reason):
        return errorToolResult(notFoundMessage, reason: reason)
    case .notFound:
        return errorToolResult(notFoundMessage)
    case .dbUnavailable:
        return errorToolResult("財務データベースに接続できません")
    }
}
