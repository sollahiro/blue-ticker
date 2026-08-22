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
    return BltServerContext(
        apiKey: "test-key", cacheDir: dir, businessChatClient: chatClient,
        geographyChatClient: chatClient)
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
            app.migrations.add(AddAssemblyFingerprintToCompanyFinancials())
            app.migrations.add(CreateCompanyFilingSections())
            app.migrations.add(CreateCompanySegmentBreakdowns())
            app.migrations.add(RenameCompanySegmentBreakdownsToCompanyBreakdowns())
            app.migrations.add(AddNotApplicableReasonToCompanyBreakdowns())
            app.migrations.add(CreateCompanyStatements())
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
/// `extraHeaders` は `MCP-Protocol-Version` 等、クライアント固有ヘッダーの挙動を検証する場合に使う。
private func postMcp(
    _ app: Application, _ bodyObject: [String: Any], extraHeaders: [String: String] = [:]
) async throws -> (status: HTTPResponseStatus, json: [String: Any]?) {
    var headers = HTTPHeaders()
    headers.contentType = .json
    headers.add(name: "Accept", value: "application/json, text/event-stream")
    for (name, value) in extraHeaders {
        headers.add(name: name, value: value)
    }
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

    @Test func getWaterfallReturnsErrorResultWhenNotStored() async throws {
        try await withMcpApp(databases: true) { app in
            let (status, json) = try await postMcp(
                app, toolCallBody(name: "get_waterfall", arguments: ["code": "7203"]))
            #expect(status == .ok)
            let result = json?["result"] as? [String: Any]
            #expect(result?["isError"] as? Bool == true)
            let content = result?["content"] as? [[String: Any]]
            let text = content?.first?["text"] as? String
            #expect(text?.contains("未集計") == true)
        }
    }

    /// issue #132: REST の 404 ボディ拡張と同じ意味論を MCP エラーテキストにも反映する。
    @Test func getBreakdownReturnsReasonWhenNotApplicable() async throws {
        try await withMcpApp(databases: true) { app in
            let row = CompanyBreakdown(docID: "S1", axis: breakdownAxisBusiness)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = BreakdownSnapshotPayload(
                axis: "business", denominator: 0, denominatorTag: "", rows: [],
                sourceKind: breakdownSourceNotApplicable, needsReview: false, warnings: [])
            row.needsReview = false
            row.source = breakdownSourceNotApplicable
            row.contentHash = ""
            row.cacheVersion = businessBreakdownCacheVersion
            row.notApplicableReason = breakdownNotApplicableSingleSegmentDisclosed
            try await row.create(on: app.db)

            let (status, json) = try await postMcp(
                app, toolCallBody(name: "get_breakdown", arguments: ["code": "7203"]))
            #expect(status == .ok)
            let result = json?["result"] as? [String: Any]
            #expect(result?["isError"] as? Bool == true)
            let content = result?["content"] as? [[String: Any]]
            let text = content?.first?["text"] as? String
            let body = text.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            #expect(body?["reason"] as? String == "single_segment_disclosed")
        }
    }

    /// 2026-07-27 品質ゲート通過後、MCP get_breakdown も axis=geography で格納済みデータを返す。
    @Test func getBreakdownReturnsGeographyAxisWhenStored() async throws {
        try await withMcpApp(databases: true) { app in
            let row = CompanyBreakdown(docID: "S1", axis: breakdownAxisGeography)
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = BreakdownSnapshotPayload(
                axis: breakdownAxisGeography, denominator: 1_000_000,
                denominatorTag: "income_statement.sales",
                rows: [
                    BreakdownRowPayload(labelRaw: "日本", label: "日本", amount: 600_000, profit: nil, rowKind: "segment")
                ],
                sourceKind: breakdownSourceGeographyLLM, needsReview: false, warnings: [])
            row.needsReview = false
            row.source = breakdownSourceGeographyLLM
            row.contentHash = ""
            row.cacheVersion = geographyBreakdownCacheVersion
            try await row.create(on: app.db)

            let (status, json) = try await postMcp(
                app,
                toolCallBody(
                    name: "get_breakdown", arguments: ["code": "7203", "axis": "geography"]))
            #expect(status == .ok)
            let result = json?["result"] as? [String: Any]
            #expect(result?["isError"] as? Bool != true)
            let content = result?["content"] as? [[String: Any]]
            let text = content?.first?["text"] as? String
            let body = text.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            #expect(body?["axis"] as? String == breakdownAxisGeography)
        }
    }

    // MARK: - get_statement（Statement 取り込み）

    @Test func getStatementReturnsErrorResultWhenNotStored() async throws {
        try await withMcpApp(databases: true) { app in
            let (status, json) = try await postMcp(
                app, toolCallBody(name: "get_statement", arguments: ["code": "7203"]))
            #expect(status == .ok)
            let result = json?["result"] as? [String: Any]
            #expect(result?["isError"] as? Bool == true)
            let content = result?["content"] as? [[String: Any]]
            let text = content?.first?["text"] as? String
            #expect(text?.contains("未抽出") == true)
        }
    }

    @Test func getStatementReturnsStoredDataSuccessfully() async throws {
        try await withMcpApp(databases: true) { app in
            let row = CompanyStatement()
            row.id = "S1"
            row.code = "7203"
            row.submitDateTime = "2025-06-20 09:00"
            row.payload = StatementYear(
                fyEnd: "2025-03-31", financialPeriod: "通期", docId: "S1",
                balanceSheet: [
                    StatementLineItem(
                        tag: "TotalAssets", label: "資産合計", value: 1_000, unit: "JPY", order: nil,
                        isTotal: true,
                        components: [
                            StatementLineComponent(tag: "CurrentAssets", weight: 1),
                            StatementLineComponent(tag: "CostOfSales", weight: -1),
                        ]),
                    StatementLineItem(
                        tag: "CurrentAssets", label: "流動資産合計", value: 400, unit: "JPY", order: nil),
                ],
                incomeStatement: [], cashFlow: [])
            row.cacheVersion = statementCacheVersion
            try await row.create(on: app.db)

            let (status, json) = try await postMcp(
                app, toolCallBody(name: "get_statement", arguments: ["code": "7203"]))
            #expect(status == .ok)
            let result = json?["result"] as? [String: Any]
            #expect(result?["isError"] as? Bool != true)
            let content = result?["content"] as? [[String: Any]]
            let text = content?.first?["text"] as? String
            let body = text.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let years = body?["years"] as? [[String: Any]]
            #expect(years?.first?["doc_id"] as? String == "S1")

            // is_total/components が REST/MCP の JSON ワイヤーフォーマットまで正しく届くことを確認する
            // （計算リンクベース由来。docs/statement.md）。
            let balanceSheet = years?.first?["balance_sheet"] as? [[String: Any]]
            let totalAssets = balanceSheet?.first { $0["tag"] as? String == "TotalAssets" }
            #expect(totalAssets?["is_total"] as? Bool == true)
            let components = totalAssets?["components"] as? [[String: Any]]
            #expect(components?.map { $0["tag"] as? String } == ["CurrentAssets", "CostOfSales"])
            #expect(components?.map { $0["weight"] as? Int } == [1, -1])

            // is_total が false の行は components が null（存在しない）のままであること。
            let currentAssets = balanceSheet?.first { $0["tag"] as? String == "CurrentAssets" }
            #expect(currentAssets?["is_total"] as? Bool == false)
            #expect(currentAssets?["components"] == nil || currentAssets?["components"] is NSNull)
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

    // MARK: - method を持たない疎通確認 POST（ChatGPT コネクタフローの疎通確認。issue: ChatGPT接続時の400混入）

    /// ChatGPT のコネクタ追加フローが initialize 前に送る空ボディ POST は、JSON-RPC パースエラー
    /// （400）にせず 200 を返す（実測 2026-08-11: 本番ログで 400→200→200 のパターンを確認し、
    /// 空ボディ1件の失敗が後続 initialize/tools_list 成功に関わらずコネクタ全体の失敗表示に
    /// つながっていた）。
    @Test func emptyBodyPostReturnsOkInsteadOfParseError() async throws {
        try await withMcpApp { app in
            var headers = HTTPHeaders()
            headers.contentType = .json
            headers.add(name: "Accept", value: "application/json, text/event-stream")
            let request = Request(
                application: app, method: .POST, url: URI(string: "/"), headers: headers,
                collectedBody: nil, on: app.eventLoopGroup.next())
            let response = try await app.responder.respond(to: request).get()
            #expect(response.status == .ok)
        }
    }

    /// ChatGPT のツール一覧再取得（refresh_actions）フローは、疎通確認として method を持たない
    /// 空オブジェクト `{}` を送ってくる（実測 2026-08-11: 本番で 400→200→200 継続を確認し、ChatGPT
    /// 側で tools/list 取得が 424/-32603「データの形式が正しくありません」として失敗表示されていた。
    /// 空ボディのみを 200 化した従来実装では `{}` を捕捉できていなかった）。空ボディと同様に
    /// 副作用のない疎通確認とみなし 200 を返す。
    @Test func emptyObjectBodyPostReturnsOkInsteadOfParseError() async throws {
        try await withMcpApp { app in
            let (status, _) = try await postMcp(app, [:])
            #expect(status == .ok)
        }
    }

    /// 空配列 `[]`（要素なしの JSON-RPC バッチ）も同様に疎通確認とみなし 200 を返す。
    @Test func emptyArrayBodyPostReturnsOkInsteadOfParseError() async throws {
        try await withMcpApp { app in
            var headers = HTTPHeaders()
            headers.contentType = .json
            headers.add(name: "Accept", value: "application/json, text/event-stream")
            let request = Request(
                application: app, method: .POST, url: URI(string: "/"), headers: headers,
                collectedBody: ByteBuffer(string: "[]"), on: app.eventLoopGroup.next())
            let response = try await app.responder.respond(to: request).get()
            #expect(response.status == .ok)
        }
    }

    /// method を持たない JSON はスルーする一方、JSON として解釈できない真に壊れたボディは
    /// 従来どおり JSON-RPC パースエラー（400）を維持する（疎通確認の誤判定でエラー隠蔽をしない）。
    @Test func malformedJsonBodyStillReturnsParseError() async throws {
        try await withMcpApp { app in
            var headers = HTTPHeaders()
            headers.contentType = .json
            headers.add(name: "Accept", value: "application/json, text/event-stream")
            let request = Request(
                application: app, method: .POST, url: URI(string: "/"), headers: headers,
                collectedBody: ByteBuffer(string: "{not json"), on: app.eventLoopGroup.next())
            let response = try await app.responder.respond(to: request).get()
            #expect(response.status == .badRequest)
        }
    }

    // MARK: - OpenAI 固有の非標準メソッド `server/discover`（issue: ChatGPT接続時の400混入）

    /// ChatGPT（OpenAI 製 MCP クライアント）は initialize 前に MCP 仕様にない `server/discover` を
    /// 送ってくる（実測 2026-08-11: 本番の診断ログで `id: "openai-mcp-discover"` を確認）。
    /// swift-sdk は未知のメソッドとして拒否する。これは意図的にそのまま素通しする（書き換えない）。
    /// discover を `tools/list` として書き換えて 200 + 実ツール一覧を返す実装を試した際、ChatGPT は
    /// その結果を discover 専用スキーマとして検証しているらしく、期待形と一致しないと判断して以降の
    /// initialize/tools_list を送らず、コネクタ追加が `refresh_actions` 424 で打ち切られることを実測
    /// （2026-08-11: ローカル + cloudflared トンネル経由での実機検証）。一方、discover が素の
    /// エラーで失敗した回は ChatGPT が標準ハンドシェイク（initialize→tools/list）へフォールバックし、
    /// コネクタのアクション一覧（8ツール）が正しく表示されることを同じ実機検証で確認済み。
    @Test func serverDiscoverMethodReturnsErrorWithEchoedId() async throws {
        try await withMcpApp { app in
            let (status, json) = try await postMcp(
                app,
                [
                    "jsonrpc": "2.0", "id": "openai-mcp-discover", "method": "server/discover",
                    "params": ["_meta": [String: Any]()],
                ])
            #expect(status == .ok)
            #expect(json?["id"] as? String == "openai-mcp-discover")
            #expect(json?["error"] != nil)
            #expect(json?["result"] == nil)
        }
    }

    // MARK: - MCP-Protocol-Version ヘッダーの未サポート値（issue: ChatGPT接続時の400混入）

    /// ChatGPT は initialize 以外の全リクエストに `MCP-Protocol-Version` ヘッダーを付与するが、値には
    /// initialize でネゴシエーション前の希望バージョン（実測 2026-08-11: "2026-07-28"）をそのまま
    /// 使うことがある。swift-sdk の `ProtocolVersionValidator` はこれを既知バージョン集合と照合し、
    /// 未知の値だと一律 400 にする。ヘッダー自体が無ければデフォルトを仮定して通す仕様のため、
    /// 未サポート値のときはヘッダーごと落として通す。
    @Test func unsupportedProtocolVersionHeaderIsStrippedInsteadOfRejected() async throws {
        try await withMcpApp { app in
            let (status, json) = try await postMcp(
                app,
                ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [String: Any]()],
                extraHeaders: ["MCP-Protocol-Version": "2026-07-28"])
            #expect(status == .ok)
            let tools = (json?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
            #expect((tools ?? []).count == mcpToolCatalog().count)
        }
    }

    // MARK: - initialize の非標準 capabilities.experimental（issue: ChatGPT接続時の400混入）

    /// ChatGPT は initialize の `params.capabilities.experimental` に値がオブジェクトの非標準な
    /// 形（実測 2026-08-11: `{"openai/visibility":{"enabled":true}}`）を送ってくる。swift-sdk の
    /// `Client.Capabilities.experimental` は `[String: String]?` に固定されており、このデコードに
    /// 失敗すると initialize 全体が `-32603 Internal error` になる。本サーバーはクライアント
    /// capabilities を利用しないため、デコードできない形の experimental はキーごと落として通す。
    @Test func initializeWithNonStringExperimentalCapabilitiesSucceeds() async throws {
        try await withMcpApp { app in
            let (status, json) = try await postMcp(
                app,
                [
                    "jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": [
                        "protocolVersion": "2025-11-25",
                        "clientInfo": ["name": "openai-mcp", "version": "1.0.0"],
                        "capabilities": [
                            "experimental": ["openai/visibility": ["enabled": true]]
                        ],
                    ],
                ])
            #expect(status == .ok)
            #expect(json?["error"] == nil)
            #expect((json?["result"] as? [String: Any])?["protocolVersion"] != nil)
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
            #expect(serverInfo?["title"] as? String == bltMcpServerTitle)
            #expect(result?["instructions"] as? String == bltMcpServerInstructions)
        }
    }

    @Test func bothInitializeResponsesReturnSameTitleAndInstructions() async throws {
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
            let firstResult = first.json?["result"] as? [String: Any]
            let firstServerInfo = firstResult?["serverInfo"] as? [String: Any]

            let second = try await postMcp(app, initBody)
            #expect(second.status == .ok)
            let secondResult = second.json?["result"] as? [String: Any]
            let secondServerInfo = secondResult?["serverInfo"] as? [String: Any]

            #expect(firstResult?["instructions"] as? String == bltMcpServerInstructions)
            #expect(secondResult?["instructions"] as? String == bltMcpServerInstructions)
            #expect(firstServerInfo?["title"] as? String == bltMcpServerTitle)
            #expect(secondServerInfo?["title"] as? String == bltMcpServerTitle)
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

    @Test func getFeedUpdatesReturnsEmptyItemsWithoutErrorWhenDatabaseEmpty() async throws {
        try await withMcpApp(databases: true) { app in
            let (status, json) = try await postMcp(
                app, toolCallBody(name: "get_feed_updates", arguments: [:]))
            #expect(status == .ok)
            let result = json?["result"] as? [String: Any]
            #expect(result?["isError"] as? Bool != true)
            let content = result?["content"] as? [[String: Any]]
            let text = content?.first?["text"] as? String
            let body = text.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            #expect(body?["schema_version"] as? Int == Api.feedSchemaVersion)
            #expect(body?["days"] as? Int == 7)
            #expect(body?["date"] as? String == feedDateString())
            let total = body?["total"] as? [String: Any]
            #expect(total?["day"] as? Int == 0)
            #expect(total?["week"] as? Int == 0)
            let items = body?["items"] as? [[String: Any]]
            #expect(items?.isEmpty == true)
        }
    }

    @Test func getFeedUpdatesReturnsListedFilings() async throws {
        try await withMcpApp(databases: true) { app in
            try await seedMcpFeedDocument(
                app, id: "S1", secCode: "72030", filer: "トヨタ自動車株式会社",
                type: "120", submit: "2099-01-20 09:00")
            let (status, json) = try await postMcp(
                app, toolCallBody(name: "get_feed_updates", arguments: ["limit": 10]))
            #expect(status == .ok)
            let result = json?["result"] as? [String: Any]
            #expect(result?["isError"] as? Bool != true)
            let content = result?["content"] as? [[String: Any]]
            let text = content?.first?["text"] as? String
            let body = text.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let items = body?["items"] as? [[String: Any]]
            #expect(items?.first?["code"] as? String == "7203")
            #expect(items?.first?["doc_id"] as? String == "S1")
        }
    }

    @Test func getFeedTrendReturnsErrorWhenDatabaseUnavailable() async throws {
        try await withMcpApp { app in
            let (status, json) = try await postMcp(
                app, toolCallBody(name: "get_feed_trend", arguments: [:]))
            #expect(status == .ok)
            let result = json?["result"] as? [String: Any]
            #expect(result?["isError"] as? Bool == true)
            let content = result?["content"] as? [[String: Any]]
            let text = content?.first?["text"] as? String
            #expect(text?.contains("データベース") == true)
        }
    }
}

private func seedMcpFeedDocument(
    _ app: Application, id: String, secCode: String?, filer: String, type: String, submit: String
) async throws {
    let doc = EdinetDocument()
    doc.id = id
    doc.edinetCode = "E00001"
    doc.secCode = secCode
    doc.filerName = filer
    doc.docTypeCode = type
    doc.periodEnd = "2025-03-31"
    doc.submitDateTime = submit
    try await doc.create(on: app.db)
}
