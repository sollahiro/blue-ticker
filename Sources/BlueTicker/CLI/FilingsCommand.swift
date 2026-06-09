import ArgumentParser
import Foundation

struct FilingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "filings",
        abstract: "銘柄の有価証券報告書一覧を表示します"
    )

    @Argument(help: "銘柄コード")
    var code: String

    @Option(name: .shortAndLong, help: "取得年数")
    var years: Int = Api.filingsDefaultYears

    @Flag(name: .long, help: "JSON 形式で出力")
    var json = false

    func run() async throws {
        let apiKey = await settingsStore.get(.edinetApiKey)
        guard let key = apiKey, !key.isEmpty else {
            fputs("エラー: EDINET API キーが設定されていません。ticker config set edinet-key <key> で設定してください。\n", stderr)
            throw ExitCode.failure
        }
        let cacheDirStr = await settingsStore.get(.cacheDir) ?? ""
        let cacheDir = URL(fileURLWithPath: cacheDirStr)
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        let client = EdinetAPIClient(apiKey: key, cacheStore: store)
        let service = FilingService(edinetClient: client)

        let docs = await service.searchFilings(
            code: code,
            maxYears: years,
            docTypes: ["120", "130", "140", "150", "160", "170"],
            maxDocuments: 10
        )

        if docs.isEmpty {
            fputs("書類が見つかりませんでした: \(code)\n", stderr)
            throw ExitCode.failure
        }

        if json {
            let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
            if let data = try? JSONSerialization.data(withJSONObject: docs, options: opts),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            printTable(
                columns: [
                    TableColumn("書類ID", width: 16),
                    TableColumn("種別", width: 6),
                    TableColumn("提出日時", width: 20),
                    TableColumn("書類名", width: 60),
                ],
                rows: docs.map { [
                    $0["docID"] as? String ?? "",
                    $0["docTypeCode"] as? String ?? "",
                    $0["submitDateTime"] as? String ?? "",
                    $0["docDescription"] as? String ?? "",
                ]}
            )
        }
    }
}

struct FilingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "filing",
        abstract: "有価証券報告書のセクション内容を表示します（Phase 3 実装予定）"
    )

    @Argument(help: "銘柄コード")
    var code: String

    @Option(name: .long, help: "セクション (risks / mda / policy)")
    var section: String = "risks"

    @Flag(name: .long, help: "JSON 形式で出力")
    var json = false

    func run() async throws {
        fputs("[filing] Phase 3 で実装予定です。\n", stderr)
        throw ExitCode.failure
    }
}
