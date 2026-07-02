import ArgumentParser
import Foundation

/// CLI コマンド共通の「API キー解決 → EdinetCacheStore → EdinetAPIClient 構築」ボイラープレート。
/// filings / filing / cache(prepare/catchup/refresh) / MetricsLoader の重複を 1 箇所へ集約する。
enum EdinetClientLoader {
    /// EDINET API キーを解決する。
    /// dev（DEBUG ビルド）のみ `BLT_EDINET_API_KEY` env を優先し、keychain 非搭載環境・
    /// keychain プロンプト回避に使えるようにする。配布（release ビルド）では env 経路を
    /// コンパイル時に除外し、settingsStore（keychain）のみを参照する。
    static func resolveApiKey() async -> String? {
        #if DEBUG
            if let envKey = ProcessInfo.processInfo.environment["BLT_EDINET_API_KEY"],
               !envKey.isEmpty {
                return envKey
            }
        #endif
        let stored = await settingsStore.get(.edinetApiKey)
        return (stored?.isEmpty == false) ? stored : nil
    }

    /// API キー検証 → クライアント構築までをまとめる。
    /// キー未設定なら stderr へ出力し `ExitCode.failure` を投げる。
    /// `cacheDir` も返す（`CacheManager` 等を追加構築する呼び出し元向け）。
    static func make() async throws -> (client: EdinetAPIClient, cacheDir: URL) {
        guard let key = await resolveApiKey() else {
            printError(
                "エラー: EDINET API キーが設定されていません。ticker config set --edinet-api-key <KEY> で設定してください。\n")
            throw ExitCode.failure
        }
        let cacheDir = URL(fileURLWithPath: await settingsStore.get(.cacheDir) ?? "")
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        let client = EdinetAPIClient(apiKey: key, cacheStore: store)
        return (client, cacheDir)
    }
}
