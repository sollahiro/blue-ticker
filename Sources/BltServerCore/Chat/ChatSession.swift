// チャット 1 回分の進行（プロンプト組み立て → モデル → ツール実行 → 回答）。
// HTTP やモデルの実体には依存しない（`ChatModelStreaming` と `ChatDataSource` を差し込む）。

import Foundation

// MARK: - データ取得

/// チャットが読む会社データ。返す文字列は整形済み（`ChatFormat`）。
protocol ChatDataSource: Sendable {
    func profile(code: String) async -> ChatCompanyProfile?
    func filingSection(code: String, section: String) async -> String?
    func breakdown(code: String, axis: String) async -> String?
}

struct ChatCompanyProfile: Sendable, Equatable {
    var name: String?
    var overview: String?
    var financialSummary: String?
}

// MARK: - 上限

struct ChatLimits: Sendable {
    /// 1 回答あたりのツール呼び出し上限。
    var maxToolCalls = 3
    /// モデルへ送る入力の文字数上限（日本語はおよそ 1 文字 1 トークン。約 1 万トークン）。
    var maxInputCharacters = 10_000
    /// 会話履歴に使う文字数（新しい順に残す）。
    var maxHistoryCharacters = 3_000
    /// ツール結果 1 件の文字数上限。
    var maxToolResultCharacters = 4_000
    /// 残りがこれを下回ったらツールを使わずに回答させる。
    var minToolBudgetCharacters = 800
    var maxOutputTokens = 1_200
}

// MARK: - クライアントへ流すイベント

enum ChatStreamEvent: Sendable, Equatable {
    case delta(String)
    case tool(name: String, label: String)
    case done(ChatUsage)
    case error(String)
    /// 事前チェック（`ChatGuarding`）で断った。回答モデルは呼んでいない。
    case refused(String)

    var jsonObject: [String: Any] {
        switch self {
        case .delta(let text):
            return ["type": "delta", "text": text]
        case .tool(let name, let label):
            return ["type": "tool", "name": name, "label": label]
        case .done(let usage):
            return [
                "type": "done",
                "usage": [
                    "prompt_tokens": usage.promptTokens,
                    "completion_tokens": usage.completionTokens,
                ],
            ]
        case .error(let message):
            return ["type": "error", "message": message]
        case .refused(let message):
            return ["type": "refused", "message": message]
        }
    }
}

// MARK: - ツール

enum ChatTools {
    static let filingSectionName = "get_filing_section"
    static let breakdownName = "get_breakdown"

    /// 有報の節キーと表示名。filing-content が返す節のうち、文章で答える問いに使うもの。
    static let sections: [(key: String, label: String)] = [
        ("management_policy", "経営方針・経営環境・対処すべき課題"),
        ("business_risks", "事業等のリスク"),
        ("mda", "経営者による財政状態・経営成績の分析"),
        ("research_and_development", "研究開発活動"),
        ("capex_overview", "設備投資等の概要"),
        ("facility_plans", "設備の新設・除却等の計画"),
        ("major_facilities", "主要な設備の状況"),
    ]

    static let axes: [(key: String, label: String)] = [
        ("segment", "報告セグメント別"),
        ("product_service", "製品・サービス別"),
        ("geography", "地域別"),
    ]

    static func sectionLabel(_ key: String) -> String? {
        sections.first { $0.key == key }?.label
    }

    static func axisLabel(_ key: String) -> String? {
        axes.first { $0.key == key }?.label
    }

    static var definitions: [ChatToolDefinition] {
        let sectionKeys = sections.map { "\"\($0.key)\"" }.joined(separator: ",")
        let sectionGuide = sections.map { "\($0.key)=\($0.label)" }.joined(separator: "、")
        let axisKeys = axes.map { "\"\($0.key)\"" }.joined(separator: ",")
        let axisGuide = axes.map { "\($0.key)=\($0.label)" }.joined(separator: "、")
        return [
            ChatToolDefinition(
                name: filingSectionName,
                description: """
                    最新の有価証券報告書から1つの節の本文を読む。長い節はキーワードを含む段落を優先して抜粋する。\
                    節: \(sectionGuide)
                    """,
                parametersJSON: """
                    {"type":"object","properties":{\
                    "section":{"type":"string","enum":[\(sectionKeys)]},\
                    "keywords":{"type":"array","items":{"type":"string"},"description":"抜粋で優先する語（例: 為替、人材）。最大5語"}},\
                    "required":["section"]}
                    """),
            ChatToolDefinition(
                name: breakdownName,
                description: """
                    最新の有価証券報告書の売上内訳（金額・構成比・利益）を取得する。軸: \(axisGuide)
                    """,
                parametersJSON: """
                    {"type":"object","properties":{"axis":{"type":"string","enum":[\(axisKeys)]}},\
                    "required":["axis"]}
                    """),
        ]
    }
}

// MARK: - 入力

struct ChatTurnInput: Sendable {
    struct Message: Sendable, Equatable {
        var role: ChatRole
        var content: String
    }

    var code: String
    /// 古い順。最後は利用者の質問。
    var messages: [Message]
}

// MARK: - 進行

struct ChatSession: Sendable {
    let model: any ChatModelStreaming
    let data: any ChatDataSource
    var limits = ChatLimits()

    func run(
        _ input: ChatTurnInput, emit: @Sendable (ChatStreamEvent) async throws -> Void
    ) async throws {
        let profile = await data.profile(code: input.code)
        var messages = [ChatModelMessage(role: .system, content: Self.systemPrompt(code: input.code, profile: profile))]
        messages += Self.history(input.messages, maxCharacters: limits.maxHistoryCharacters)

        var toolCallsUsed = 0
        var answered = false
        var usage = ChatUsage(promptTokens: 0, completionTokens: 0)
        // ツール上限ぶんの往復 + 最後の回答 1 回。
        for _ in 0...limits.maxToolCalls {
            let remaining = limits.maxInputCharacters - Self.characterCount(messages)
            let allowTools =
                toolCallsUsed < limits.maxToolCalls && remaining >= limits.minToolBudgetCharacters
            let hasToolHistory = messages.contains { $0.role == .tool }
            let request = ChatModelRequest(
                messages: messages,
                tools: allowTools || hasToolHistory ? ChatTools.definitions : [],
                maxOutputTokens: limits.maxOutputTokens,
                toolChoiceNone: !allowTools && hasToolHistory)

            var text = ""
            var calls: [ChatToolCall] = []
            for try await event in model.stream(request) {
                switch event {
                case .text(let delta):
                    text += delta
                    answered = true
                    try await emit(.delta(delta))
                case .toolCalls(let received):
                    calls += received
                case .usage(let received):
                    usage.promptTokens += received.promptTokens
                    usage.completionTokens += received.completionTokens
                }
            }
            guard allowTools, !calls.isEmpty else { break }

            messages.append(ChatModelMessage(role: .assistant, content: text, toolCalls: calls))
            for call in calls {
                let result: String
                if toolCallsUsed >= limits.maxToolCalls {
                    result = "ツールの呼び出し上限に達しました。ここまでの情報で回答してください。"
                } else {
                    toolCallsUsed += 1
                    let budget = min(
                        limits.maxToolResultCharacters,
                        max(0, limits.maxInputCharacters - Self.characterCount(messages)))
                    let execution = await execute(call, code: input.code, budget: budget)
                    try await emit(.tool(name: call.name, label: execution.label))
                    result = execution.text
                }
                messages.append(ChatModelMessage(role: .tool, content: result, toolCallId: call.id))
            }
        }
        if !answered {
            try await emit(.delta("回答を作れませんでした。質問を変えてもう一度お試しください。"))
        }
        try await emit(.done(usage))
    }

    struct ToolExecution: Equatable {
        var label: String
        var text: String
    }

    func execute(_ call: ChatToolCall, code: String, budget: Int) async -> ToolExecution {
        let arguments =
            (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
            ?? [:]
        switch call.name {
        case ChatTools.filingSectionName:
            let section = arguments["section"] as? String ?? ""
            guard let label = ChatTools.sectionLabel(section) else {
                return ToolExecution(label: "有報を確認", text: "その節は読めません。使える節: " + ChatTools.sections.map(\.key).joined(separator: ", "))
            }
            let keywords = (arguments["keywords"] as? [String] ?? []).prefix(5)
            guard let text = await data.filingSection(code: code, section: section),
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return ToolExecution(label: "有報の「\(label)」", text: "この会社の有報からは「\(label)」の本文を取得できませんでした。")
            }
            return ToolExecution(
                label: "有報の「\(label)」",
                text: "有報「\(label)」より:\n"
                    + ChatFormat.excerpt(text, keywords: Array(keywords), maxCharacters: budget))

        case ChatTools.breakdownName:
            let axis = arguments["axis"] as? String ?? ""
            guard let label = ChatTools.axisLabel(axis) else {
                return ToolExecution(label: "売上内訳", text: "その軸は使えません。使える軸: " + ChatTools.axes.map(\.key).joined(separator: ", "))
            }
            guard let text = await data.breakdown(code: code, axis: axis) else {
                return ToolExecution(label: "\(label)の売上内訳", text: "この会社の有報からは\(label)の売上内訳を取得できませんでした。")
            }
            return ToolExecution(
                label: "\(label)の売上内訳",
                text: "\(label)の売上内訳（最新の有報）:\n" + String(text.prefix(budget)))

        default:
            return ToolExecution(label: call.name, text: "不明なツールです: \(call.name)")
        }
    }

    // MARK: - プロンプト

    static func systemPrompt(code: String, profile: ChatCompanyProfile?) -> String {
        let name = profile?.name ?? "証券コード \(code) の会社"
        var lines = [
            "あなたは有報LABのアシスタントです。\(name)（証券コード \(code)）について、有価証券報告書と財務データに基づいて日本語で答えます。",
            "",
            "守ること:",
            "・数値は下の財務データとツールの結果に書かれた表記をそのまま使う。単位換算や割り算などの計算を自分でしない。",
            "・データにないことは推測せず、わからないと答える。株価の予想や売買の推奨はしない。",
            "・経営方針、リスク、業績の要因、研究開発、設備投資など文章で書かれた内容は get_filing_section で有報を読んでから答える。",
            "・セグメント別・製品別・地域別の売上は get_breakdown を使う。",
            "・ツールを呼ぶ前に前置きを書かない。",
            "・結論から書き、300字程度に収める。見出しや表は使わず、必要なら「・」の箇条書きにする。",
            "・有報の記述に基づくときは「有報の『事業等のリスク』によると」のように節の名前を添える。",
        ]
        if let overview = profile?.overview, !overview.isEmpty {
            lines += ["", "会社概要: \(overview)"]
        }
        if let summary = profile?.financialSummary, !summary.isEmpty {
            lines += ["", "財務データ（有報の連結数値。古い順）:", summary]
        }
        return lines.joined(separator: "\n")
    }

    /// 新しい発言から `maxCharacters` に収まるぶんだけ残す。最後の質問は必ず残す。
    static func history(_ messages: [ChatTurnInput.Message], maxCharacters: Int) -> [ChatModelMessage] {
        var kept: [ChatModelMessage] = []
        var used = 0
        for message in messages.reversed() {
            let length = message.content.count
            if !kept.isEmpty, used + length > maxCharacters { break }
            kept.append(ChatModelMessage(role: message.role, content: message.content))
            used += length
        }
        // 先頭が assistant だと文脈が欠けるため落とす。
        while kept.last?.role == .assistant { kept.removeLast() }
        return kept.reversed()
    }

    static func characterCount(_ messages: [ChatModelMessage]) -> Int {
        messages.reduce(0) { total, message in
            total + message.content.count + message.toolCalls.reduce(0) { $0 + $1.arguments.count }
        }
    }
}
