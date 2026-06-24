import ArgumentParser
import Foundation

// remote / local バックエンドの切り替え解決。
// 各コマンドは run() 冒頭で clientIfEnabled() を呼び、非 nil なら remote 経路、
// nil ならローカル経路（従来の Services 直呼び）を実行する。

enum RemoteBackend {
    /// remote バックエンドが有効ならクライアントを返す（local なら nil）。
    /// 接続情報の解決順位は env（BLT_SERVER_URL / BLT_AUTH_TOKEN）> config。
    /// remote だが server-url が未解決なら stderr へ出して `ExitCode.failure` を投げる。
    static func clientIfEnabled() async throws -> RemoteAPIClient? {
        let backend = await settingsStore.get(.edinetBackend) ?? "local"
        guard backend == "remote" else { return nil }

        let env = ProcessInfo.processInfo.environment
        let url: String
        if let envURL = nonEmpty(env["BLT_SERVER_URL"]) {
            url = envURL
        } else {
            url = (await settingsStore.get(.serverURL)) ?? ""
        }
        // env が指定されていれば keychain を読まない（authToken は keychain 保存のため）。
        let token: String?
        if let envToken = nonEmpty(env["BLT_AUTH_TOKEN"]) {
            token = envToken
        } else {
            token = await settingsStore.get(.authToken)
        }

        guard let client = RemoteAPIClient(baseURLString: url, authToken: token) else {
            printError(
                "エラー: remote バックエンドですが server-url が未設定です。"
                    + "ticker config set --server-url <url> または BLT_SERVER_URL を設定してください。\n")
            throw ExitCode.failure
        }
        return client
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
