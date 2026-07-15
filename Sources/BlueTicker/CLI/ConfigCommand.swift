import ArgumentParser
import Foundation

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "BLUE TICKER の設定を管理します",
        subcommands: [ConfigShow.self, ConfigSet.self],
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
        let cacheDir = await settingsStore.get(.cacheDir) ?? ""
        let serverURL = await settingsStore.get(.serverURL) ?? ""
        let ssoEnabled = await settingsStore.getBool(.cfAccessSsoEnabled)

        if json {
            printJSONObject([
                "cacheDir": cacheDir,
                "serverURL": serverURL,
                "cfAccessSsoEnabled": ssoEnabled,
            ])
        } else {
            print("設定一覧:")
            print("  キャッシュDir    : \(cacheDir)")
            print("  サーバーURL       : \(serverURL.isEmpty ? "(未設定)" : serverURL)")
            print("  SSO ログイン      : \(ssoEnabled ? "有効（ticker login 済み）" : "無効")")
        }
    }
}

struct ConfigSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "設定値を変更します"
    )

    @Option(name: .long, help: "remote バックエンドの blt-server URL (例: https://blt-server.fly.dev)")
    var serverUrl: String?

    @Flag(name: .long, help: "Cloudflare Access SSO ログイン（ticker login）を無効化")
    var disableSso = false

    func run() async throws {
        if let url = serverUrl {
            await settingsStore.set(.serverURL, value: url)
            print("サーバーURLを \(url) に設定しました。")
        }
        if disableSso {
            await settingsStore.set(.cfAccessSsoEnabled, value: false)
            print("SSO ログインを無効化しました。")
        }
        await settingsStore.save()
    }
}
