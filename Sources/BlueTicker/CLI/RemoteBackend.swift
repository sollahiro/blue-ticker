import ArgumentParser
import Foundation

// remote / local バックエンドの切り替え解決。
// 各コマンドは run() 冒頭で clientIfEnabled() を呼び、非 nil なら remote 経路、
// nil ならローカル経路（従来の Services 直呼び）を実行する。

enum RemoteBackend {
    private enum CloudflaredTokenFailureKind {
        case sessionExpired
        case binaryMissing
        /// cloudflared 起動前の内部エラー（一時ファイル作成失敗・Process.run 失敗など）。
        case internalError
        case invocationFailed
    }

    /// remote バックエンドが有効ならクライアントを返す（local なら nil）。
    /// 接続情報の解決順位は env（BLT_SERVER_URL）> config。
    /// remote だが server-url が未解決なら stderr へ出して `ExitCode.failure` を投げる。
    static func clientIfEnabled() async throws -> RemoteAPIClient? {
        let backend = await settingsStore.get(.edinetBackend) ?? "remote"
        guard backend == "remote" else { return nil }

        let env = ProcessInfo.processInfo.environment
        let url: String
        if let envURL = nonEmpty(env["BLT_SERVER_URL"]) {
            url = envURL
        } else {
            url = (await settingsStore.get(.serverURL)) ?? ""
        }
        // Cloudflare Access SSO（ticker login 経由）。有効なら cloudflared から都度 JWT を取得する。
        var cfJwt: String?
        if await settingsStore.getBool(.cfAccessSsoEnabled), !url.isEmpty {
            switch CloudflaredAccess.fetchToken(appURL: url) {
            case .success(let jwt):
                cfJwt = jwt
            case .binaryNotFound:
                printError("エラー: cloudflared が見つかりません。インストールを確認してください。\n")
                throw ExitCode.failure
            case .processFailed(let exitCode, let stderr):
                printError(cloudflaredProcessFailureMessage(exitCode: exitCode, stderr: stderr))
                throw ExitCode.failure
            case .emptyToken(let stderr):
                printError(cloudflaredEmptyTokenMessage(stderr: stderr))
                throw ExitCode.failure
            }
        }

        guard
            let client = RemoteAPIClient(baseURLString: url, cfAccessJwt: cfJwt)
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

    private static func cloudflaredFailureKind(exitCode: Int32, stderr: String) -> CloudflaredTokenFailureKind {
        let lower = stderr.lowercased()
        if
            exitCode == 127
                || lower.contains("command not found")
                || lower.contains("no such file")
                || lower.contains("executable file not found")
        {
            return .binaryMissing
        }
        if exitCode < 0 { return .internalError }

        if
            lower.contains("unable to find token")
                || lower.contains("no valid session found")
                || lower.contains("please run login")
                || lower.contains("invalid session")
        {
            return .sessionExpired
        }
        return .invocationFailed
    }

    static func cloudflaredProcessFailureMessage(exitCode: Int32, stderr: String) -> String {
        let detail = stderr.isEmpty ? "" : " 詳細: \(stderr)"
        switch cloudflaredFailureKind(exitCode: exitCode, stderr: stderr) {
        case .binaryMissing:
            return
                "エラー: cloudflared の実行に失敗しました（exit=\(exitCode)）。"
                + "インストール状態と PATH を確認してください。\(detail)\n"
        case .sessionExpired:
            return
                "エラー: Cloudflare Access の SSO セッションが無効です。"
                + "ticker login を再実行してください（cloudflared exit=\(exitCode)）。\(detail)\n"
        case .internalError:
            return
                "エラー: cloudflared の起動に失敗しました（exit=\(exitCode)）。"
                + "実行環境を確認してください。\(detail)\n"
        case .invocationFailed:
            return
                "エラー: cloudflared で Cloudflare Access トークンを取得できませんでした（exit=\(exitCode)）。"
                + "ネットワーク/TLS/環境要因の可能性があります。必要に応じて ticker login を再実行してください。"
                + "\(detail)\n"
        }
    }

    static func cloudflaredEmptyTokenMessage(stderr: String) -> String {
        if stderr.isEmpty {
            return
                "エラー: cloudflared からトークンを取得できませんでした。"
                + "ticker login を再実行してください。\n"
        }
        switch cloudflaredFailureKind(exitCode: 0, stderr: stderr) {
        case .sessionExpired:
            return
                "エラー: Cloudflare Access の SSO セッションが無効です。ticker login を再実行してください。"
                + " (cloudflared: \(stderr))\n"
        case .binaryMissing:
            return
                "エラー: cloudflared の実行に失敗しました。"
                + "インストール状態と PATH を確認してください。 (cloudflared: \(stderr))\n"
        case .internalError, .invocationFailed:
            return
                "エラー: cloudflared からトークンを取得できませんでした。"
                + "必要に応じて ticker login を再実行してください。 (cloudflared: \(stderr))\n"
        }
    }
}
