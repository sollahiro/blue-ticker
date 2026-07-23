// MCP プロトコル層（BltMcpServerCore）の契約テスト。
// 実サーバー・ソケットを起動せず、StatelessHTTPServerTransport.handleRequest を直接呼んで
// initialize / tools/list / tools/call の JSON-RPC 契約を検証する。

import Foundation
import MCP
import Testing

@testable import BlueTickerCore
@testable import BltMcpServerCore

private let expectedToolNames: Set<String> = [
    "search_companies", "search_by_sector", "get_filings",
    "get_financial_summary", "get_half_financial_summary",
    "get_analysis", "get_half_analysis", "get_filing_content",
    "get_breakdown",
]

private func makeTransport(
    callTool: @escaping @Sendable (CallTool.Parameters) async -> CallTool.Result = { _ in
        jsonToolResult(["ok": true])
    }
) async throws -> StatelessHTTPServerTransport {
    try await makeBltMcpTransport(version: "test-version", callTool: callTool)
}

private func send(
    _ transport: StatelessHTTPServerTransport, _ bodyObject: [String: Any],
    extraHeaders: [String: String] = [:]
) async throws -> (status: Int, json: [String: Any]?) {
    let data = try JSONSerialization.data(withJSONObject: bodyObject)
    var headers = [
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    ]
    headers.merge(extraHeaders) { _, new in new }
    let request = HTTPRequest(
        method: "POST",
        headers: headers,
        body: data,
        path: "/"
    )
    let response = await transport.handleRequest(request)
    var json: [String: Any]?
    if let bodyData = response.bodyData {
        json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    }
    return (response.statusCode, json)
}

@Suite struct McpServerFactoryTests {

    @Test func toolsListReturnsAllExpectedTools() async throws {
        let transport = try await makeTransport()
        let (status, json) = try await send(
            transport, ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [String: Any]()])

        #expect(status == 200)
        let tools = (json?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        let names = Set((tools ?? []).compactMap { $0["name"] as? String })
        #expect(names == expectedToolNames)
    }

    @Test func callToolDispatchesToInjectedHandlerWithParsedArguments() async throws {
        let transport = try await makeTransport(callTool: { params in
            #expect(params.name == "search_companies")
            #expect(params.arguments?["query"]?.stringValue == "toyota")
            return jsonToolResult(["code": "7203", "name": "トヨタ自動車"])
        })
        let (status, json) = try await send(
            transport, [
                "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": ["name": "search_companies", "arguments": ["query": "toyota"]],
            ])

        #expect(status == 200)
        let result = json?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String
        #expect(text?.contains("7203") == true)
        #expect((result?["isError"] as? Bool) != true)
    }

    @Test func callToolErrorResultSetsIsErrorTrue() async throws {
        let transport = try await makeTransport(callTool: { _ in
            errorToolResult("財務データは未集計です")
        })
        let (status, json) = try await send(
            transport, [
                "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": ["name": "get_financial_summary", "arguments": ["code": "9999"]],
            ])

        #expect(status == 200)
        let result = json?["result"] as? [String: Any]
        #expect(result?["isError"] as? Bool == true)
    }

    @Test func unknownMethodReturnsJsonRpcError() async throws {
        let transport = try await makeTransport()
        let (status, json) = try await send(
            transport, ["jsonrpc": "2.0", "id": 4, "method": "not/a/real/method", "params": [String: Any]()])

        #expect(status == 200 || (400...499).contains(status))
        #expect(json?["error"] != nil)
    }

    /// Cloudflare Tunnel は元の Host ヘッダー（例: api.sollahiro.com）をそのまま origin へ転送する。
    /// デフォルトの検証パイプラインは OriginValidator.localhost() を含み、localhost 以外の
    /// Host を 421 で拒否するため、本番相当の Host ヘッダーでも通ることを回帰として固定する。
    @Test func toolsListSucceedsWithNonLocalhostHostHeader() async throws {
        let transport = try await makeTransport()
        let (status, json) = try await send(
            transport, ["jsonrpc": "2.0", "id": 5, "method": "tools/list", "params": [String: Any]()],
            extraHeaders: ["Host": "api.sollahiro.com"])

        #expect(status == 200)
        let tools = (json?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect((tools ?? []).count == expectedToolNames.count)
    }

    /// ApiSkills → MCP 生成の schema 回帰（required / default / items）。
    /// ツール名集合だけでは取りこぼす破壊を固定する。
    @Test func toolSchemasPinRequiredDefaultsAndItems() throws {
        let byName = Dictionary(uniqueKeysWithValues: mcpToolCatalog().map { ($0.name, $0) })

        let search = try #require(byName["search_companies"])
        let searchSchema = try #require(search.inputSchema.objectValue)
        #expect(
            Set((searchSchema["required"]?.arrayValue ?? []).compactMap(\.stringValue)) == ["query"])
        #expect(searchSchema["properties"]?.objectValue?["query"]?.objectValue?["type"]?.stringValue == "string")
        #expect(searchSchema["properties"]?.objectValue?["q"] == nil)

        let sector = try #require(byName["search_by_sector"])
        let sectorSchema = try #require(sector.inputSchema.objectValue)
        #expect(
            Set((sectorSchema["required"]?.arrayValue ?? []).compactMap(\.stringValue)) == ["sector"])
        let limit = try #require(sectorSchema["properties"]?.objectValue?["limit"]?.objectValue)
        #expect(limit["type"]?.stringValue == "integer")
        #expect(limit["default"]?.intValue == Api.sectorCompaniesLimitDefault)

        let financials = try #require(byName["get_financial_summary"])
        let financialsProps = try #require(financials.inputSchema.objectValue?["properties"]?.objectValue)
        #expect(financialsProps["code"] != nil)
        #expect(financialsProps["years"] == nil)

        let filing = try #require(byName["get_filing_content"])
        let sections = try #require(
            filing.inputSchema.objectValue?["properties"]?.objectValue?["sections"]?.objectValue)
        #expect(sections["type"]?.stringValue == "array")
        #expect(sections["items"]?.objectValue?["type"]?.stringValue == "string")

        let breakdown = try #require(byName["get_breakdown"])
        let axis = try #require(
            breakdown.inputSchema.objectValue?["properties"]?.objectValue?["axis"]?.objectValue)
        #expect(axis["type"]?.stringValue == "string")
        // サーバー省略時 business と一致。旧 schema に無かった default を意図的に明示している。
        #expect(axis["default"]?.stringValue == "business")
    }
}
