// MCP プロトコル層の配線（swift-sdk への依存はこのファイル・Tools.swift に閉じる）。
// ツール名→処理のディスパッチは知らない。呼び出し元（BltServerCore）がハンドラを注入する。

import Foundation
import MCP

/// `Server(name:)` に渡す固定名。MCPRoute.swift の initialize 再送シムでも同じ値を使うため公開する。
public let bltMcpServerName = "blt-mcp-server"

/// `Server(capabilities:)` に渡す固定値。MCPRoute.swift の initialize 再送シムでも同じ値を使うため公開する。
public let bltMcpServerCapabilities = Server.Capabilities(tools: .init(listChanged: false))

/// Vapor の MCP ルート（ルートパス `POST /`）に埋め込むための、ソケットを持たない HTTP トランスポートを組み立てる。
/// 返す `StatelessHTTPServerTransport` の `handleRequest(_:)` を Vapor ルートから直接呼ぶ。
public func makeBltMcpTransport(
    version: String,
    toolCatalog: [Tool] = mcpToolCatalog(),
    callTool: @escaping @Sendable (CallTool.Parameters) async -> CallTool.Result
) async throws -> StatelessHTTPServerTransport {
    let server = Server(
        name: bltMcpServerName,
        version: version,
        capabilities: bltMcpServerCapabilities
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: toolCatalog)
    }
    await server.withMethodHandler(CallTool.self) { params in
        await callTool(params)
    }

    // デフォルトの検証パイプラインは OriginValidator.localhost() を含み、Host ヘッダーが
    // localhost/127.0.0.1/[::1] 以外だと 421 を返す（DNS rebinding 対策）。本サーバーは
    // Cloudflare Tunnel 経由で実ホスト名（例: api.<domain>）がそのまま Host ヘッダーに載って届き、
    // 信頼境界は Cloudflare Access（MCP ルートも /v1 と同じ認証グループ）が担うため、
    // OriginValidator は無効化する（SDK が「cloud deployments」向けと明記する設定）。
    let transport = StatelessHTTPServerTransport(
        validationPipeline: StandardValidationPipeline(validators: [
            OriginValidator.disabled,
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
    )
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
