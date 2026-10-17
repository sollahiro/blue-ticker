// 共有 StatelessHTTPServerTransport に渡す JSON-RPC リクエスト id の隔離。
//
// 依存 `modelcontextprotocol/swift-sdk`（0.12.1）の `StatelessHTTPServerTransport` は、
// 応答待ち（`responseWaiters`）を JSON-RPC の `id` だけをキーにした辞書で持つ。本サーバーは
// transport をプロセス全体で 1 つ共有するため、別々の HTTP リクエストが同じ `id` で同時に届くと
// （別クライアント・別セッションが同じ番号から採番する、並列呼び出しで id が重なる等）、後着の
// waiter が先着の waiter を上書きし、先に終わった方の応答が後着の HTTP リクエストへ返る。
// 上書きされた側の waiter は二度と resume されずタイムアウトする。実測（2026-10-12）: 並列の
// get_financial_summary で 7751 の呼び出しに 4901 の応答が返り、4901 側は -32001 で打ち切られた。
//
// 対策として、transport へ渡す前に `id` をリクエストごとに一意な内部 id へ差し替え、応答で元の
// `id` へ戻す。transport・Server からは常に一意な id に見えるため、応答の取り違えが起きない。

import Foundation
import MCP

/// `transport.handleRequest(_:)` の代わりに呼ぶ。JSON-RPC リクエスト（`method` と `id` を持つ単一
/// オブジェクト）のときだけ `id` を一意な内部 id に差し替えて transport へ渡し、応答ボディの `id` を
/// 元の値へ戻す。通知・応答・解釈できないボディは従来どおりそのまま transport へ渡す。
///
/// 副作用: クライアントの `notifications/cancelled` は元の `id` を指すため、差し替え後の実行中
/// リクエストとは一致せずキャンセルされない（ツールは最後まで走り、応答は元の POST に返る）。
/// キャンセル時に応答待ちがハングする既知バグ（upstream issue #255）は、これで踏まなくなる。
public func handleBltMcpRequest(
    _ transport: StatelessHTTPServerTransport, _ request: HTTPRequest
) async -> HTTPResponse {
    guard let isolated = isolateRequestId(request) else {
        return await transport.handleRequest(request)
    }
    let response = await transport.handleRequest(isolated.request)
    return restoreRequestId(
        response, internalId: isolated.internalId, originalIdJSON: isolated.originalIdJSON)
}

/// 内部 id の接頭辞。英数字とハイフンのみで構成し、JSON エンコード時にエスケープされないようにする
/// （応答ボディ上のバイト列置換で元の id へ戻すため）。
let bltMcpInternalIdPrefix = "blt-internal-"

private struct JSONRPCIdEnvelope: Decodable {
    let id: ID
}

/// リクエストの `id` を一意な内部 id に差し替えたリクエストを返す。対象外（リクエストでない・
/// `id` が文字列／整数でない・JSON として解釈できない）なら nil。
/// 戻り値の `originalIdJSON` は元の id の JSON 表現（`"abc"` や `7`）。
func isolateRequestId(
    _ request: HTTPRequest
) -> (request: HTTPRequest, internalId: String, originalIdJSON: Data)? {
    guard let body = request.body,
        var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
        json["method"] is String,
        // `ID` の Decodable は null を "" として読むため、null（不正な id）は対象外にする。
        json["id"] is String || json["id"] is NSNumber,
        let originalId = try? JSONDecoder().decode(JSONRPCIdEnvelope.self, from: body).id,
        let originalIdJSON = try? JSONEncoder().encode(originalId)
    else { return nil }

    let internalId = bltMcpInternalIdPrefix + UUID().uuidString
    json["id"] = internalId
    guard let rewritten = try? JSONSerialization.data(withJSONObject: json) else { return nil }

    var headers = request.headers.filter { $0.key.lowercased() != "content-length" }
    headers["Content-Length"] = String(rewritten.count)
    let isolated = HTTPRequest(
        method: request.method, headers: headers, body: rewritten, path: request.path)
    return (isolated, internalId, originalIdJSON)
}

/// 応答ボディ中の内部 id（JSON 文字列リテラル）を元の id の JSON 表現へ置き換える。
/// 内部 id を含まない応答（バリデーションエラー等）はそのまま返す。
func restoreRequestId(
    _ response: HTTPResponse, internalId: String, originalIdJSON: Data
) -> HTTPResponse {
    guard case .data(var data, let headers) = response,
        let range = data.range(of: Data("\"\(internalId)\"".utf8))
    else { return response }
    data.replaceSubrange(range, with: originalIdJSON)
    return .data(data, headers: headers)
}
