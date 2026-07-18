import ArgumentParser
import Foundation

/// TickerDev（開発用ローカル解析 CLI）向けの「Chat Completions 互換エンドポイント設定解決」
/// ボイラープレート。`EdinetClientLoader` と同型。型名・実装はプロバイダ非依存にし、
/// 現時点では xAI Grok（`XAI_API_KEY`）を読む。将来ローカル LLM 等へ差し替える際は
/// このファイルの環境変数名・既定値のみ変更すればよい（Analysis/API 層は変更不要）。
enum LLMClientLoader {
    /// `XAI_API_KEY` / `XAI_MODEL`（必須）/ `XAI_BASE_URL`（任意）から `ChatCompletionEndpoint` を組み立てる。
    /// モデル名は決め打ちしない（存在しない/廃止されたモデル名を書かないため、未設定なら nil）。
    static func resolveEndpoint() -> ChatCompletionEndpoint? {
        let env = ProcessInfo.processInfo.environment
        guard let apiKey = env["XAI_API_KEY"], !apiKey.isEmpty,
              let model = env["XAI_MODEL"], !model.isEmpty
        else { return nil }
        let baseURL = env["XAI_BASE_URL"]?.isEmpty == false ? env["XAI_BASE_URL"]! : Api.xaiBaseURL
        return ChatCompletionEndpoint(baseURL: baseURL, apiKey: apiKey, model: model)
    }

    /// エンドポイント解決 → クライアント構築までをまとめる。
    /// 未設定なら stderr へ出力し `ExitCode.failure` を投げる。
    static func make() throws -> ChatCompletionClient {
        guard let endpoint = resolveEndpoint() else {
            printError(
                "エラー: LLM API 設定が未完了です。XAI_API_KEY と XAI_MODEL 環境変数を設定してください。\n")
            throw ExitCode.failure
        }
        return ChatCompletionClient(endpoint: endpoint)
    }
}
