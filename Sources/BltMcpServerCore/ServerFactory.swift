// MCP プロトコル層の配線（swift-sdk への依存はこのファイル・Tools.swift に閉じる）。
// ツール名→処理のディスパッチは知らない。呼び出し元（BltServerCore）がハンドラを注入する。

import Foundation
import MCP

/// `POST /mcp` に埋め込むための、ソケットを持たない HTTP トランスポートを組み立てる。
/// 返す `StatelessHTTPServerTransport` の `handleRequest(_:)` を Vapor ルートから直接呼ぶ。
public func makeBltMcpTransport(
    version: String,
    toolCatalog: [Tool] = mcpToolCatalog(),
    callTool: @escaping @Sendable (CallTool.Parameters) async -> CallTool.Result
) async throws -> StatelessHTTPServerTransport {
    let server = Server(
        name: "blt-mcp-server",
        version: version,
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: toolCatalog)
    }
    await server.withMethodHandler(CallTool.self) { params in
        await callTool(params)
    }

    let transport = StatelessHTTPServerTransport()
    try await server.start(transport: transport)
    return transport
}

// MARK: - CallTool.Result ヘルパー

/// JSON-serializable な値（`[String: Any]` 等）を `CallTool.Result` のテキストコンテンツへ変換する。
public func jsonToolResult(_ value: Any) -> CallTool.Result {
    guard JSONSerialization.isValidJSONObject(value),
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8)
    else {
        return errorToolResult("応答の JSON エンコードに失敗しました")
    }
    return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: nil, isError: false)
}

/// エラーメッセージを `isError: true` の `CallTool.Result` へ変換する。
public func errorToolResult(_ message: String) -> CallTool.Result {
    let body: [String: String] = ["error": message]
    let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    let text = String(data: data, encoding: .utf8) ?? "{\"error\":\"unknown\"}"
    return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: nil, isError: true)
}
