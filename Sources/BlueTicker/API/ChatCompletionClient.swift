// OpenAI Chat Completions 互換の汎用 LLM クライアント。
// Stage 6 の html_table 正規化（Analysis/GeographyBreakdownLLMNormalizer.swift）専用。
// プロバイダ非依存（xAI Grok / ローカル OpenAI 互換サーバーいずれも ChatCompletionEndpoint の
// 差し替えだけで動く想定。docs/breakdown-normalization-concept.md 参照）。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Chat Completions 互換エンドポイントの接続情報。
struct ChatCompletionEndpoint: Sendable {
    var baseURL: String
    var apiKey: String
    var model: String
    /// `response_format: json_schema` を相手が守るか。守らない場合は `json_object` +
    /// プロンプト内スキーマ記述にフォールバックする（ローカル LLM 等の非対応実装を見据える）。
    var supportsJsonSchema: Bool = true
    var timeoutSeconds: Double = 60
}

/// Analysis/ 層はこのプロトコルだけを見る。具体の HTTP 実装は API/ に閉じ込め、
/// テスト時のモック差し替えも容易にする。
/// jsonSchema・戻り値は `Data`（JSON エンコード済み）でやり取りする。`[String: Any]` は
/// Sendable ではなく、actor が満たすプロトコル要件の引数・戻り値に使うと
/// （Swift ツールチェーンのバージョンにより）`sending` を付けても型検査に通らないことがある
/// （実例: Xcode 同梱の新しい Swift では通るが、CI の `swift:6.1` では
/// 「non-sendable type ... cannot be returned/sent」でビルド失敗した）。
protocol ChatCompleting: Sendable {
    func complete(system: String, user: String, jsonSchema: Data, schemaName: String) async throws -> Data
}

enum ChatCompletionError: Error {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case emptyContent
    case decodingFailed(String)
}

/// OpenAI Chat Completions 互換の actor クライアント（`EdinetAPIClient` と同じ actor + URLSession
/// + async/await パターン）。
actor ChatCompletionClient: ChatCompleting {
    private let endpoint: ChatCompletionEndpoint

    init(endpoint: ChatCompletionEndpoint) {
        self.endpoint = endpoint
    }

    func complete(system: String, user: String, jsonSchema: Data, schemaName: String) async throws -> Data {
        guard let url = URL(string: endpoint.baseURL + "/chat/completions") else {
            throw ChatCompletionError.invalidURL
        }
        guard let jsonSchemaObject = try? JSONSerialization.jsonObject(with: jsonSchema) else {
            throw ChatCompletionError.decodingFailed("invalid jsonSchema")
        }

        var body: [String: Any] = [
            "model": endpoint.model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if endpoint.supportsJsonSchema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": schemaName,
                    "schema": jsonSchemaObject,
                    "strict": true,
                ],
            ]
        } else {
            body["response_format"] = ["type": "json_object"]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = endpoint.timeoutSeconds
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatCompletionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ChatCompletionError.httpError(http.statusCode, text)
        }

        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = top["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty
        else { throw ChatCompletionError.emptyContent }

        guard let parsed = Self.parseJSONObject(from: content),
              let reencoded = try? JSONSerialization.data(withJSONObject: parsed)
        else {
            throw ChatCompletionError.decodingFailed(content)
        }
        return reencoded
    }

    /// `response_format` が無視され、コードフェンス付きテキストで返ってきた場合の防御的パース。
    private static func parseJSONObject(from content: String) -> [String: Any]? {
        if let data = content.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end else {
            return nil
        }
        let stripped = String(content[start...end])
        guard let data = stripped.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
