// MCP プロトコル層の配線（swift-sdk への依存はこのファイル・Tools.swift に閉じる）。
// ツール名→処理のディスパッチは知らない。呼び出し元（BltServerCore）がハンドラを注入する。

import Foundation
import MCP

/// `Server(name:)` に渡す固定名。MCPRoute.swift の initialize 再送シムでも同じ値を使うため公開する。
public let bltMcpServerName = "blt-mcp-server"

/// `Server(capabilities:)` に渡す固定値。MCPRoute.swift の initialize 再送シムでも同じ値を使うため公開する。
public let bltMcpServerCapabilities = Server.Capabilities(tools: .init(listChanged: false))

/// `Server(title:)` に渡す固定表示名。MCPRoute.swift の initialize 再送シムでも同じ値を使うため公開する。
public let bltMcpServerTitle = "Blue Ticker"

/// `Server(instructions:)` / `Initialize.Result(instructions:)` に渡す固定文。
/// MCPRoute.swift の initialize 再送シムでも同じ値を使うため公開する。
public let bltMcpServerInstructions =
    "日本株の財務データ基盤（EDINET 有価証券報告書由来）。銘柄コードが不明な場合は必ず先に search_companies で確定し、返却された code を他ツールの code 引数に使うこと。get_filings=書類一覧と doc_id、get_financial_summary=水準値サマリー、get_waterfall=前年差・要因分解、get_statement=BS/PL/CF/SS 全項目、get_statement_notes=注記（note_type 必須）、get_filing_content=有報本文セクション、get_breakdown=事業別・地域別等の内訳。全ツールは格納済みデータのみを返し、未集計時は isError のエラー応答になる。金額単位は百万円、比率は %。本サーバーで取得できない・未算出の情報を他の情報源（Web検索等）で補うかどうかは、ユーザーに確認してから判断すること。"

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
        title: bltMcpServerTitle,
        instructions: bltMcpServerInstructions,
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

/// JSON-serializable な値（`[String: Any]` 等）を `CallTool.Result` のテキストコンテンツと
/// `structuredContent`（outputSchema 準拠の JSON オブジェクト）へ変換する。
/// 配列など非オブジェクトのトップレベル値は `{"results": ...}` で包む（search_companies 等）。
public func jsonToolResult(_ value: Any) -> CallTool.Result {
    let objectPayload: Any
    if let dict = value as? [String: Any] {
        objectPayload = dict
    } else {
        objectPayload = ["results": value]
    }

    guard JSONSerialization.isValidJSONObject(objectPayload),
        let data = try? JSONSerialization.data(withJSONObject: objectPayload, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8)
    else {
        return errorToolResult("応答の JSON エンコードに失敗しました")
    }

    let structuredContent = try? JSONDecoder().decode(Value.self, from: data)

    return CallTool.Result(
        content: [.text(text: text, annotations: nil, _meta: nil)],
        structuredContent: structuredContent,
        isError: false
    )
}

/// エラーメッセージを `isError: true` の `CallTool.Result` へ変換する。`reason` を渡すと
/// 同じボディに `"reason"` キーを追加する（breakdown の notApplicable 応答用。issue #132）。
public func errorToolResult(_ message: String, reason: String? = nil) -> CallTool.Result {
    var body: [String: String] = ["error": message]
    if let reason { body["reason"] = reason }
    let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    let text = String(data: data, encoding: .utf8) ?? "{\"error\":\"unknown\"}"
    return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: nil, isError: true)
}
