// チャットの事前チェック。売買の判断・株価の予想を求める質問と、個人情報を含む質問は
// 回答モデルへ渡す前に断る。個人情報は端末側でも送信前に止めるので、ここは取りこぼしの受け皿。
// 判定は OpenRouter Decisions（Jev）の choice。確率が閾値に届かなければ通す（回答モデルの指示でも断る）。

import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1

enum ChatGuardVerdict: String, Sendable, Equatable {
    case allowed
    case investmentAdvice = "investment_advice"
    case personalInformation = "personal_information"

    /// 断るときに利用者へ返す文。
    var refusal: String? {
        switch self {
        case .allowed:
            return nil
        case .investmentAdvice:
            return "売買の判断や株価の見通しにはお答えできません。業績や事業の内容についての質問をどうぞ。"
        case .personalInformation:
            return "個人を特定できる情報が含まれているようなので、お答えできません。その部分を消してから質問してください。"
        }
    }
}

protocol ChatGuarding: Sendable {
    func check(_ question: String) async -> ChatGuardVerdict
}

struct JevChatGuard: ChatGuarding {
    static let defaultURL = "https://openrouter.ai/api/alpha/decisions"
    static let defaultModel = "typesafe/jev-1.13"
    /// これ以上の確率で断る。Jev の確率は同じ入力でも揺れるため、強く当てはまるときだけにする。
    static let defaultThreshold = 0.6

    let apiKey: String
    let model: String
    let url: String
    let threshold: Double
    let client: HTTPClient
    let logger: Logger

    /// `OPENROUTER_CHAT_API_KEY` を使う。`OPENROUTER_CHAT_GUARD_MODEL=off` で無効。
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        client: HTTPClient = .shared, logger: Logger
    ) -> JevChatGuard? {
        func value(_ key: String) -> String? {
            let trimmed = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        guard let apiKey = value("OPENROUTER_CHAT_API_KEY") else { return nil }
        let model = value("OPENROUTER_CHAT_GUARD_MODEL") ?? defaultModel
        guard model.lowercased() != "off" else { return nil }
        return JevChatGuard(
            apiKey: apiKey, model: model, url: defaultURL, threshold: defaultThreshold,
            client: client, logger: logger)
    }

    static let instructions = """
        日本の上場企業についてのチャットに届いた利用者の質問を分類する。
        investment_advice: 特定の銘柄を買うべきか・売るべきか、買い時・売り時、株価や目標株価の予想、どの銘柄が儲かるかなど、売買の判断や株価の見通しを求めている。
        personal_information: 質問の中に、氏名・住所・電話番号・メールアドレス・口座番号・カード番号・マイナンバーなど、個人を特定できる情報が書かれている。
        allowed: 上のどちらでもない（業績、財務、事業内容、リスク、戦略などの質問）。
        """

    func requestBody(_ question: String) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "state": ["question": question],
            "questions": [
                "category": [
                    "type": "choice",
                    "instructions": Self.instructions,
                    "criteria": [
                        ChatGuardVerdict.allowed.rawValue: "問題のない質問",
                        ChatGuardVerdict.investmentAdvice.rawValue: "売買の判断・株価の予想を求める質問",
                        ChatGuardVerdict.personalInformation.rawValue: "個人を特定できる情報を含む質問",
                    ],
                ] as [String: Any]
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// `answers.category` の choice と確率から判定する。読めなければ通す。
    static func verdict(from data: Data, threshold: Double) -> ChatGuardVerdict {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let answers = top["answers"] as? [String: Any],
            let category = answers["category"] as? [String: Any],
            let choice = (category["choice"] as? String)?.trimmingCharacters(in: .whitespaces),
            let verdict = ChatGuardVerdict(rawValue: choice), verdict != .allowed
        else { return .allowed }
        let probabilities = category["probabilities"] as? [String: Any] ?? [:]
        let probability = ChatFormat.number(probabilities[choice])
            ?? ChatFormat.number(category["confidence"]) ?? 0
        return probability >= threshold ? verdict : .allowed
    }

    func check(_ question: String) async -> ChatGuardVerdict {
        do {
            var http = HTTPClientRequest(url: url)
            http.method = .POST
            http.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
            http.headers.add(name: "Content-Type", value: "application/json")
            http.headers.add(name: "HTTP-Referer", value: "https://github.com/sollahiro/blue-ticker")
            http.headers.add(name: "X-OpenRouter-Title", value: "YuhoLAB Chat Guard")
            http.body = .bytes(ByteBuffer(data: try requestBody(question)))
            let response = try await client.execute(http, timeout: .seconds(15))
            let buffer = try await response.body.collect(upTo: 64 * 1024)
            guard response.status == .ok else {
                logger.warning("chat guard failed", metadata: ["status": "\(response.status.code)"])
                return .allowed
            }
            return Self.verdict(from: Data(buffer.readableBytesView), threshold: threshold)
        } catch {
            // 判定できないときは通す。回答モデルの指示でも売買の判断は断る。
            logger.warning("chat guard failed", metadata: ["error": "\(error)"])
            return .allowed
        }
    }
}
