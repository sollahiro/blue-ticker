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
        abstract: "有価証券報告書のセクション内容を抽出します"
    )

    @Argument(help: "銘柄コード")
    var code: String

    @Option(name: .long, help: "書類ID（省略時は最新の有価証券報告書）")
    var docId: String?

    @Option(name: .long, help: "抽出セクション: risks/mda/capex_overview/major_facilities/research_and_development")
    var sections: [String] = []

    @Flag(name: .long, help: "JSON 形式で出力")
    var json = false

    func run() async throws {
        let apiKey = await settingsStore.get(.edinetApiKey)
        guard let key = apiKey, !key.isEmpty else {
            fputs("エラー: EDINET API キーが設定されていません。ticker config set edinet-key <key> で設定してください。\n", stderr)
            throw ExitCode.failure
        }

        let codeTrimmed = code.trimmingCharacters(in: .whitespaces)
        let cacheDirStr = await settingsStore.get(.cacheDir) ?? ""
        let cacheDir = URL(fileURLWithPath: cacheDirStr)
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        let client = EdinetAPIClient(apiKey: key, cacheStore: store)

        // 書類IDを決定
        let targetDocID: String
        if let dId = docId, !dId.isEmpty {
            targetDocID = dId
        } else {
            // 最新の有価証券報告書を検索
            let docs = await EdinetDiscovery.buildDocumentIndexForCode(
                code: codeTrimmed, client: client, analysisYears: 1
            )
            guard let latest = docs.first, let dId = latest["docID"] as? String else {
                fputs("書類が見つかりませんでした: \(codeTrimmed)\n", stderr)
                throw ExitCode.failure
            }
            targetDocID = dId
            fputs("書類ID: \(targetDocID)\n", stderr)
        }

        // XBRL ダウンロード
        guard let xbrlDir = await client.downloadDocument(targetDocID) else {
            fputs("XBRLのダウンロードに失敗しました: \(targetDocID)\n", stderr)
            throw ExitCode.failure
        }

        // セクション抽出
        let targetSections = sections.isEmpty ? Array(xbrlSections.keys) : sections
        let parser = XBRLParser()
        var result: [String: Any] = ["docID": targetDocID, "code": codeTrimmed]
        var extracted: [String: String] = [:]

        for sectionKey in targetSections {
            if let sectionDef = xbrlSections[sectionKey] {
                let text = parser.extractSection(in: xbrlDir, sectionName: sectionDef.title)
                extracted[sectionKey] = text ?? ""
            }
        }
        result["sections"] = extracted

        if json {
            let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: opts),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            fputs("\n[書類 \(targetDocID)]\n", stderr)
            for (key, text) in extracted.sorted(by: { $0.key < $1.key }) {
                let def = xbrlSections[key]
                let title = def?.title ?? key
                fputs("\n## \(title)\n", stderr)
                if text.isEmpty {
                    fputs("（見つかりませんでした）\n", stderr)
                } else {
                    let truncated = text.count > 2000 ? String(text.prefix(2000)) + "..." : text
                    fputs(truncated + "\n", stderr)
                }
            }
        }
    }
}
