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
        #expect((body["provider"] as? [String: Any])?["data_collection"] as? String == "deny")
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

    @Test func breakdownReadsNamedCellsAndUnits() throws {
        let capex: [String: Any] = [
            "unit": "currency_amount",
            "breakdown": [
                "flow_metric": "capital_expenditures",
                "flow": ["denominator": 6_059_779_000_000],
                "rows": [
                    ["label": "自動車", "flow": 2_453_641_000_000, "segment_assets": 33_182_372_000_000, "row_kind": "segment"],
                    ["label": "消去又は全社", "flow": 29_452_000_000, "row_kind": "reconciling"],
                    ["label": "連結合計又は会社合計", "flow": 6_059_779_000_000, "row_kind": "EntityTotal"],
                ],
            ],
        ]
        let capexText = try #require(ChatFormat.breakdownSummary(capex))
        #expect(
            capexText == """
                自動車: 設備投資額 2.45兆円（構成比 40.5%）、セグメント資産 33.18兆円
                ［合計］連結合計又は会社合計: 設備投資額 6.06兆円
                """)

        let debt: [String: Any] = [
            "unit": "currency_amount",
            "breakdown": [
                "denominator": 43_205_469_000_000,
                "rows": [
                    ["label": "有利子負債", "closing": 17_581_104_000_000, "opening": 15_829_516_000_000,
                     "maturity_class": "current", "in_total": true, "paired_row_index": NSNull(), "row_kind": "segment"],
                    ["label": "短期借入債務", "closing": 5_699_083_000_000, "maturity_class": "current",
                     "in_total": false, "paired_row_index": 0, "row_kind": "segment"],
                ],
            ],
        ]
        let debtText = try #require(ChatFormat.breakdownSummary(debt))
        #expect(debtText.hasPrefix("有利子負債（流動）: 期首 15.83兆円、期末 17.58兆円（構成比 40.7%）"))
        #expect(debtText.contains("短期借入債務（流動）〔明細〕: 期末 5.70兆円"))

        let employees: [String: Any] = [
            "unit": "persons",
            "breakdown": ["denominator": 94_900, "rows": [["label": "音楽", "amount": 11_400, "row_kind": "segment"]]],
        ]
        #expect(ChatFormat.breakdownSummary(employees) == "音楽: 人数 11,400人（構成比 12.0%）")
    }

    @Test func excerptSplitsLongParagraphIntoSentences() {
        let filler = (1...40).map { "業績についての一般的な説明\($0)です。" }.joined()
        let text = filler + "研究開発では電動化と自動運転に注力しています。" + filler
        let excerpt = ChatFormat.excerpt(text, keywords: ["研究開発"], maxCharacters: 300)
        #expect(excerpt.count <= 300)
        #expect(excerpt.contains("研究開発では電動化と自動運転に注力しています。"))
        #expect(excerpt.hasPrefix("業績についての一般的な説明1です。"))
    }

    @Test func toolAxesCoverPublicBreakdownAxes() {
        let keys = Set(ChatTools.axes.map(\.key))
        #expect(keys.contains("research_and_development"))
        #expect(keys.contains("capex"))
        #expect(keys.contains("interest_bearing_debt"))
        #expect(!keys.contains("goodwill_amortization"))
        #expect(keys.count == 11)
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

    @Test func emptyFinalAnswerIsRetriedWithoutTools() async throws {
        let call = ChatToolCall(id: "c1", name: ChatTools.breakdownName, arguments: #"{"axis":"segment"}"#)
        let model = ScriptedChatModel([
            [.toolCalls([call])],
            [.toolCalls([ChatToolCall(id: "c2", name: ChatTools.breakdownName, arguments: #"{"axis":"geography"}"#)])],
            [.text("セグメントは日本が中心です。")],
        ])
        var session = ChatSession(model: model, data: FakeChatData())
        session.limits.maxToolCalls = 1
        let events = try await run(session)
        #expect(events.contains(.delta("セグメントは日本が中心です。")))
        #expect(!events.contains { if case .delta(let text) = $0 { text.contains("回答を作れませんでした") } else { false } })
        let retry = try #require(model.recorded.last)
        #expect(retry.messages.last?.content == ChatSession.answerNowPrompt)
        #expect(retry.toolChoiceNone)
    }

    @Test func repeatedToolResultIsReplacedWithNotice() async throws {
        let call = { (id: String) in
            ChatToolCall(id: id, name: ChatTools.filingSectionName, arguments: #"{"section":"business_risks"}"#)
        }
        let model = ScriptedChatModel([
            [.toolCalls([call("c1")])],
            [.toolCalls([call("c2")])],
            [.text("回答")],
        ])
        _ = try await run(ChatSession(model: model, data: FakeChatData()))
        let requests = model.recorded
        #expect(requests[1].messages.last?.content.contains("為替の変動が業績に影響します。") == true)
        #expect(requests[2].messages.last?.content.contains("前回と同じ内容でした") == true)
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

private struct FixedGuard: ChatGuarding {
    let verdict: ChatGuardVerdict
    func check(_ question: String) async -> ChatGuardVerdict { verdict }
}

private func withChatApp(
    model: (any ChatModelStreaming)?, guarding: (any ChatGuarding)? = nil,
    _ body: (Application) async throws -> Void
) async throws {
    let app = try await Application.make(.testing)
    do {
        setChatModel(app, model, guarding: guarding)
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

    @Test func guardRefusesBeforeCallingTheModel() async throws {
        let model = ScriptedChatModel([[.text("買いです")]])
        try await withChatApp(model: model, guarding: FixedGuard(verdict: .investmentAdvice)) { app in
            let (status, _, body) = try await postChat(
                app, #"{"code":"6103","messages":[{"role":"user","content":"今買うべき？"}]}"#)
            #expect(status == .ok)
            let frames = body.components(separatedBy: "\n\n").filter { !$0.isEmpty }
            #expect(frames.first?.contains(#""type":"refused""#) == true)
            #expect(frames.first?.contains("売買の判断") == true)
            #expect(frames.last?.contains(#""type":"done""#) == true)
        }
        #expect(model.recorded.isEmpty)
    }
}

@Suite struct JevChatGuardTests {
    @Test func verdictNeedsProbabilityOverThreshold() {
        func answer(_ choice: String, _ probability: Double) -> Data {
            Data(#"{"answers":{"category":{"type":"choice","choice":"\#(choice)","probabilities":{"\#(choice)":\#(probability)}}}}"#.utf8)
        }
        #expect(JevChatGuard.verdict(from: answer("investment_advice", 0.9), threshold: 0.6) == .investmentAdvice)
        #expect(JevChatGuard.verdict(from: answer("personal_information", 0.7), threshold: 0.6) == .personalInformation)
        #expect(JevChatGuard.verdict(from: answer("investment_advice", 0.4), threshold: 0.6) == .allowed)
        #expect(JevChatGuard.verdict(from: answer("allowed", 0.99), threshold: 0.6) == .allowed)
        #expect(JevChatGuard.verdict(from: Data("broken".utf8), threshold: 0.6) == .allowed)
    }

    @Test func requestBodyIsAChoiceQuestion() throws {
        let guarding = JevChatGuard(
            apiKey: "k", model: JevChatGuard.defaultModel, url: JevChatGuard.defaultURL,
            threshold: 0.6, client: .shared, logger: Logger(label: "test"))
        let body = try #require(
            try JSONSerialization.jsonObject(with: guarding.requestBody("買い時は？")) as? [String: Any])
        #expect(body["model"] as? String == "typesafe/jev-1.13")
        #expect((body["state"] as? [String: Any])?["question"] as? String == "買い時は？")
        let category = try #require((body["questions"] as? [String: Any])?["category"] as? [String: Any])
        #expect(category["type"] as? String == "choice")
        #expect((category["criteria"] as? [String: Any])?.keys.sorted()
            == ["allowed", "investment_advice", "personal_information"])
    }

    @Test func environmentCanTurnTheGuardOff() {
        let logger = Logger(label: "test")
        #expect(JevChatGuard.fromEnvironment([:], logger: logger) == nil)
        // 既定では使わない（費用が回答モデルの約 25 倍のため）。モデル名を入れたときだけ有効。
        #expect(JevChatGuard.fromEnvironment(["OPENROUTER_CHAT_API_KEY": "k"], logger: logger) == nil)
        #expect(JevChatGuard.fromEnvironment(
            ["OPENROUTER_CHAT_API_KEY": "k", "OPENROUTER_CHAT_GUARD_MODEL": JevChatGuard.defaultModel],
            logger: logger)?.model == "typesafe/jev-1.13")
        #expect(JevChatGuard.fromEnvironment(
            ["OPENROUTER_CHAT_API_KEY": "k", "OPENROUTER_CHAT_GUARD_MODEL": "off"], logger: logger) == nil)
    }
}
