import ArgumentParser
import Foundation

struct CacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "EDINET キャッシュを管理します",
        subcommands: [
            CacheStatus.self,
            CachePrepare.self,
            CacheCatchup.self,
            CacheRefresh.self,
            CacheClean.self,
        ],
        defaultSubcommand: CacheStatus.self
    )
}

struct CacheStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "キャッシュの状態を表示します"
    )

    @Flag(name: .long, help: "JSON 形式で出力")
    var json = false

    func run() async throws {
        let cacheDir = URL(fileURLWithPath: await settingsStore.get(.cacheDir) ?? "")
        let edinetDir = edinetCacheDir(cacheDir)
        let derivedDir = derivedCacheDir(cacheDir)
        let fm = FileManager.default

        func dirSize(_ url: URL) -> Int64 {
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            else { return 0 }
            return enumerator.compactMap { $0 as? URL }
                .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
                .reduce(Int64(0)) { $0 + Int64($1) }
        }

        let edinetBytes = dirSize(edinetDir)
        let derivedBytes = dirSize(derivedDir)

        if json {
            printJSONObject([
                "cacheDir": cacheDir.path,
                "edinetCacheBytes": edinetBytes,
                "derivedCacheBytes": derivedBytes,
            ])
        } else {
            print("キャッシュ状態:")
            print("  EDINET キャッシュ : \(formatBytes(edinetBytes))")
            print("  derived キャッシュ: \(formatBytes(derivedBytes))")
            print("  場所              : \(cacheDir.path)")
        }
    }
}

struct CachePrepare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare",
        abstract: "EDINET 書類インデックスを構築します"
    )

    @Option(name: .shortAndLong, help: "取得する年数")
    var years: Int = Api.prepareDefaultYears

    func run() async throws {
        let apiKey = await settingsStore.get(.edinetApiKey)
        guard let key = apiKey, !key.isEmpty else {
            fputs("EDINET API キーが設定されていません。`ticker config set --edinet-api-key <KEY>` で設定してください。\n", stderr)
            throw ExitCode.failure
        }
        let cacheDir = URL(fileURLWithPath: await settingsStore.get(.cacheDir) ?? "")
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        let client = EdinetAPIClient(apiKey: key, cacheStore: store)

        let currentYear = Calendar.current.component(.year, from: Date())
        for year in (currentYear - years + 1)...currentYear {
            print("  \(year)年 のインデックスを構築中...")
            let docs = await client.ensureDocumentIndexForYear(year)
            print("    → \(docs.count) 件")
        }
        print("完了しました。")
    }
}

struct CacheCatchup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catchup",
        abstract: "既存インデックスを最新日付まで追いつかせます"
    )

    @Option(name: .shortAndLong, help: "対象年数")
    var years: Int = Api.prepareDefaultYears

    func run() async throws {
        let apiKey = await settingsStore.get(.edinetApiKey)
        guard let key = apiKey, !key.isEmpty else {
            fputs("EDINET API キーが設定されていません。\n", stderr)
            throw ExitCode.failure
        }
        let cacheDir = URL(fileURLWithPath: await settingsStore.get(.cacheDir) ?? "")
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        let client = EdinetAPIClient(apiKey: key, cacheStore: store)

        let currentYear = Calendar.current.component(.year, from: Date())
        for year in (currentYear - years + 1)...currentYear {
            print("  \(year)年 を追いつかせています...")
            let docs = await client.catchupDocumentIndexForYear(year)
            print("    → \(docs.count) 件")
        }
        print("完了しました。")
    }
}

struct CacheRefresh: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh",
        abstract: "インデックスを強制再構築します"
    )

    @Option(name: .shortAndLong, help: "対象年数")
    var years: Int = Api.prepareDefaultYears

    func run() async throws {
        let apiKey = await settingsStore.get(.edinetApiKey)
        guard let key = apiKey, !key.isEmpty else {
            fputs("EDINET API キーが設定されていません。\n", stderr)
            throw ExitCode.failure
        }
        let cacheDir = URL(fileURLWithPath: await settingsStore.get(.cacheDir) ?? "")
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        let client = EdinetAPIClient(apiKey: key, cacheStore: store)

        let currentYear = Calendar.current.component(.year, from: Date())
        for year in (currentYear - years + 1)...currentYear {
            print("  \(year)年 を再構築中...")
            let docs = await client.refreshDocumentIndexForYear(year)
            print("    → \(docs.count) 件")
        }
        print("完了しました。")
    }
}

struct CacheClean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "derived キャッシュを削除します"
    )

    @Flag(name: .long, help: "実際には削除せず内容を表示")
    var dryRun = false

    func run() async throws {
        let cacheDir = URL(fileURLWithPath: await settingsStore.get(.cacheDir) ?? "")
        let derived = derivedCacheDir(cacheDir)
        if dryRun {
            print("削除対象: \(derived.path)")
        } else {
            try? FileManager.default.removeItem(at: derived)
            print("derived キャッシュを削除しました。")
        }
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1_000_000
    return String(format: "%.1f MB", mb)
}
