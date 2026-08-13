import ArgumentParser
import Foundation

/// TickerDev（開発用ローカル解析 CLI）向けの「Chat Completions 互換エンドポイント設定解決」
/// ボイラープレート。`EdinetClientLoader` と同型。型名・実装はプロバイダ非依存。
/// 稼働プロバイダは軸共通の `LLM_PROVIDER`（`openai` / `xai`）。
/// キーと MODEL はプロバイダ×軸（`OPENAI_*` / `XAI_*`）。
///
/// Server 側（`BltServerFacade.resolveXaiEndpoint`）と同じ命名規約だが、実装は意図的に別
/// （EDINET キー解決が Server/DevCLI で個別に存在するのと同じ設計）。
enum LLMClientLoader {
    enum Axis: String {
        case business
        case geography
    }

    /// 軸別の LLM エンドポイントを解決する。
    /// - 稼働プロバイダ: `LLM_PROVIDER`（`openai` / `xai`。未設定は xai。不正値は未解決）。
    /// - openai: `OPENAI_BUSINESS_*` / `OPENAI_GEOGRAPHY_*`。
    /// - xai: `XAI_BUSINESS_*` / `XAI_GEOGRAPHY_*`。business のみ旧 `XAI_*` へフォールバック。
    /// `BASE_URL` 省略時はプロバイダの既定 URL。
    static func resolveEndpoint(axis: Axis) -> ChatCompletionEndpoint? {
        let env = ProcessInfo.processInfo.environment
        guard let provider = LLMProvider.fromEnv(env) else { return nil }
        return provider.endpoint(axis: axis.rawValue, env: env)
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
                    LLM_PROVIDER（openai または xai）と、\
                    openai なら OPENAI_BUSINESS_API_KEY / OPENAI_BUSINESS_MODEL、\
                    xai なら XAI_BUSINESS_API_KEY / XAI_BUSINESS_MODEL \
                    （または旧 XAI_API_KEY / XAI_MODEL）を設定してください。

                    """
                )
            case .geography:
                printError(
                    """
                    エラー: geography LLM API 設定が未完了です。\
                    LLM_PROVIDER（openai または xai）と、\
                    openai なら OPENAI_GEOGRAPHY_API_KEY / OPENAI_GEOGRAPHY_MODEL、\
                    xai なら XAI_GEOGRAPHY_API_KEY / XAI_GEOGRAPHY_MODEL を設定してください。

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
}
