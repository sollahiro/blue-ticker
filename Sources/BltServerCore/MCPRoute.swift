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
        let httpRequest = MCP.HTTPRequest(
            method: req.method.rawValue,
            headers: Dictionary(
                req.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }),
            body: requestBody,
            path: req.url.path
        )
        let httpResponse = await transport.handleRequest(httpRequest)
        let response =
            reinitializeShimResponse(requestBody: requestBody, response: httpResponse, version: blueTickerVersion)
            ?? httpResponse
        return vaporResponse(from: response)
    }
}

/// 一部の MCP クライアント（Grok 等）はツール呼び出しのたびに `initialize` を再送する。
/// swift-sdk の `Server` はプロセス生存期間で単一インスタンスを共有し、`isInitialized` を
/// 一度きりのフラグとして扱うため、2 回目以降の `initialize` は毎回
/// `-32600 Server is already initialized` で失敗する（`tools/list` / `tools/call` 自体は
/// `strict: false` のためこのフラグの影響を受けず成功する）。initialize の結果は
/// capabilities/serverInfo が固定・protocolVersion もネゴシエーションのみで決定的なため、
/// このケースに限り成功レスポンスへ差し替える。
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

    // capabilities/serverInfo は ServerFactory.swift の makeBltMcpTransport と同じ固定値を使う
    // （BltMcpServerCore が公開する定数を再利用し、二重管理を避ける）。
    let initResult = Initialize.Result(
        protocolVersion: negotiatedVersion,
        capabilities: bltMcpServerCapabilities,
        serverInfo: Server.Info(name: bltMcpServerName, version: version)
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

    case "search_by_sector":
        let sector = args["sector"]?.stringValue ?? ""
        let limit = args["limit"]?.intValue ?? Api.sectorCompaniesLimitDefault
        return mapBltResponse(await context.searchBySector(sector: sector, limit: limit))

    case "get_filings":
        let code = args["code"]?.stringValue ?? ""
        let maxYears = args["max_years"]?.intValue ?? Api.filingsMaxYearsDefault
        return mapBltResponse(
            await serveFilings(
                code: code, maxYears: maxYears, db: db, logger: logger, context: context))

    case "get_financial_summary":
        let code = args["code"]?.stringValue ?? ""
        let years = args["years"]?.intValue ?? Api.financialsYearsDefault
        return mapStoredResult(
            await serveStoredFinancials(code: code, years: years, db: db, logger: logger),
            notFoundMessage: "財務データは未集計です")

    case "get_half_financial_summary":
        let code = args["code"]?.stringValue ?? ""
        let years = args["years"]?.intValue ?? Api.halfFinancialsYearsDefault
        return mapStoredResult(
            await serveStoredHalfFinancials(code: code, years: years, db: db, logger: logger),
            notFoundMessage: "半期財務データは未集計です")

    case "get_filing_content":
        let code = args["code"]?.stringValue ?? ""
        let docId = args["doc_id"]?.stringValue
        let sections = args["sections"]?.arrayValue?.compactMap { $0.stringValue }
        return mapStoredResult(
            await serveStoredFilingSections(
                code: code, docId: docId, sections: sections, db: db, logger: logger),
            notFoundMessage: "書類本文は未抽出です")

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
