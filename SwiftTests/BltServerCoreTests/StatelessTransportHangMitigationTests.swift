// 依存 `modelcontextprotocol/swift-sdk`（0.12.1）の StatelessHTTPServerTransport が抱える
// 既知バグ（upstream issue #254/#255・blue-ticker issue #84）に対する緩和策の統合テスト。
//
// MCPRoute.swift のツール単体テスト（MCPRouteTests.swift）とは異なり、ここでは実際の
// StatelessHTTPServerTransport を直接使い、「クライアントが notifications/cancelled を送った
// 場合に元の POST の responseWaiter が resume されずハングする」という診断そのものが正しいこと
// （withOperationTimeout でラップしない生の依存SDK）と、MCPRoute.swift と同じ withOperationTimeout
// でラップすれば同じ状況が有限時間で打ち切られること（緩和策そのもの）の両方を検証する。

import Foundation
import Testing
import MCP

@testable import BltServerCore

@Suite struct StatelessTransportHangMitigationTests {

    private func makeSlowToolTransport() async throws -> StatelessHTTPServerTransport {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.disabled,
                AcceptHeaderValidator(mode: .jsonOnly),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
            ]))
        let server = Server(
            name: "hang-mitigation-test", version: "0",
            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(CallTool.self) { _ in
            // 60秒スリープ =「クライアントがキャンセルする前に応答できない遅いツール」を模擬。
            // `try?` にせず CancellationError をそのまま伝播させる（swift-sdk の Server.swift は
            // ハンドラが CancellationError を throw することで「応答を送らない」と判定するため。
            // ここを `try?` で握りつぶすと、キャンセル後も正常応答を返してしまい issue #255 を
            // 再現できない）。
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return .init(
                content: [.text(text: "late", annotations: nil, _meta: nil)],
                structuredContent: nil, isError: false)
        }
        try await server.start(transport: transport)
        return transport
    }

    private static let jsonRpcHeaders = [
        "Content-Type": "application/json",
        "Accept": "application/json",
    ]

    private func toolCallHttpRequest(id: Int) throws -> MCP.HTTPRequest {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": "slow", "arguments": [String: Any]()],
        ])
        return MCP.HTTPRequest(method: "POST", headers: Self.jsonRpcHeaders, body: body, path: "/")
    }

    private func cancelHttpRequest(requestId: Int) throws -> MCP.HTTPRequest {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "notifications/cancelled",
            "params": ["requestId": requestId],
        ])
        return MCP.HTTPRequest(method: "POST", headers: Self.jsonRpcHeaders, body: body, path: "/")
    }

    /// `Task.detached` の完了結果を非ブロッキングで覗くための箱。
    /// `Task.value` を直接 await すると、ハングしている Task を待つテスト自身も
    /// 一緒にハングしてしまう（本テスト作成時、実際にテストプロセスごと無応答になり
    /// 強制終了する羽目になった＝それ自体が issue #255 の実地証拠でもある）ため、
    /// 「別 Task が裏で走らせた結果を actor 経由で覗く」形にして安全に境界時間を計測する。
    private actor ResultBox {
        private(set) var response: MCP.HTTPResponse?
        func set(_ value: MCP.HTTPResponse) { response = value }
    }

    @Test func rawTransportNeverRespondsAfterCancellationNotification() async throws {
        let transport = try await makeSlowToolTransport()
        let httpRequest = try toolCallHttpRequest(id: 1)
        let box = ResultBox()

        Task.detached {
            let response = await transport.handleRequest(httpRequest)
            await box.set(response)
        }

        try await Task.sleep(nanoseconds: 200_000_000)  // waiter 登録の猶予
        _ = await transport.handleRequest(try cancelHttpRequest(requestId: 1))

        try await Task.sleep(nanoseconds: 2_000_000_000)  // 十分に長い猶予を与えても…

        // 依存SDK単体（withOperationTimeout でラップしない生の呼び出し）では、
        // notifications/cancelled を送っても元の POST の responseWaiter は resume されない
        // （issue #255 の再現）。ここで nil でなくなっていたら upstream が既に直しているということ。
        #expect(await box.response == nil)
    }

    @Test func operationTimeoutWrapperBoundsHangAfterCancellationNotification() async throws {
        let transport = try await makeSlowToolTransport()
        let httpRequest = try toolCallHttpRequest(id: 1)

        let start = Date()
        // MCPRoute.swift の本番コードと同じ withOperationTimeout でラップする
        // （本番は Api.mcpRequestTimeoutSeconds=200 だが、テストを高速に保つため短い値を使う）。
        async let wrapped: MCP.HTTPResponse? = try? await withOperationTimeout(
            label: "MCPリクエスト処理", seconds: 1
        ) {
            await transport.handleRequest(httpRequest)
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        _ = await transport.handleRequest(try cancelHttpRequest(requestId: 1))

        let response = await wrapped
        let elapsed = Date().timeIntervalSince(start)

        // 同じハング状況でも、withOperationTimeout でラップすると
        // 60秒(ハンドラのスリープ)ではなく約1秒(テスト用の短い timeout)で打ち切られる。
        // 境界は 60 秒ハングとの弁別だけが目的で正確な秒数は問わないため、CI ランナー混雑時の
        // スケジューリング遅延を吸収できるよう余裕を持たせる（issue #99: 3秒境界で2回連続 flake）。
        #expect(response == nil)
        #expect(elapsed < 10)
    }
}
