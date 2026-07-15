import ArgumentParser
import Foundation

struct LoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Cloudflare Access への SSO ログインを行います（remote バックエンド専用）"
    )

    func run() async throws {
        // RemoteBackend.client() と同じ解決順位（env > config）。
        // ずれると login した URL と後続リクエストの token 取得 URL が食い違うため揃える。
        let envURL = ProcessInfo.processInfo.environment["BLT_SERVER_URL"]
        let configURL = await settingsStore.get(.serverURL)
        guard let url = (envURL?.isEmpty == false ? envURL : nil) ?? configURL, !url.isEmpty else {
            printError(
                "エラー: server-url が未設定です。"
                    + "ticker config set --server-url <url> を先に設定してください。\n")
            throw ExitCode.failure
        }
        guard CloudflaredAccess.resolveBinaryPath() != nil else {
            printError("エラー: cloudflared が見つかりません。`brew install cloudflared` 等でインストールしてください。\n")
            throw ExitCode.failure
        }

        print("ブラウザで Cloudflare Access のログインを行います...")
        guard CloudflaredAccess.login(appURL: url) else {
            printError("エラー: ログインに失敗しました。\n")
            throw ExitCode.failure
        }

        await settingsStore.set(.cfAccessSsoEnabled, value: true)
        await settingsStore.save()
        print("ログインに成功しました。以降 remote バックエンドへの接続は SSO セッションを使用します。")
    }
}
