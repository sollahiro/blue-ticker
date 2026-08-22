// MCP プロトコル層（BltMcpServerCore）の契約テスト。
// 実サーバー・ソケットを起動せず、StatelessHTTPServerTransport.handleRequest を直接呼んで
// initialize / tools/list / tools/call の JSON-RPC 契約を検証する。

import Foundation
import MCP
import Testing

@testable import BlueTickerCore
@testable import BltMcpServerCore

private let expectedToolNames: Set<String> = [
    "search_companies", "get_filings",
    "get_financial_summary",
    "get_waterfall", "get_filing_content",
    "get_breakdown", "get_statement", "get_statement_notes",
    "get_feed_updates", "get_feed_trend",
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

private func outputSchemaRequiredKeys(_ tool: Tool) -> Set<String> {
    let schema = tool.outputSchema?.objectValue
    return Set((schema?["required"]?.arrayValue ?? []).compactMap(\.stringValue))
}

private func decodeJSONObject(from text: String?) -> [String: Any]? {
    guard let text, let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func jsonObjectsEqual(_ lhs: [String: Any]?, _ rhs: [String: Any]?) -> Bool {
    (lhs as NSDictionary?) == (rhs as NSDictionary?)
}

private func toolResultText(_ result: CallTool.Result) -> String? {
    guard let first = result.content.first else { return nil }
    guard case .text(let text, _, _) = first else { return nil }
    return text
}

private func valueJSONObject(_ value: Value) -> [String: Any]? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
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

    /// ChatGPT plugin Phase 1: 全ツールに title / annotations / outputSchema が付与される。
    @Test func allToolsCarryTitleAnnotationsAndOutputSchema() throws {
        let skillsByTool = Dictionary(
            uniqueKeysWithValues: apiSkillsCatalog().compactMap { skill -> (String, ApiSkill)? in
                guard let tool = skill.mcpTool else { return nil }
                return (tool, skill)
            })

        for tool in mcpToolCatalog() {
            let skill = try #require(skillsByTool[tool.name])
            #expect((tool.title ?? "").isEmpty == false)
            #expect(tool.title == skill.name)
            #expect((tool.description ?? "").isEmpty == false)

            let annotations = tool.annotations
            #expect(annotations.readOnlyHint == true)
            #expect(annotations.destructiveHint == false)
            #expect(annotations.openWorldHint == false)

            let schema = try #require(tool.outputSchema?.objectValue)
            #expect(schema["type"]?.stringValue == "object")
            let required = schema["required"]?.arrayValue ?? []
            #expect(required.isEmpty == false)
        }
    }

    /// outputSchema の top-level required を固定し、意図しないスキーマ変更を検知する。
    @Test func toolOutputSchemasPinRequiredKeySets() throws {
        let byName = Dictionary(uniqueKeysWithValues: mcpToolCatalog().map { ($0.name, $0) })

        #expect(
            outputSchemaRequiredKeys(try #require(byName["search_companies"])) == ["results"])
        #expect(
            outputSchemaRequiredKeys(try #require(byName["get_filings"]))
                == ["code", "name", "filings"])
        let financialRequired: Set<String> = [
            "schema_version", "code", "name", "sector", "market", "currency", "unit", "years",
        ]
        #expect(
            outputSchemaRequiredKeys(try #require(byName["get_financial_summary"])) == financialRequired)
        #expect(outputSchemaRequiredKeys(try #require(byName["get_waterfall"])) == financialRequired)
        #expect(
            outputSchemaRequiredKeys(try #require(byName["get_filing_content"]))
                == ["code", "doc_id", "sections"])
        #expect(
            outputSchemaRequiredKeys(try #require(byName["get_breakdown"]))
                == ["code", "doc_id", "axis", "breakdown"])
        #expect(
            outputSchemaRequiredKeys(try #require(byName["get_statement"]))
                == ["schema_version", "code", "name", "sector", "market", "years"])
        #expect(
            outputSchemaRequiredKeys(try #require(byName["get_statement_notes"]))
                == ["code", "doc_id", "note_type", "note"])
        #expect(
            outputSchemaRequiredKeys(try #require(byName["get_feed_updates"]))
                == ["schema_version", "items"])
        #expect(
            outputSchemaRequiredKeys(try #require(byName["get_feed_trend"]))
                == ["schema_version", "days", "items"])
    }

    /// outputSchema 文字列は全ツールで MCP.Value へデコードできる（壊れた schema はツールを落とさない）。
    @Test func allToolOutputSchemasDecodeSuccessfully() throws {
        for tool in mcpToolCatalog() {
            #expect(tool.outputSchema != nil)
        }
    }

    @Test func callToolObjectPayloadSetsStructuredContentMatchingText() async throws {
        let transport = try await makeTransport(callTool: { _ in
            jsonToolResult(["code": "7203", "name": "トヨタ自動車"])
        })
        let (status, json) = try await send(
            transport, [
                "jsonrpc": "2.0", "id": 6, "method": "tools/call",
                "params": ["name": "get_filings", "arguments": ["code": "7203"]],
            ])

        #expect(status == 200)
        let result = json?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        let textObj = decodeJSONObject(from: content?.first?["text"] as? String)
        let structured = result?["structuredContent"] as? [String: Any]
        #expect(jsonObjectsEqual(textObj, structured))
        #expect(textObj?["code"] as? String == "7203")
    }

    @Test func callToolArrayPayloadWrapsResultsInStructuredContent() async throws {
        let transport = try await makeTransport(callTool: { _ in
            jsonToolResult([
                ["code": "7203", "name": "トヨタ自動車", "sector": "", "market": "", "location": ""],
            ])
        })
        let (status, json) = try await send(
            transport, [
                "jsonrpc": "2.0", "id": 7, "method": "tools/call",
                "params": ["name": "search_companies", "arguments": ["query": "toyota"]],
            ])

        #expect(status == 200)
        let result = json?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        let textObj = decodeJSONObject(from: content?.first?["text"] as? String)
        let structured = result?["structuredContent"] as? [String: Any]
        #expect(jsonObjectsEqual(textObj, structured))
        let results = textObj?["results"] as? [[String: Any]]
        #expect(results?.first?["code"] as? String == "7203")
    }

    @Test func initializeReturnsTitleAndInstructions() async throws {
        let transport = try await makeTransport()
        let (status, json) = try await send(
            transport, [
                "jsonrpc": "2.0", "id": 8, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [String: Any](),
                    "clientInfo": ["name": "test-client", "version": "1.0"],
                ],
            ])

        #expect(status == 200)
        let result = json?["result"] as? [String: Any]
        #expect(result?["instructions"] as? String == bltMcpServerInstructions)
        let serverInfo = result?["serverInfo"] as? [String: Any]
        #expect(serverInfo?["title"] as? String == bltMcpServerTitle)
    }

    /// 実 builder（StatementResponse.jsonObject）の NSNull 入り payload が outputSchema required と整合し、
    /// structuredContent デコードを壊さないことを固定する。
    @Test func getStatementOutputSchemaMatchesRealResponseBuilder() throws {
        let payload = StatementResponse(
            schemaVersion: statementSchemaVersion, code: "7203", name: nil, sector: nil, market: nil,
            years: []
        ).jsonObject()

        let result = jsonToolResult(payload)
        #expect(result.structuredContent != nil)

        let statementTool = try #require(mcpToolCatalog().first { $0.name == "get_statement" })
        let requiredKeys = outputSchemaRequiredKeys(statementTool)

        let structured = try #require(result.structuredContent?.objectValue)
        for key in requiredKeys {
            #expect(structured[key] != nil)
        }
        #expect(structured["name"] == .null)

        let textObj = decodeJSONObject(from: toolResultText(result))
        for key in requiredKeys {
            #expect(textObj?[key] != nil)
        }
        #expect(textObj?["name"] is NSNull)
    }

    /// financials 系の NSNull 入りネスト配列が jsonToolResult → Value デコードを通過する。
    @Test func jsonToolResultDecodesNSNullHeavyPayload() throws {
        let payload: [String: Any] = [
            "schema_version": 1,
            "code": "7203",
            "name": "トヨタ自動車",
            "sector": "自動車",
            "market": "プライム",
            "currency": "JPY",
            "unit": "百万円",
            "years": [["sales": NSNull(), "margin": 12.3]],
        ]

        let result = jsonToolResult(payload)
        #expect(result.structuredContent != nil)

        let textObj = decodeJSONObject(from: toolResultText(result))
        let structuredObj = valueJSONObject(try #require(result.structuredContent))
        #expect(jsonObjectsEqual(textObj, structuredObj))
        let years = textObj?["years"] as? [[String: Any]]
        #expect(years?.first?["sales"] is NSNull)
    }
}
