import ArgumentParser
import Foundation

/// TickerDev（開発用ローカル解析 CLI）共通の「API キー解決 → EdinetCacheStore → EdinetAPIClient 構築」
/// ボイラープレート。dev*(waterfall/summary/filings/filing/search) / cache(prepare/catchup/refresh) /
/// MetricsLoader の重複を 1 箇所へ集約する。
enum EdinetClientLoader {
    /// EDINET API キーを解決する。TickerDev は配布しないため `BLT_EDINET_API_KEY` env のみを見る。
    static func resolveApiKey() -> String? {
        let envKey = ProcessInfo.processInfo.environment["BLT_EDINET_API_KEY"]
        return (envKey?.isEmpty == false) ? envKey : nil
    }

    /// API キー検証 → クライアント構築までをまとめる。
    /// キー未設定なら stderr へ出力し `ExitCode.failure` を投げる。
    /// `cacheDir` も返す（`CacheManager` 等を追加構築する呼び出し元向け）。
    static func make() async throws -> (client: EdinetAPIClient, cacheDir: URL) {
        guard let key = resolveApiKey() else {
            printError(
                "エラー: EDINET API キーが設定されていません。BLT_EDINET_API_KEY 環境変数を設定してください。\n")
            throw ExitCode.failure
        }
        let cacheDir = URL(fileURLWithPath: await settingsStore.get(.cacheDir) ?? "")
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        let client = EdinetAPIClient(apiKey: key, cacheStore: store)
        return (client, cacheDir)
    }
}
