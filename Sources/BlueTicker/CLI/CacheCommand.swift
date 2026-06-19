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
            printError("EDINET API キーが設定されていません。`ticker config set --edinet-api-key <KEY>` で設定してください。\n")
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
        abstract: "今日までの最新データを取得します"
    )

    @Option(name: .shortAndLong, help: "対象年数")
    var years: Int = Api.prepareDefaultYears

    func run() async throws {
        let apiKey = await settingsStore.get(.edinetApiKey)
        guard let key = apiKey, !key.isEmpty else {
            printError("EDINET API キーが設定されていません。\n")
            throw ExitCode.failure
        }
        let cacheDir = URL(fileURLWithPath: await settingsStore.get(.cacheDir) ?? "")
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        let client = EdinetAPIClient(apiKey: key, cacheStore: store)

        let currentYear = Calendar.current.component(.year, from: Date())
        for year in (currentYear - years + 1)...currentYear {
            print("  \(year)年のデータを取得中です。")
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
            printError("EDINET API キーが設定されていません。\n")
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
        abstract: "EDINET キャッシュを整理します"
    )

    @Flag(name: .long, help: "実際には削除せず対象を表示")
    var dryRun = false

    @Option(name: .long, help: "指定日数より古い EDINET 検索キャッシュを削除")
    var edinetSearchDays: Int? = nil

    @Option(name: .long, help: "指定日数より古い XBRL ディレクトリを削除")
    var edinetXbrlDays: Int? = nil

    @Option(name: .long, help: "保持する年次インデックスの年数（デフォルト: \(Api.documentIndexKeepYears)、0 で全削除）")
    var edinetDocIndexYears: Int = Api.documentIndexKeepYears

    func run() async throws {
        let cacheDir = URL(fileURLWithPath: await settingsStore.get(.cacheDir) ?? "")
        let pruner = CachePruner(cacheDir: cacheDir)

        let summary = pruner.prune(
            dryRun: dryRun,
            edinetSearchDays: edinetSearchDays,
            edinetXbrlDays: edinetXbrlDays,
            edinetDocIndexYears: edinetDocIndexYears
        )

        let mb = Double(summary.freedBytes) / 1_000_000
        if dryRun {
            print("[dry-run] 削除対象: ファイル \(summary.scannedFiles) 件, ディレクトリ \(summary.scannedDirs) 件 (\(String(format: "%.1f", mb)) MB)")
        } else {
            print("[実行] 削除: ファイル \(summary.removedFiles) 件, ディレクトリ \(summary.removedDirs) 件")
            print("[実行] 解放: \(String(format: "%.1f", mb)) MB")
        }
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1_000_000
    return String(format: "%.1f MB", mb)
}
