// POST /v1/chat: 会社についての質問に、有報データを読みながら LLM が答える（SSE で返す）。
// 呼び出し回数の上限・利用者認証はゲートウェイ（HAPIS）が持つ。ここは 1 回答あたりの
// ツール回数と入力量だけを抑える（ChatLimits）。
//
// リクエスト: {"code":"7203","messages":[{"role":"user","content":"..."}]}（古い順・最後は user）
// 応答: text/event-stream。各イベントは `data: {"type":"delta"|"tool"|"done"|"error",...}`。

import BltStoreCore
import BlueTickerCore
import Fluent
import Foundation
import Logging
import Vapor

// MARK: - サービス（モデル）の差し込み

private struct ChatModelKey: StorageKey {
    typealias Value = ChatModelBox
}

final class ChatModelBox: Sendable {
    let model: (any ChatModelStreaming)?
    let guarding: (any ChatGuarding)?
    init(model: (any ChatModelStreaming)?, guarding: (any ChatGuarding)? = nil) {
        self.model = model
        self.guarding = guarding
    }
}

/// テストから偽モデル・偽の事前チェックを差し込む。model に nil を渡すと「未設定（503）」になる。
func setChatModel(
    _ app: Application, _ model: (any ChatModelStreaming)?, guarding: (any ChatGuarding)? = nil
) {
    app.storage[ChatModelKey.self] = ChatModelBox(model: model, guarding: guarding)
}

private func chatServices(for app: Application) -> ChatModelBox {
    if let box = app.storage[ChatModelKey.self] { return box }
    let box =
        app.environment.name == "testing"
        ? ChatModelBox(model: nil)
        : ChatModelBox(
            model: OpenRouterChatModel.fromEnvironment(logger: app.logger),
            guarding: JevChatGuard.fromEnvironment(logger: app.logger))
    app.storage[ChatModelKey.self] = box
    return box
}

// MARK: - リクエスト

enum ChatRequestLimits {
    static let maxMessages = 12
    static let maxMessageCharacters = 2_000
    static let maxBodyBytes: ByteCount = "64kb"
}

func parseChatRequest(_ data: Data?) -> Result<ChatTurnInput, ChatRequestError> {
    guard let data, !data.isEmpty,
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return .failure(ChatRequestError("JSON の本文が必要です")) }

    guard let code = (object["code"] as? String)?.trimmingCharacters(in: .whitespaces),
        (4...5).contains(code.count), code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
    else { return .failure(ChatRequestError("code は 4〜5 文字の銘柄コードです")) }

    guard let rawMessages = object["messages"] as? [[String: Any]], !rawMessages.isEmpty else {
        return .failure(ChatRequestError("messages が必要です"))
    }
    guard rawMessages.count <= ChatRequestLimits.maxMessages else {
        return .failure(ChatRequestError("messages は \(ChatRequestLimits.maxMessages) 件までです"))
    }
    var messages: [ChatTurnInput.Message] = []
    for raw in rawMessages {
        guard let roleText = raw["role"] as? String,
            let role = ChatRole(rawValue: roleText), role == .user || role == .assistant
        else { return .failure(ChatRequestError("role は user か assistant です")) }
        guard let content = raw["content"] as? String,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .failure(ChatRequestError("content が空です")) }
        guard content.count <= ChatRequestLimits.maxMessageCharacters else {
            return .failure(
                ChatRequestError("content は \(ChatRequestLimits.maxMessageCharacters) 文字までです"))
        }
        messages.append(ChatTurnInput.Message(role: role, content: content))
    }
    guard messages.last?.role == .user else {
        return .failure(ChatRequestError("最後のメッセージは user の質問にしてください"))
    }
    return .success(ChatTurnInput(code: code, messages: messages))
}

struct ChatRequestError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - 有報データ（格納済みのみ）

struct StoredChatDataSource: ChatDataSource {
    let db: Database?
    let logger: Logger

    func profile(code: String) async -> ChatCompanyProfile? {
        var profile = ChatCompanyProfile()
        if case .ok(let json) = await serveStoredFinancials(
            code: code, years: 3, db: db, logger: logger)
        {
            profile.name = json["name"] as? String
            profile.financialSummary = ChatFormat.financialSummary(json)
        }
        if case .ok(let json) = await serveStoredOverview(code: code, db: db, logger: logger) {
            profile.overview = json["overview"] as? String
        }
        return profile == ChatCompanyProfile() ? nil : profile
    }

    func filingSection(code: String, section: String) async -> String? {
        guard case .ok(let json) = await serveStoredFilingSections(
            code: code, docId: nil, sections: [section], db: db, logger: logger)
        else { return nil }
        return (json["sections"] as? [String: Any])?[section] as? String
    }

    func breakdown(code: String, axis: String) async -> String? {
        guard case .ok(let json) = await serveStoredBreakdown(
            code: code, docId: nil, axis: axis, db: db, logger: logger)
        else { return nil }
        return ChatFormat.breakdownSummary(json)
    }
}

// MARK: - SSE

func chatSSEFrame(_ event: ChatStreamEvent) -> String {
    let data =
        (try? JSONSerialization.data(withJSONObject: event.jsonObject, options: [.sortedKeys]))
        ?? Data("{\"type\":\"error\"}".utf8)
    return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
}

// MARK: - ルート

func registerChatRoute(_ v1: RoutesBuilder, dbAvailable: Bool) {
    v1.on(.POST, "chat", body: .collect(maxSize: ChatRequestLimits.maxBodyBytes)) {
        req async -> Response in
        let services = chatServices(for: req.application)
        guard let model = services.model else {
            return errorResponse(.serviceUnavailable, message: "チャットは現在利用できません")
        }
        let body = req.body.data.map { Data($0.readableBytesView) }
        let input: ChatTurnInput
        switch parseChatRequest(body) {
        case .success(let parsed): input = parsed
        case .failure(let error): return errorResponse(.badRequest, message: error.message)
        }
        recordFeedTrend(req.application, surface: "rest", tool: "chat", code: input.code)

        let timing = ChatTiming(code: input.code)
        // 売買の判断・個人情報を含む質問は、回答モデルへ渡す前に断る。
        let refusal: String?
        if let guarding = services.guarding, let question = input.messages.last?.content {
            refusal = await guarding.check(question).refusal
        } else {
            refusal = nil
        }
        timing.markGuard()

        let session = ChatSession(
            model: model,
            data: StoredChatDataSource(db: dbAvailable ? req.db : nil, logger: req.logger))
        let logger = req.logger

        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream; charset=utf-8")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        response.headers.replaceOrAdd(name: "X-Accel-Buffering", value: "no")
        // 圧縮するとプロキシ側でまとめて届くことがあるため、SSE は圧縮しない。
        response.headers.responseCompression = .disable
        response.body = .init(asyncStream: { writer in
            if let refusal {
                timing.observe(.refused(refusal))
                timing.log(logger, outcome: "refused")
                try await writer.write(.buffer(ByteBuffer(string: chatSSEFrame(.refused(refusal)))))
                try await writer.write(
                    .buffer(ByteBuffer(string: chatSSEFrame(.done(ChatUsage(promptTokens: 0, completionTokens: 0))))))
                try await writer.write(.end)
                return
            }
            do {
                try await session.run(input) { event in
                    timing.observe(event)
                    try await writer.write(.buffer(ByteBuffer(string: chatSSEFrame(event))))
                }
                timing.log(logger, outcome: "answered")
            } catch {
                timing.log(logger, outcome: "failed")
                logger.warning("chat failed", metadata: ["error": "\(error)"])
                try? await writer.write(
                    .buffer(ByteBuffer(string: chatSSEFrame(.error("回答を取得できませんでした。時間をおいてお試しください。")))))
            }
            try await writer.write(.end)
        })
        return response
    }
}

// MARK: - 計測

/// 1 回答の所要時間を 1 行ログ（`chat_timing`）に出す。質問・回答の本文は出さない。
/// HTTP のアクセスログはヘッダを返した時点で止まるため、ストリームの最後までをここで測る。
final class ChatTiming: @unchecked Sendable {
    private let lock = NSLock()
    private let start = DispatchTime.now()
    private let code: String
    private var guardMs: UInt64?
    private var firstTextMs: UInt64?
    private var toolCalls = 0
    private var usage = ChatUsage(promptTokens: 0, completionTokens: 0)

    init(code: String) { self.code = code }

    private func elapsedMs() -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    func markGuard() {
        lock.withLock { guardMs = elapsedMs() }
    }

    func observe(_ event: ChatStreamEvent) {
        lock.withLock {
            switch event {
            case .delta, .refused:
                if firstTextMs == nil { firstTextMs = elapsedMs() }
            case .tool:
                toolCalls += 1
            case .done(let received):
                usage = received
            case .error:
                break
            }
        }
    }

    func log(_ logger: Logger, outcome: String) {
        let metadata: Logger.Metadata = lock.withLock {
            [
                "event": "chat_timing",
                "outcome": .string(outcome),
                "code": .string(code),
                "guard_ms": .stringConvertible(guardMs ?? 0),
                "first_text_ms": .stringConvertible(firstTextMs ?? 0),
                "total_ms": .stringConvertible(elapsedMs()),
                "tool_calls": .stringConvertible(toolCalls),
                "prompt_tokens": .stringConvertible(usage.promptTokens),
                "completion_tokens": .stringConvertible(usage.completionTokens),
            ]
        }
        logger.notice("chat_timing", metadata: metadata)
    }
}
