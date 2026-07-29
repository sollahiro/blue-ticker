import ArgumentParser
import Foundation

/// Stage 7（Statement 本体）の BS/PL/CF 抽出を目視確認するための開発用コマンド。
/// `--bs`/`--pl`/`--cf` は少なくとも1つ必須（未指定時はエラー。「とりあえず全部」を暗黙で
/// 返さない）。EDINET から実際に XBRL を取得する（smoke fixture 経路は無い）。
struct DevStatementCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "statement",
        abstract: "Stage 7 の BS/PL/CF 抽出を実行し目視確認する（開発用）"
    )

    @Argument(help: "銘柄コード")
    var code: String

    @Argument(help: "書類ID（省略時は最新の有価証券報告書）")
    var docID: String?

    @Flag(name: .customLong("bs"), help: "貸借対照表を抽出する")
    var bs = false

    @Flag(name: .customLong("pl"), help: "損益計算書を抽出する")
    var pl = false

    @Flag(name: .customLong("cf"), help: "キャッシュ・フロー計算書を抽出する")
    var cf = false

    func run() async throws {
        var statementTypes: Set<StatementSectionType> = []
        if bs { statementTypes.insert(.balanceSheet) }
        if pl { statementTypes.insert(.incomeStatement) }
        if cf { statementTypes.insert(.cashFlow) }

        guard !statementTypes.isEmpty else {
            printError("エラー: --bs / --pl / --cf のうち少なくとも1つを指定してください。\n")
            throw ExitCode.failure
        }

        let ctx = try await MetricsLoader.prepare(rawCode: code)
        printError("対象: \(ctx.code) \(ctx.name)\n")

        let targetDocID: String
        if let docID, !docID.isEmpty {
            targetDocID = docID
        } else {
            let docs = await EdinetDiscovery.buildDocumentIndexForCode(
                code: ctx.code, client: ctx.client, analysisYears: 1
            )
            guard let latest = docs.first, let dId = latest["docID"] as? String else {
                printError("書類が見つかりませんでした: \(ctx.code)\n")
                throw ExitCode.failure
            }
            targetDocID = dId
        }
        printError("書類ID: \(targetDocID)\n")

        let analyzer = StatementAnalyzer(edinetClient: ctx.client)
        guard let year = await analyzer.extract(docID: targetDocID, statementTypes: statementTypes)
        else {
            printError("エラー: XBRLの取得または抽出に失敗しました。\n")
            throw ExitCode.failure
        }

        if statementTypes.contains(.balanceSheet) {
            printSection(title: "貸借対照表 (BS)", items: year.balanceSheet)
        }
        if statementTypes.contains(.incomeStatement) {
            printSection(title: "損益計算書 (PL)", items: year.incomeStatement)
        }
        if statementTypes.contains(.cashFlow) {
            printSection(title: "キャッシュ・フロー計算書 (CF)", items: year.cashFlow)
        }
    }

    private func printSection(title: String, items: [StatementLineItem]) {
        print("=== \(title): \(items.count)件 ===")
        for item in items {
            let label = item.label ?? "(ラベル不明)"
            let unit = item.unit ?? "-"
            print("  \(item.tag): \(label) = \(item.value) [\(unit)]")
        }
    }
}
