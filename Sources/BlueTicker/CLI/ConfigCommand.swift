import ArgumentParser
import Foundation

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "BLUE TICKER の設定を管理します",
        subcommands: [ConfigShow.self, ConfigSet.self, ConfigInit.self],
        defaultSubcommand: ConfigShow.self
    )
}

struct ConfigShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "現在の設定を表示します"
    )

    @Flag(name: .long, help: "JSON 形式で出力")
    var json = false

    func run() async throws {
        let apiKey = await settingsStore.maskedApiKey()
        let cacheDir = await settingsStore.get(.cacheDir) ?? ""
        let cacheEnabled = await settingsStore.getBool(.cacheEnabled)
        let backend = await settingsStore.get(.edinetBackend) ?? "local"
        let serverURL = await settingsStore.get(.serverURL) ?? ""
        let authToken = await settingsStore.maskedAuthToken()
        let cfClientId = await settingsStore.maskedCfAccessClientId()
        let cfClientSecret = await settingsStore.maskedCfAccessClientSecret()
        let ssoEnabled = await settingsStore.getBool(.cfAccessSsoEnabled)

        if json {
            printJSONObject([
                "edinetApiKey": apiKey,
                "cacheDir": cacheDir,
                "cacheEnabled": cacheEnabled,
                "edinetBackend": backend,
                "serverURL": serverURL,
                "authToken": authToken,
                "cfAccessClientId": cfClientId,
                "cfAccessClientSecret": cfClientSecret,
                "cfAccessSsoEnabled": ssoEnabled,
            ])
        } else {
            print("設定一覧:")
            print("  EDINET API Key   : \(apiKey)")
            print("  キャッシュDir    : \(cacheDir)")
            print("  キャッシュ有効    : \(cacheEnabled)")
            print("  バックエンド      : \(backend)")
            print("  サーバーURL       : \(serverURL.isEmpty ? "(未設定)" : serverURL)")
            print("  認証トークン      : \(authToken)")
            print("  CF Client ID     : \(cfClientId)")
            print("  CF Client Secret : \(cfClientSecret)")
            print("  SSO ログイン      : \(ssoEnabled ? "有効（ticker login 済み）" : "無効")")
        }
    }
}

struct ConfigSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "設定値を変更します"
    )

    @Option(name: .long, help: "EDINET API キー")
    var edinetApiKey: String?

    @Option(name: .long, help: "バックエンド (local / remote)")
    var backend: String?

    @Option(name: .long, help: "remote バックエンドの blt-server URL (例: https://blt-server.fly.dev)")
    var serverUrl: String?

    @Option(name: .long, help: "remote バックエンドの Bearer 認証トークン")
    var authToken: String?

    @Option(name: .long, help: "Cloudflare Access Service Token の Client ID")
    var cfAccessClientId: String?

    @Option(name: .long, help: "Cloudflare Access Service Token の Client Secret")
    var cfAccessClientSecret: String?

    @Flag(name: .long, help: "キャッシュを無効化")
    var disableCache = false

    @Flag(name: .long, help: "キャッシュを有効化")
    var enableCache = false

    @Flag(name: .long, help: "Cloudflare Access SSO ログイン（ticker login）を無効化")
    var disableSso = false

    func run() async throws {
        if let key = edinetApiKey {
            try await settingsStore.set(.edinetApiKey, value: key)
            print("EDINET API キーを保存しました。")
        }
        if let b = backend {
            try await settingsStore.set(.edinetBackend, value: b)
            print("バックエンドを \(b) に設定しました。")
        }
        if let url = serverUrl {
            try await settingsStore.set(.serverURL, value: url)
            print("サーバーURLを \(url) に設定しました。")
        }
        if let token = authToken {
            try await settingsStore.set(.authToken, value: token)
            print("認証トークンを保存しました。")
        }
        if let id = cfAccessClientId {
            try await settingsStore.set(.cfAccessClientId, value: id)
            print("CF Access Client ID を保存しました。")
        }
        if let secret = cfAccessClientSecret {
            try await settingsStore.set(.cfAccessClientSecret, value: secret)
            print("CF Access Client Secret を保存しました。")
        }
        if disableCache {
            await settingsStore.set(.cacheEnabled, value: false)
            print("キャッシュを無効化しました。")
        }
        if enableCache {
            await settingsStore.set(.cacheEnabled, value: true)
            print("キャッシュを有効化しました。")
        }
        if disableSso {
            await settingsStore.set(.cfAccessSsoEnabled, value: false)
            print("SSO ログインを無効化しました。")
        }
        await settingsStore.save()
    }
}

struct ConfigInit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "初期設定を対話式で行います"
    )

    func run() async throws {
        print("BLUE TICKER 初期設定")
        print("-------------------")
        print("EDINET API キーを入力してください（https://disclosure2.edinet-fsa.go.jp）:")
        guard let key = readLine()?.trimmingCharacters(in: .whitespaces), !key.isEmpty else {
            printError("APIキーが入力されませんでした。\n")
            return
        }
        try await settingsStore.set(.edinetApiKey, value: key)
        await settingsStore.save()
        print("設定を保存しました。")
    }
}
