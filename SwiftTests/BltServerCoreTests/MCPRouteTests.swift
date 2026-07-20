// MCP プロトコルルート（MCPRoute.swift、ルートパス `POST /`）の統合テスト。
// /v1 と同じ認証グループに乗っていること、DB 読み取り共通ロジック（Routes.swift）を
// 経由して REST と同じ意味論（404/503）でツール結果が返ることを、インメモリ Application で検証する。

import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import Vapor

@testable import BlueTickerCore
@testable import BltMcpServerCore
@testable import BltServerCore

private func makeMcpContext() -> BltServerContext {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("blt-mcp-route-tests-\(UUID().uuidString)", isDirectory: true)
    let chatClient = ChatCompletionClient(
        endpoint: ChatCompletionEndpoint(baseURL: "", apiKey: "", model: ""))
    return BltServerContext(apiKey: "test-key", cacheDir: dir, chatClient: chatClient)
}

private func withMcpApp(
    databases: Bool = false,
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
        try await registerRoutes(app, context: makeMcpContext())
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

/// ルートパス（`/`）へ JSON-RPC ボディを POST し、ステータスとデコード済み JSON を返す。
private func postMcp(
    _ app: Application, _ bodyObject: [String: Any]
) async throws -> (status: HTTPResponseStatus, json: [String: Any]?) {
    var headers = HTTPHeaders()
    headers.contentType = .json
    headers.add(name: "Accept", value: "application/json, text/event-stream")
    let bodyData = try JSONSerialization.data(withJSONObject: bodyObject)
    let request = Request(
        application: app, method: .POST, url: URI(string: "/"), headers: headers,
        collectedBody: ByteBuffer(data: bodyData), on: app.eventLoopGroup.next())
    let response = try await app.responder.respond(to: request).get()
    var json: [String: Any]?
    if let string = response.body.string, let data = string.data(using: .utf8) {
        json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    return (response.status, json)
}

/// `Vapor.Response` の本文を JSON デコードする（`mcpTimeoutResponse` 等、直接組み立てたレスポンスの検証用）。
private func decodeJSON(_ response: Response) -> [String: Any]? {
    guard let string = response.body.string, let data = string.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func toolCallBody(name: String, arguments: [String: Any]) -> [String: Any] {
    [
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": ["name": name, "arguments": arguments],
    ]
}

@Suite struct MCPRouteTests {

    // MARK: - DB 読み取り共通ロジック（REST と同じ意味論）

    @Test func getFinancialSummaryReturnsErrorResultWhenNotStored() async throws {
        try await withMcpApp(databases: true) { app in
            let (status, json) = try await postMcp(
                app, toolCallBody(name: "get_financial_summary", arguments: ["code": "7203"]))
            #expect(status == .ok)
            let result = json?["result"] as? [String: Any]
            #expect(result?["isError"] as? Bool == true)
            let content = result?["content"] as? [[String: Any]]
            let text = content?.first?["text"] as? String
            #expect(text?.contains("未集計") == true)
        }
    }

    @Test func getAnalysisReturnsErrorResultWhenNotStored() async throws {
        try await withMcpApp(databases: true) { app in
            let (status, json) = try await postMcp(
                app, toolCallBody(name: "get_analysis", arguments: ["code": "7203"]))
            #expect(status == .ok)
            let result = json?["result"] as? [String: Any]
            #expect(result?["isError"] as? Bool == true)
            let content = result?["content"] as? [[String: Any]]
            let text = content?.first?["text"] as? String
            #expect(text?.contains("未集計") == true)
        }
    }

    @Test func getHalfAnalysisReturnsErrorResultWhenNotStored() async throws {
        try await withMcpApp(databases: true) { app in
            let (status, json) = try await postMcp(
                app, toolCallBody(name: "get_half_analysis", arguments: ["code": "7203"]))
            #expect(status == .ok)
            let result = json?["result"] as? [String: Any]
            #expect(result?["isError"] as? Bool == true)
            let content = result?["content"] as? [[String: Any]]
            let text = content?.first?["text"] as? String
            #expect(text?.contains("未集計") == true)
        }
    }

    @Test func toolsListIsReachableWithoutDatabase() async throws {
        try await withMcpApp { app in
            let (status, json) = try await postMcp(
                app, ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [String: Any]()])
            #expect(status == .ok)
            let tools = (json?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
            #expect((tools ?? []).count == mcpToolCatalog().count)
        }
    }

    // MARK: - initialize 再送（Grok 等、ツール呼び出しのたびに initialize を再送するクライアント対応）

    @Test func secondInitializeRequestSucceedsInsteadOfAlreadyInitializedError() async throws {
        try await withMcpApp { app in
            let initBody: [String: Any] = [
                "jsonrpc": "2.0", "id": 0, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [String: Any](),
                    "clientInfo": ["name": "test-client", "version": "1.0"],
                ],
            ]

            let first = try await postMcp(app, initBody)
            #expect(first.status == .ok)
            #expect(first.json?["error"] == nil)

            let second = try await postMcp(app, initBody)
            #expect(second.status == .ok)
            #expect(second.json?["error"] == nil)
            let result = second.json?["result"] as? [String: Any]
            #expect(result?["protocolVersion"] as? String == "2025-06-18")
            let serverInfo = result?["serverInfo"] as? [String: Any]
            #expect(serverInfo?["name"] as? String == "blt-mcp-server")
        }
    }

    // MARK: - タイムアウト時の JSON-RPC エラーレスポンス（依存SDKのwaiter leak緩和策、Api.mcpRequestTimeoutSeconds参照）

    @Test func mcpTimeoutResponsePreservesRequestIdAndReturnsJsonRpcError() throws {
        let requestBody = try JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": 42, "method": "tools/call"])
        let response = mcpTimeoutResponse(requestBody: requestBody)
        #expect(response.status == .internalServerError)

        let json = try #require(decodeJSON(response))
        #expect(json["id"] as? Int == 42)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32000)
    }

    @Test func mcpTimeoutResponseFallsBackToNullIdWhenBodyIsNil() throws {
        let response = mcpTimeoutResponse(requestBody: nil)
        let json = try #require(decodeJSON(response))
        #expect(json["id"] is NSNull)
    }

    @Test func mcpTimeoutResponseFallsBackToNullIdWhenBodyIsMalformed() throws {
        let response = mcpTimeoutResponse(requestBody: Data("not json".utf8))
        let json = try #require(decodeJSON(response))
        #expect(json["id"] is NSNull)
    }

    @Test func mcpTimeoutResponseFallsBackToNullIdWhenBodyIsNonObjectJson() throws {
        let response = mcpTimeoutResponse(requestBody: Data("[1, 2, 3]".utf8))
        let json = try #require(decodeJSON(response))
        #expect(json["id"] is NSNull)
    }
}
