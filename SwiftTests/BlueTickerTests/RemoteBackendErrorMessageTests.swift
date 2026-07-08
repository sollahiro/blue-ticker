import Testing

@testable import BlueTickerCore

@Suite struct RemoteBackendErrorMessageTests {
    @Test func processFailureMessageSuggestsInstallForMissingBinary() {
        let message = RemoteBackend.cloudflaredProcessFailureMessage(
            exitCode: 127, stderr: "cloudflared: command not found")

        #expect(message.contains("インストール状態と PATH を確認"))
        #expect(message.contains("exit=127"))
        #expect(!message.contains("SSO セッションが無効"))
    }

    @Test func processFailureMessageSuggestsReloginForExpiredSession() {
        let message = RemoteBackend.cloudflaredProcessFailureMessage(
            exitCode: 1,
            stderr: "no valid session found, please run: cloudflared access login")

        #expect(message.contains("SSO セッションが無効"))
        #expect(message.contains("ticker login"))
        #expect(!message.contains("ネットワーク/TLS"))
    }

    @Test func processFailureMessageMentionsNetworkOrTlsForUnknownFailure() {
        let message = RemoteBackend.cloudflaredProcessFailureMessage(
            exitCode: 1,
            stderr: "x509: certificate signed by unknown authority")

        #expect(message.contains("ネットワーク/TLS/環境要因"))
        #expect(message.contains("必要に応じて ticker login を再実行"))
        #expect(!message.contains("SSO セッションが無効"))
    }

    @Test func processFailureMessageForInternalErrorDoesNotMentionTls() {
        let message = RemoteBackend.cloudflaredProcessFailureMessage(
            exitCode: -1, stderr: "一時ファイルの作成に失敗しました")

        #expect(message.contains("実行環境を確認"))
        #expect(message.contains("exit=-1"))
        #expect(!message.contains("ネットワーク/TLS"))
        #expect(!message.contains("SSO セッションが無効"))
    }

    @Test func processFailureMessageTreatsNoSuchFileOnNegativeExitAsBinaryMissing() {
        let message = RemoteBackend.cloudflaredProcessFailureMessage(
            exitCode: -1, stderr: "The operation couldn't be completed. (NSPOSIXErrorDomain error 2 - No such file or directory)")

        #expect(message.contains("インストール状態と PATH を確認"))
        #expect(!message.contains("実行環境を確認"))
        #expect(!message.contains("SSO セッションが無効"))
    }

    @Test func processFailureMessageTreatsExecutableNotFoundWithoutExit127AsBinaryMissing() {
        let message = RemoteBackend.cloudflaredProcessFailureMessage(
            exitCode: 1, stderr: "executable file not found")

        #expect(message.contains("インストール状態と PATH を確認"))
        #expect(!message.contains("SSO セッションが無効"))
    }

    @Test func processFailureMessageSuggestsReloginForInvalidSessionKeyword() {
        let message = RemoteBackend.cloudflaredProcessFailureMessage(
            exitCode: 1, stderr: "invalid session for application")

        #expect(message.contains("SSO セッションが無効"))
        #expect(message.contains("ticker login"))
    }

    @Test func processFailureMessageDoesNotTreatNetworkErrorAsSessionExpired() {
        let message = RemoteBackend.cloudflaredProcessFailureMessage(
            exitCode: 1,
            stderr: "failed to refresh login token: connection refused")

        #expect(message.contains("ネットワーク/TLS/環境要因"))
        #expect(!message.contains("SSO セッションが無効"))
    }

    @Test func emptyTokenMessageWithBlankStderrDoesNotClaimSessionExpired() {
        let message = RemoteBackend.cloudflaredEmptyTokenMessage(stderr: "")

        #expect(message.contains("トークンを取得できませんでした"))
        #expect(message.contains("ticker login"))
        #expect(!message.contains("SSO セッションが無効"))
    }

    @Test func emptyTokenMessageWithKnownSessionStderrSuggestsRelogin() {
        let message = RemoteBackend.cloudflaredEmptyTokenMessage(
            stderr: "Unable to find token for provided application. Please run login command to generate token.")

        #expect(message.contains("SSO セッションが無効"))
        #expect(message.contains("ticker login"))
    }
}
