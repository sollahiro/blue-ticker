// チャット（POST /v1/chat）の仕様。モデルは偽物を差し込み、ネットワークに依存しない。
// SSE パーサ・データ整形・ツール往復と上限・HTTP の入口（503 / 400 / SSE）を見る。

import Foundation
import Logging
import Testing
import Vapor

@testable import BlueTickerCore
@testable import BltServerCore

// MARK: - 偽物

/// 呼ばれるたびに台本の次のイベント列を返し、受け取ったリクエストを記録する。
private final class ScriptedChatModel: ChatModelStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [[ChatModelEvent]]
    private(set) var requests: [ChatModelRequest] = []

    init(_ script: [[ChatModelEvent]]) { self.script = script }

    func stream(_ request: ChatModelRequest) -> AsyncThrowingStream<ChatModelEvent, any Error> {
        let events: [ChatModelEvent] = lock.withLock {
            requests.append(request)
            return script.isEmpty ? [] : script.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    var recorded: [ChatModelRequest] { lock.withLock { requests } }
}

private struct FakeChatData: ChatDataSource {
    var profileValue: ChatCompanyProfile? = ChatCompanyProfile(
        name: "テスト株式会社", overview: "工作機械をつくる。", financialSummary: "26年3月期: 売上高 2,359億円")
    var sections: [String: String] = ["business_risks": "為替の変動が業績に影響します。"]
    var breakdowns: [String: String] = ["segment": "日本: 金額 1,174億円（構成比 49.8%）"]

    func profile(code: String) async -> ChatCompanyProfile? { profileValue }
    func filingSection(code: String, section: String) async -> String? { sections[section] }
    func breakdown(code: String, axis: String) async -> String? { breakdowns[axis] }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ChatStreamEvent] = []
    func append(_ event: ChatStreamEvent) { lock.withLock { items.append(event) } }
    var events: [ChatStreamEvent] { lock.withLock { items } }
}

private func run(
    _ session: ChatSession, question: String = "リスクは？"
) async throws -> [ChatStreamEvent] {
    let log = EventLog()
    try await session.run(
        ChatTurnInput(code: "6103", messages: [.init(role: .user, content: question)])
    ) { log.append($0) }
    return log.events
}

// MARK: - SSE パーサ

@Suite struct OpenRouterStreamParserTests {
    @Test func textAcrossSplitUTF8AndComments() throws {
        var parser = OpenRouterStreamParser()
        let stream = Array(
            """
            : OPENROUTER PROCESSING

            data: {"choices":[{"delta":{"content":"為替"}}]}

            data: {"choices":[{"delta":{"content":"です"},"finish_reason":"stop"}],"usage":{"prompt_tokens":120,"completion_tokens":8}}

            data: [DONE]

            """.utf8)
        // 「為」の途中（マルチバイトの中）で切る。
        let cut = stream.firstIndex(of: 0xE7)! + 1
        var events = try parser.consume(Array(stream[..<cut]))
        events += try parser.consume(Array(stream[cut...]))
        events += try parser.finish()
        #expect(events == [
            .text("為替"), .text("です"),
            .usage(ChatUsage(promptTokens: 120, completionTokens: 8)),
        ])
    }

    @Test func toolCallArgumentsAreAssembled() throws {
        var parser = OpenRouterStreamParser()
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"get_filing_section","arguments":"{\"sec"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"tion\":\"mda\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ]
        let events = try parser.consume(Array((lines.joined(separator: "\n\n") + "\n\n").utf8))
        #expect(events == [
            .toolCalls([ChatToolCall(id: "c1", name: "get_filing_section", arguments: #"{"section":"mda"}"#)])
        ])
    }

    @Test func errorObjectThrows() {
        var parser = OpenRouterStreamParser()
        #expect(throws: ChatModelError.self) {
            _ = try parser.consume(Array("data: {\"error\":{\"message\":\"rate limited\"}}\n".utf8))
        }
    }

    @Test func requestBodyCarriesFallbacksAndToolChoice() throws {
        let model = OpenRouterChatModel(
            apiKey: "k", models: ["a/primary", "b/fallback"], baseURL: "https://example.invalid",
            client: .shared, logger: Logger(label: "test"))
        let data = try model.requestBody(
            ChatModelRequest(
                messages: [ChatModelMessage(role: .user, content: "q")],
                tools: ChatTools.definitions, maxOutputTokens: 100, toolChoiceNone: true))
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["models"] as? [String] == ["a/primary", "b/fallback"])
        #expect(body["model"] == nil)
        #expect(body["stream"] as? Bool == true)
        #expect(body["tool_choice"] as? String == "none")
        let tools = try #require(body["tools"] as? [[String: Any]])
        let function = try #require(tools.first?["function"] as? [String: Any])
        #expect(function["name"] as? String == "get_filing_section")
        #expect((function["parameters"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test func environmentWithoutKeyIsUnconfigured() {
        let logger = Logger(label: "test")
        #expect(OpenRouterChatModel.fromEnvironment([:], logger: logger) == nil)
        let model = OpenRouterChatModel.fromEnvironment(
            ["OPENROUTER_CHAT_API_KEY": " k ", "OPENROUTER_CHAT_FALLBACK_MODELS": "x/y, ,"],
            logger: logger)
        #expect(model?.apiKey == "k")
        #expect(model?.models == [OpenRouterChatModel.defaultModel, "x/y"])
    }
}

// MARK: - 整形

@Suite struct ChatFormatTests {
    @Test func yenUnits() {
        #expect(ChatFormat.yen(235_888_000_000) == "2,359億円")
        #expect(ChatFormat.yen(15_505_000_000) == "155.1億円")
        #expect(ChatFormat.yen(-5_412_000_000) == "-54.1億円")
        #expect(ChatFormat.yen(3_210_000_000_000) == "3.21兆円")
        #expect(ChatFormat.yen(52_000_000) == "5,200万円")
    }

    @Test func financialSummaryOldestFirstWithGrowth() throws {
        let json: [String: Any] = [
            "years": [
                [
                    "fy_end": "2026-03-31", "sales": 235_888_000_000, "sales_label": "売上高",
                    "operating_profit": 15_505_000_000, "net_profit": 1_000_000_000,
                    "operating_margin": 6.573, "employees": 4101,
                ],
                [
                    "fy_end": "2025-03-31", "sales": 206_822_000_000,
                    "operating_profit": 14_651_000_000, "net_profit": -500_000_000,
                ],
            ]
        ]
        let summary = try #require(ChatFormat.financialSummary(json))
        let lines = summary.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("25年3月期: 売上高 2,068億円、営業利益 146.5億円"))
        #expect(lines[1].contains("売上高 2,359億円（前期比 +14.1%）"))
        #expect(lines[1].contains("純利益 10.0億円（黒字化）"))
        #expect(lines[1].contains("営業利益率 6.6%"))
        #expect(lines[1].contains("従業員数 4,101人"))
    }

    @Test func breakdownSkipsReconcilingRows() throws {
        let json: [String: Any] = [
            "unit": "currency_amount",
            "breakdown": [
                "denominator": 235_888_000_000,
                "rows": [
                    ["label": "日本", "amount": 117_355_000_000, "profit": 8_830_000_000, "row_kind": "segment"],
                    ["label": "調整項目", "amount": 0, "profit": 2_175_000_000, "row_kind": "reconciling"],
                    ["label": "連結合計", "amount": 235_888_000_000, "row_kind": "subtotal"],
                ],
            ],
        ]
        let text = try #require(ChatFormat.breakdownSummary(json))
        #expect(
            text == """
                日本: 金額 1,174億円（構成比 49.8%）、利益 88.3億円（利益率 7.5%）
                ［合計］連結合計: 金額 2,359億円
                """)
    }

    @Test func excerptPrefersKeywordParagraphsInOriginalOrder() {
        let text = (1...20).map { "段落\($0)は一般的な説明です。" + String(repeating: "あ", count: 40) }
            .joined(separator: "\n") + "\n為替の変動は大きなリスクです。"
        let excerpt = ChatFormat.excerpt(text, keywords: ["為替"], maxCharacters: 200)
        #expect(excerpt.count <= 200)
        #expect(excerpt.contains("為替の変動は大きなリスクです。"))
        #expect(excerpt.hasPrefix("段落1は"))
        #expect(excerpt.hasSuffix("再取得できます）"))
        #expect(ChatFormat.excerpt("短い本文", keywords: [], maxCharacters: 200) == "短い本文")
    }
}

// MARK: - 進行

@Suite struct ChatSessionTests {
    @Test func toolRoundTripThenAnswer() async throws {
        let model = ScriptedChatModel([
            [.toolCalls([ChatToolCall(id: "c1", name: ChatTools.filingSectionName, arguments: #"{"section":"business_risks","keywords":["為替"]}"#)])],
            [.text("為替が"), .text("リスクです。"), .usage(ChatUsage(promptTokens: 10, completionTokens: 5))],
        ])
        let events = try await run(ChatSession(model: model, data: FakeChatData()))
        #expect(events == [
            .tool(name: ChatTools.filingSectionName, label: "有報の「事業等のリスク」"),
            .delta("為替が"), .delta("リスクです。"),
            .done(ChatUsage(promptTokens: 10, completionTokens: 5)),
        ])

        let requests = model.recorded
        #expect(requests.count == 2)
        let system = try #require(requests[0].messages.first)
        #expect(system.role == .system)
        #expect(system.content.contains("テスト株式会社"))
        #expect(system.content.contains("26年3月期: 売上高 2,359億円"))
        #expect(!requests[0].tools.isEmpty)
        let toolMessage = try #require(requests[1].messages.last)
        #expect(toolMessage.role == .tool)
        #expect(toolMessage.toolCallId == "c1")
        #expect(toolMessage.content.contains("為替の変動が業績に影響します。"))
    }

    @Test func toolCallsStopAtLimitAndFinalTurnHasNoNewTools() async throws {
        let call = ChatToolCall(id: "c", name: ChatTools.breakdownName, arguments: #"{"axis":"segment"}"#)
        let model = ScriptedChatModel([
            [.toolCalls([call, call])],
            [.toolCalls([call, call])],
            [.text("まとめ")],
        ])
        var session = ChatSession(model: model, data: FakeChatData())
        session.limits.maxToolCalls = 3
        let events = try await run(session)
        #expect(events.filter { if case .tool = $0 { true } else { false } }.count == 3)
        #expect(events.contains(.delta("まとめ")))

        let requests = model.recorded
        #expect(requests.count == 3)
        // 4 件目の呼び出しには上限の旨を返し、最後の回答はツール指定なし（tool_choice none）。
        #expect(requests[2].messages.last?.content.contains("上限") == true)
        #expect(requests[2].toolChoiceNone)
    }

    @Test func missingDataIsReportedToModel() async throws {
        let model = ScriptedChatModel([
            [.toolCalls([ChatToolCall(id: "c1", name: ChatTools.filingSectionName, arguments: #"{"section":"mda"}"#)])],
            [.text("わかりません")],
        ])
        _ = try await run(ChatSession(model: model, data: FakeChatData()))
        #expect(model.recorded[1].messages.last?.content.contains("取得できませんでした") == true)
    }

    @Test func emptyAnswerGetsFallbackText() async throws {
        let events = try await run(ChatSession(model: ScriptedChatModel([[]]), data: FakeChatData()))
        #expect(events.count == 2)
        guard case .delta(let text) = events[0] else {
            Issue.record("delta がない")
            return
        }
        #expect(text.contains("回答を作れませんでした"))
    }

    @Test func historyKeepsNewestWithinBudget() {
        let messages: [ChatTurnInput.Message] = [
            .init(role: .user, content: String(repeating: "古", count: 50)),
            .init(role: .assistant, content: String(repeating: "答", count: 50)),
            .init(role: .user, content: "新しい質問"),
        ]
        let kept = ChatSession.history(messages, maxCharacters: 60)
        #expect(kept.map(\.content) == ["新しい質問"])
    }
}

// MARK: - HTTP の入口

private func withChatApp(
    model: (any ChatModelStreaming)?, _ body: (Application) async throws -> Void
) async throws {
    let app = try await Application.make(.testing)
    do {
        setChatModel(app, model)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blt-chat-tests-\(UUID().uuidString)", isDirectory: true)
        try await registerRoutes(app, context: BltServerContext(apiKey: "test-key", cacheDir: dir))
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private func postChat(_ app: Application, _ json: String) async throws -> (HTTPResponseStatus, HTTPHeaders, String) {
    let request = Request(
        application: app, method: .POST, url: URI(string: "/v1/chat"),
        headers: ["Content-Type": "application/json"],
        collectedBody: ByteBuffer(string: json), on: app.eventLoopGroup.next())
    let response = try await app.responder.respond(to: request).get()
    let buffer = try await response.body.collect(on: app.eventLoopGroup.next()).get()
    return (response.status, response.headers, buffer.map { String(buffer: $0) } ?? "")
}

@Suite struct ChatRouteTests {
    @Test func unconfiguredModelIs503() async throws {
        try await withChatApp(model: nil) { app in
            let (status, _, body) = try await postChat(
                app, #"{"code":"6103","messages":[{"role":"user","content":"q"}]}"#)
            #expect(status == .serviceUnavailable)
            #expect(body.contains("\"status\":503"))
        }
    }

    @Test func invalidRequestsAre400() async throws {
        try await withChatApp(model: ScriptedChatModel([])) { app in
            for json in [
                "not json",
                #"{"code":"../x","messages":[{"role":"user","content":"q"}]}"#,
                #"{"code":"6103","messages":[]}"#,
                #"{"code":"6103","messages":[{"role":"system","content":"q"}]}"#,
                #"{"code":"6103","messages":[{"role":"user","content":"q"},{"role":"assistant","content":"a"}]}"#,
                #"{"code":"6103","messages":[{"role":"user","content":"\#(String(repeating: "あ", count: 2001))"}]}"#,
            ] {
                let (status, _, _) = try await postChat(app, json)
                #expect(status == .badRequest, "\(json.prefix(60))")
            }
        }
    }

    @Test func streamsServerSentEvents() async throws {
        let model = ScriptedChatModel([[.text("こんにちは")]])
        try await withChatApp(model: model) { app in
            let (status, headers, body) = try await postChat(
                app, #"{"code":"6103","messages":[{"role":"user","content":"概要は？"}]}"#)
            #expect(status == .ok)
            #expect(headers.first(name: .contentType)?.hasPrefix("text/event-stream") == true)
            let frames = body.components(separatedBy: "\n\n").filter { !$0.isEmpty }
            #expect(frames.first == #"data: {"text":"こんにちは","type":"delta"}"#)
            #expect(frames.last?.contains(#""type":"done""#) == true)
        }
        // DB 未接続でも会社データなしで回答は進む（システムプロンプトは銘柄コードのみ）。
        #expect(model.recorded.first?.messages.first?.content.contains("証券コード 6103") == true)
    }
}
