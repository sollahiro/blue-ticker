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
        // env が指定されていれば keychain を読まない（各認証情報は keychain 保存のため）。
        let token: String?
        if let envToken = nonEmpty(env["BLT_AUTH_TOKEN"]) {
            token = envToken
        } else {
            token = await settingsStore.get(.authToken)
        }
        // Cloudflare Access Service Token（鍵ペア）。env（Cloudflare 標準名）> keychain。
        let cfClientId: String?
        if let envId = nonEmpty(env["CF_ACCESS_CLIENT_ID"]) {
            cfClientId = envId
        } else {
            cfClientId = await settingsStore.get(.cfAccessClientId)
        }
        let cfClientSecret: String?
        if let envSecret = nonEmpty(env["CF_ACCESS_CLIENT_SECRET"]) {
            cfClientSecret = envSecret
        } else {
            cfClientSecret = await settingsStore.get(.cfAccessClientSecret)
        }
        // Cloudflare Access SSO（ticker login 経由）。有効なら cloudflared から都度 JWT を取得する。
        var cfJwt: String?
        if await settingsStore.getBool(.cfAccessSsoEnabled), !url.isEmpty {
            guard let jwt = CloudflaredAccess.fetchToken(appURL: url) else {
                printError("エラー: Cloudflare Access の SSO セッションが無効です。ticker login を再実行してください。\n")
                throw ExitCode.failure
            }
            cfJwt = jwt
        }

        guard
            let client = RemoteAPIClient(
                baseURLString: url, authToken: token,
                cfAccessClientId: cfClientId, cfAccessClientSecret: cfClientSecret,
                cfAccessJwt: cfJwt)
        else {
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
