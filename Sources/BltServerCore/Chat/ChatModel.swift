// チャット（POST /v1/chat）が使う LLM の抽象と、OpenRouter のストリーミング実装。
// モデル呼び出しは `ChatModelStreaming` に閉じ込め、テストでは偽の実装を差し込む。
// Linux の URLSession はストリーミング受信ができないため、AsyncHTTPClient で SSE を読む。

import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1

// MARK: - メッセージとイベント

struct ChatToolCall: Sendable, Equatable {
    let id: String
    let name: String
    /// モデルが返した引数（JSON 文字列のまま）。
    let arguments: String
}

enum ChatRole: String, Sendable {
    case system, user, assistant, tool
}

struct ChatModelMessage: Sendable, Equatable {
    var role: ChatRole
    var content: String
    var toolCalls: [ChatToolCall] = []
    var toolCallId: String? = nil

    /// OpenAI 互換の chat/completions に載せる形。
    var jsonObject: [String: Any] {
        var object: [String: Any] = ["role": role.rawValue, "content": content]
        if !toolCalls.isEmpty {
            object["tool_calls"] = toolCalls.map { call in
                [
                    "id": call.id, "type": "function",
                    "function": ["name": call.name, "arguments": call.arguments],
                ] as [String: Any]
            }
        }
        if let toolCallId { object["tool_call_id"] = toolCallId }
        return object
    }
}

struct ChatToolDefinition: Sendable {
    let name: String
    let description: String
    /// JSON Schema（文字列で持ち、送信時に展開する）。
    let parametersJSON: String

    var jsonObject: [String: Any] {
        let parameters =
            (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8))) ?? [String: Any]()
        return [
            "type": "function",
            "function": ["name": name, "description": description, "parameters": parameters]
                as [String: Any],
        ]
    }
}

struct ChatModelRequest: Sendable {
    var messages: [ChatModelMessage]
    /// 空ならツールなしで回答させる。
    var tools: [ChatToolDefinition]
    var maxOutputTokens: Int
    /// ツール履歴はあるが、もう呼ばせない（最後の回答）。履歴の解釈にツール定義が要るため tools は送る。
    var toolChoiceNone = false
}

struct ChatUsage: Sendable, Equatable {
    var promptTokens: Int
    var completionTokens: Int
}

enum ChatModelEvent: Sendable, Equatable {
    case text(String)
    case toolCalls([ChatToolCall])
    case usage(ChatUsage)
}

struct ChatModelError: Error, CustomStringConvertible {
    let description: String
}

protocol ChatModelStreaming: Sendable {
    func stream(_ request: ChatModelRequest) -> AsyncThrowingStream<ChatModelEvent, any Error>
}

// MARK: - OpenRouter の SSE パーサ

/// OpenRouter（OpenAI 互換）の SSE を行単位で読み、`ChatModelEvent` に変える。
/// チャンクは UTF-8 の途中で切れることがあるため、バイトのまま改行までためる。
struct OpenRouterStreamParser {
    private var pending: [UInt8] = []
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]

    mutating func consume(_ bytes: [UInt8]) throws -> [ChatModelEvent] {
        pending.append(contentsOf: bytes)
        var events: [ChatModelEvent] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            events += try parseLine(line)
        }
        return events
    }

    /// ストリーム終端。finish_reason が来ないまま切れた場合もツール呼び出しを取りこぼさない。
    mutating func finish() throws -> [ChatModelEvent] {
        var events: [ChatModelEvent] = []
        if !pending.isEmpty {
            let line = String(decoding: pending, as: UTF8.self)
            pending.removeAll()
            events += try parseLine(line)
        }
        events += flushCalls()
        return events
    }

    private mutating func parseLine(_ raw: String) throws -> [ChatModelEvent] {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空行はイベント区切り、":" 始まりはコメント（OpenRouter の処理中通知）。
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]",
            let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8)))
                as? [String: Any]
        else { return [] }

        if let error = object["error"] as? [String: Any] {
            throw ChatModelError(description: "OpenRouter error: \(error["message"] ?? error)")
        }

        var events: [ChatModelEvent] = []
        if let choice = (object["choices"] as? [[String: Any]])?.first {
            let delta = choice["delta"] as? [String: Any] ?? [:]
            if let text = delta["content"] as? String, !text.isEmpty {
                events.append(.text(text))
            }
            for item in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = item["index"] as? Int ?? 0
                var call = calls[index] ?? (id: "", name: "", arguments: "")
                if let id = item["id"] as? String, !id.isEmpty { call.id = id }
                let function = item["function"] as? [String: Any] ?? [:]
                if let name = function["name"] as? String, !name.isEmpty { call.name = name }
                if let arguments = function["arguments"] as? String { call.arguments += arguments }
                calls[index] = call
            }
            if choice["finish_reason"] is String {
                events += flushCalls()
            }
        }
        if let usage = object["usage"] as? [String: Any] {
            events.append(
                .usage(
                    ChatUsage(
                        promptTokens: usage["prompt_tokens"] as? Int ?? 0,
                        completionTokens: usage["completion_tokens"] as? Int ?? 0)))
        }
        return events
    }

    private mutating func flushCalls() -> [ChatModelEvent] {
        guard !calls.isEmpty else { return [] }
        let assembled = calls.sorted { $0.key < $1.key }.map { _, call in
            ChatToolCall(
                id: call.id.isEmpty ? "call_\(call.name)" : call.id, name: call.name,
                arguments: call.arguments.isEmpty ? "{}" : call.arguments)
        }
        calls.removeAll()
        return [.toolCalls(assembled)]
    }
}

// MARK: - OpenRouter クライアント

struct OpenRouterChatModel: ChatModelStreaming {
    static let defaultBaseURL = "https://openrouter.ai/api/v1"
    static let defaultModel = "anthropic/claude-haiku-5.5"

    let apiKey: String
    /// 先頭が主モデル。2件目以降は OpenRouter の `models` によるフォールバック。
    let models: [String]
    let baseURL: String
    let client: HTTPClient
    let logger: Logger
    var timeout: TimeAmount = .seconds(90)

    /// `OPENROUTER_CHAT_API_KEY` が無ければ nil（ルートは 503 を返す）。
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        client: HTTPClient = .shared, logger: Logger
    ) -> OpenRouterChatModel? {
        func value(_ key: String) -> String? {
            let trimmed = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        guard let apiKey = value("OPENROUTER_CHAT_API_KEY") else { return nil }
        let primary = value("OPENROUTER_CHAT_MODEL") ?? defaultModel
        let fallbacks = (value("OPENROUTER_CHAT_FALLBACK_MODELS") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != primary }
        return OpenRouterChatModel(
            apiKey: apiKey, models: [primary] + fallbacks,
            baseURL: value("OPENROUTER_CHAT_BASE_URL") ?? defaultBaseURL,
            client: client, logger: logger)
    }

    func requestBody(_ request: ChatModelRequest) throws -> Data {
        var body: [String: Any] = [
            "messages": request.messages.map(\.jsonObject),
            "stream": true,
            "max_tokens": request.maxOutputTokens,
            "temperature": 0.2,
            "usage": ["include": true],
            // 質問を学習・保持する提供元へは回さない（プライバシーポリシーの記載と揃える）。
            "provider": ["data_collection": "deny"],
        ]
        if models.count > 1 {
            body["models"] = models
        } else {
            body["model"] = models.first ?? Self.defaultModel
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map(\.jsonObject)
            if request.toolChoiceNone { body["tool_choice"] = "none" }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    func stream(_ request: ChatModelRequest) -> AsyncThrowingStream<ChatModelEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var http = HTTPClientRequest(url: baseURL + "/chat/completions")
                    http.method = .POST
                    http.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
                    http.headers.add(name: "Content-Type", value: "application/json")
                    http.headers.add(name: "Accept", value: "text/event-stream")
                    http.headers.add(
                        name: "HTTP-Referer", value: "https://github.com/sollahiro/blue-ticker")
                    http.headers.add(name: "X-Title", value: "YuhoLAB Chat")
                    http.body = .bytes(ByteBuffer(data: try requestBody(request)))

                    let response = try await client.execute(http, timeout: timeout)
                    guard response.status == .ok else {
                        let detail = try? await String(buffer: response.body.collect(upTo: 16 * 1024))
                        // 本文はログにだけ残す（利用者へは出さない）。
                        logger.warning(
                            "OpenRouter chat failed",
                            metadata: [
                                "status": "\(response.status.code)", "body": "\(detail ?? "")",
                            ])
                        throw ChatModelError(description: "OpenRouter status \(response.status.code)")
                    }
                    var parser = OpenRouterStreamParser()
                    for try await chunk in response.body {
                        for event in try parser.consume(Array(chunk.readableBytesView)) {
                            continuation.yield(event)
                        }
                    }
                    for event in try parser.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
