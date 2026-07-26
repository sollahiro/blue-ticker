import ArgumentParser
import Foundation

/// TickerDev（開発用ローカル解析 CLI）向けの「Chat Completions 互換エンドポイント設定解決」
/// ボイラープレート。`EdinetClientLoader` と同型。型名・実装はプロバイダ非依存にし、
/// 現時点では xAI Grok を読む。将来ローカル LLM 等へ差し替える際は
/// このファイルの環境変数名・既定値のみ変更すればよい（Analysis/API 層は変更不要）。
///
/// Server 側（`BltServerFacade.resolveXaiEndpoint`）と同じ命名規約だが、実装は意図的に別
/// （EDINET キー解決が Server/DevCLI で個別に存在するのと同じ設計）。
enum LLMClientLoader {
    enum Axis: String {
        case business
        case geography
    }

    /// 軸別の LLM エンドポイントを解決する。
    /// - business: `XAI_BUSINESS_API_KEY` / `XAI_BUSINESS_MODEL` / `XAI_BUSINESS_BASE_URL`。
    ///   未設定時は旧 `XAI_API_KEY` / `XAI_MODEL` / `XAI_BASE_URL` にフォールバック。
    /// - geography: `XAI_GEOGRAPHY_API_KEY` / `XAI_GEOGRAPHY_MODEL` / `XAI_GEOGRAPHY_BASE_URL` のみ。
    static func resolveEndpoint(axis: Axis) -> ChatCompletionEndpoint? {
        let env = ProcessInfo.processInfo.environment
        let prefix: String
        let allowLegacyFallback: Bool
        switch axis {
        case .business:
            prefix = "XAI_BUSINESS"
            allowLegacyFallback = true
        case .geography:
            prefix = "XAI_GEOGRAPHY"
            allowLegacyFallback = false
        }
        let apiKey =
            nonEmpty(env["\(prefix)_API_KEY"])
            ?? (allowLegacyFallback ? nonEmpty(env["XAI_API_KEY"]) : nil)
        let model =
            nonEmpty(env["\(prefix)_MODEL"])
            ?? (allowLegacyFallback ? nonEmpty(env["XAI_MODEL"]) : nil)
        guard let apiKey, let model else { return nil }
        let baseURL =
            nonEmpty(env["\(prefix)_BASE_URL"])
            ?? (allowLegacyFallback ? nonEmpty(env["XAI_BASE_URL"]) : nil)
            ?? Api.xaiBaseURL
        return ChatCompletionEndpoint(baseURL: baseURL, apiKey: apiKey, model: model)
    }

    /// business 軸の後方互換エイリアス（旧 `XAI_*` または `XAI_BUSINESS_*`）。
    static func resolveEndpoint() -> ChatCompletionEndpoint? {
        resolveEndpoint(axis: .business)
    }

    /// エンドポイント解決 → クライアント構築までをまとめる。
    /// 未設定なら stderr へ出力し `ExitCode.failure` を投げる。
    static func make(axis: Axis) throws -> ChatCompletionClient {
        guard let endpoint = resolveEndpoint(axis: axis) else {
            switch axis {
            case .business:
                printError(
                    """
                    エラー: business LLM API 設定が未完了です。\
                    XAI_BUSINESS_API_KEY と XAI_BUSINESS_MODEL \
                    （または旧 XAI_API_KEY / XAI_MODEL）を設定してください。

                    """
                )
            case .geography:
                printError(
                    """
                    エラー: geography LLM API 設定が未完了です。\
                    XAI_GEOGRAPHY_API_KEY と XAI_GEOGRAPHY_MODEL を設定してください。

                    """
                )
            }
            throw ExitCode.failure
        }
        return ChatCompletionClient(endpoint: endpoint)
    }

    /// business 軸の後方互換エイリアス。
    static func make() throws -> ChatCompletionClient {
        try make(axis: .business)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
