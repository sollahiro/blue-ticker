// 共有 StatelessHTTPServerTransport での JSON-RPC id 隔離（handleBltMcpRequest）のテスト。
// 同じ id の tools/call が同時に届いても、各 HTTP リクエストに自分の応答が元の id 付きで返ることを検証する。

import Foundation
import MCP
import Testing

@testable import BltMcpServerCore

private let jsonRpcHeaders = [
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
]

/// `code` 引数をそのまま返すツール。`delay_ms` だけ待ってから応答する（並列時の完了順を作る）。
private func makeEchoTransport() async throws -> StatelessHTTPServerTransport {
    try await makeBltMcpTransport(version: "test-version") { params in
        let code = params.arguments?["code"]?.stringValue ?? ""
        let delayMs = params.arguments?["delay_ms"]?.intValue ?? 0
        try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        return jsonToolResult(["code": code])
    }
}

private func toolCallRequest(id: Any, code: String, delayMs: Int) throws -> HTTPRequest {
    let body = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": id, "method": "tools/call",
        "params": [
            "name": "get_financial_summary",
            "arguments": ["code": code, "delay_ms": delayMs] as [String: Any],
        ],
    ])
    return HTTPRequest(method: "POST", headers: jsonRpcHeaders, body: body, path: "/")
}

private func responseJSON(_ response: HTTPResponse) -> [String: Any]? {
    response.bodyData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
}

private func returnedCode(_ json: [String: Any]?) -> String? {
    let result = json?["result"] as? [String: Any]
    let structured = result?["structuredContent"] as? [String: Any]
    return structured?["code"] as? String
}

@Suite struct RequestIdIsolationTests {

    /// 実測（2026-10-12）の再現形: 同じ id の並列呼び出しで、先に終わった呼び出しの応答が
    /// 別の呼び出しへ返っていた。id 隔離後は各リクエストに自分の応答が返る。
    @Test func concurrentCallsWithSameIdEachGetOwnResponse() async throws {
        let transport = try await makeEchoTransport()
        let fast = try toolCallRequest(id: 1, code: "4901", delayMs: 50)
        let slow = try toolCallRequest(id: 1, code: "7751", delayMs: 300)

        async let fastResponse = handleBltMcpRequest(transport, fast)
        async let slowResponse = handleBltMcpRequest(transport, slow)
        let (fastJSON, slowJSON) = await (responseJSON(fastResponse), responseJSON(slowResponse))

        #expect(returnedCode(fastJSON) == "4901")
        #expect(returnedCode(slowJSON) == "7751")
        #expect((fastJSON?["id"] as? Int) == 1)
        #expect((slowJSON?["id"] as? Int) == 1)
    }

    @Test func manyConcurrentCallsWithSameStringIdEachGetOwnResponse() async throws {
        let transport = try await makeEchoTransport()
        let codes = ["4901", "6301", "6645", "7751", "8591"]

        // (要求した code, 返った code, 返った id)
        let results = try await withThrowingTaskGroup(of: (String, String?, String?).self) { group in
            for (index, code) in codes.enumerated() {
                let request = try toolCallRequest(id: "call", code: code, delayMs: (codes.count - index) * 30)
                group.addTask {
                    let json = responseJSON(await handleBltMcpRequest(transport, request))
                    return (code, returnedCode(json), json?["id"] as? String)
                }
            }
            var collected: [(String, String?, String?)] = []
            for try await item in group { collected.append(item) }
            return collected
        }

        #expect(results.count == codes.count)
        for (code, returned, id) in results {
            #expect(returned == code)
            #expect(id == "call")
        }
    }

    @Test func originalIdIsRestoredOnJsonRpcError() async throws {
        let transport = try await makeEchoTransport()
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": "req-7", "method": "not/a/real/method", "params": [String: Any](),
        ])
        let response = await handleBltMcpRequest(
            transport, HTTPRequest(method: "POST", headers: jsonRpcHeaders, body: body, path: "/"))

        let json = responseJSON(response)
        #expect(json?["error"] != nil)
        #expect((json?["id"] as? String) == "req-7")
    }

    @Test func notificationIsPassedThroughUnchanged() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "notifications/initialized",
        ])
        let request = HTTPRequest(method: "POST", headers: jsonRpcHeaders, body: body, path: "/")
        #expect(isolateRequestId(request) == nil)

        let transport = try await makeEchoTransport()
        #expect(await handleBltMcpRequest(transport, request).statusCode == 202)
    }

    @Test func isolatedRequestHasUniqueInternalIdAndMatchingContentLength() throws {
        var request = try toolCallRequest(id: 5, code: "7751", delayMs: 0)
        request = HTTPRequest(
            method: request.method,
            headers: request.headers.merging(["content-length": "1"]) { _, new in new },
            body: request.body, path: request.path)

        let first = try #require(isolateRequestId(request))
        let second = try #require(isolateRequestId(request))
        #expect(first.internalId != second.internalId)
        #expect(first.internalId.hasPrefix(bltMcpInternalIdPrefix))
        #expect(String(data: first.originalIdJSON, encoding: .utf8) == "5")

        let rewritten = try #require(first.request.body)
        let json = try #require((try JSONSerialization.jsonObject(with: rewritten)) as? [String: Any])
        #expect((json["id"] as? String) == first.internalId)
        #expect(first.request.headers["Content-Length"] == String(rewritten.count))
        #expect(first.request.headers["content-length"] == nil)
    }
}
