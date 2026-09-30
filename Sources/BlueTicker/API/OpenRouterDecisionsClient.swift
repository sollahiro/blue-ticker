// OpenRouter Decisions API（Jev）。Chat Completions とは別エンドポイント。
// 返すのは Choice / Noul / Score と確率で、散文は返さない。
// セグメント注記は `OPENROUTER_API_KEY` があるときだけ呼ぶ。未設定ならクライアントを作らない。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let openRouterDecisionsAPIKeyEnv = "OPENROUTER_API_KEY"

struct OpenRouterDecisionsEndpoint: Sendable, Equatable {
    var url: String
    var apiKey: String
    var model: String
    var timeoutSeconds: Double = 60
}

/// `OPENROUTER_API_KEY` だけを読む。空なら nil。Overview 用キーは見ない。
func resolveOpenRouterDecisionsEndpoint(
    _ env: [String: String] = ProcessInfo.processInfo.environment
) -> OpenRouterDecisionsEndpoint? {
    let raw = env[openRouterDecisionsAPIKeyEnv]?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !raw.isEmpty else { return nil }
    return OpenRouterDecisionsEndpoint(
        url: Api.openrouterDecisionsURL,
        apiKey: raw,
        model: Api.openrouterDecisionsModel)
}

protocol DecisionsCompleting: Sendable {
    func decide(requestJSON: Data) async throws -> Data
}

struct OpenRouterDecisionAnswer: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case choice(selected: String, probabilities: [String: Double], confidence: Double?)
        case noul(yesProbability: Double)
        case score(score: Double, probabilities: [String: Double], confidence: Double?)
    }

    var kind: Kind

    var choice: (selected: String, probabilities: [String: Double], confidence: Double?)? {
        guard case .choice(let selected, let probabilities, let confidence) = kind else { return nil }
        return (selected, probabilities, confidence)
    }
}

enum OpenRouterDecisionsCodec {
    static func requestJSON(model: String, state: [String: Any], questions: [String: Any]) -> Data? {
        let body: [String: Any] = [
            "model": model,
            "state": state,
            "questions": questions,
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    static func choiceQuestion(instructions: String, criteria: [String: String]) -> [String: Any] {
        [
            "type": "choice",
            "instructions": instructions,
            "criteria": criteria,
        ]
    }

    /// `answers` を質問キーごとに読む。Choice / Noul / Score 以外は落とす。
    static func answers(from data: Data) -> [String: OpenRouterDecisionAnswer] {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = top["answers"] as? [String: Any]
        else { return [:] }
        var parsed: [String: OpenRouterDecisionAnswer] = [:]
        for (key, value) in raw {
            guard let object = value as? [String: Any], let answer = parseAnswer(object) else { continue }
            parsed[key] = answer
        }
        return parsed
    }

    private static func parseAnswer(_ object: [String: Any]) -> OpenRouterDecisionAnswer? {
        let type = object["type"] as? String
        if type == "noul" || object["noul"] != nil && type != "choice" && type != "score" {
            guard let yes = doubleValue(object["noul"]) else { return nil }
            return OpenRouterDecisionAnswer(kind: .noul(yesProbability: yes))
        }
        if type == "score" || object["score"] != nil && type != "choice" {
            guard let score = doubleValue(object["score"]) else { return nil }
            return OpenRouterDecisionAnswer(
                kind: .score(
                    score: score,
                    probabilities: probabilityMap(object["probabilities"]),
                    confidence: doubleValue(object["confidence"])))
        }
        guard let selected = object["choice"] as? String else { return nil }
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return OpenRouterDecisionAnswer(
            kind: .choice(
                selected: trimmed,
                probabilities: probabilityMap(object["probabilities"]),
                confidence: doubleValue(object["confidence"])))
    }

    private static func probabilityMap(_ value: Any?) -> [String: Double] {
        guard let object = value as? [String: Any] else { return [:] }
        var map: [String: Double] = [:]
        for (key, raw) in object {
            if let number = doubleValue(raw) { map[key] = number }
        }
        return map
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let number as NSNumber: return number.doubleValue
        default: return nil
        }
    }
}

/// `POST https://openrouter.ai/api/alpha/decisions`。Authorization は Bearer。
actor OpenRouterDecisionsClient: DecisionsCompleting {
    private let endpoint: OpenRouterDecisionsEndpoint

    init(endpoint: OpenRouterDecisionsEndpoint) {
        self.endpoint = endpoint
    }

    func decide(requestJSON: Data) async throws -> Data {
        guard let url = URL(string: endpoint.url) else { throw ChatCompletionError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("https://github.com/sollahiro/blue-ticker", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("BLUE TICKER Segment Note", forHTTPHeaderField: "X-OpenRouter-Title")
        request.timeoutInterval = endpoint.timeoutSeconds
        request.httpBody = requestJSON

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatCompletionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            printError("[blue-ticker] OpenRouter decisions HTTP \(http.statusCode)\n")
            throw ChatCompletionError.httpError(http.statusCode, "")
        }
        return data
    }
}
