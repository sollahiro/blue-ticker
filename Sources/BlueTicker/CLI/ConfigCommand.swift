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

        if json {
            printJSONObject([
                "edinetApiKey": apiKey,
                "cacheDir": cacheDir,
                "cacheEnabled": cacheEnabled,
                "edinetBackend": backend,
            ])
        } else {
            print("設定一覧:")
            print("  EDINET API Key : \(apiKey)")
            print("  キャッシュDir  : \(cacheDir)")
            print("  キャッシュ有効  : \(cacheEnabled)")
            print("  バックエンド    : \(backend)")
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

    @Flag(name: .long, help: "キャッシュを無効化")
    var disableCache = false

    @Flag(name: .long, help: "キャッシュを有効化")
    var enableCache = false

    func run() async throws {
        if let key = edinetApiKey {
            try await settingsStore.set(.edinetApiKey, value: key)
            print("EDINET API キーを保存しました。")
        }
        if let b = backend {
            try await settingsStore.set(.edinetBackend, value: b)
            print("バックエンドを \(b) に設定しました。")
        }
        if disableCache {
            await settingsStore.set(.cacheEnabled, value: false)
            print("キャッシュを無効化しました。")
        }
        if enableCache {
            await settingsStore.set(.cacheEnabled, value: true)
            print("キャッシュを有効化しました。")
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
