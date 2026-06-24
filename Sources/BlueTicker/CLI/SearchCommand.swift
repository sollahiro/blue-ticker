import ArgumentParser
import Foundation

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "銘柄コードまたは名称で企業を検索します"
    )

    @Argument(help: "銘柄コードまたは名称")
    var query: String

    @Flag(name: .long, help: "JSON 形式で出力")
    var json = false

    func run() async throws {
        let results: [StockSearchResult]
        if let remote = try await RemoteBackend.clientIfEnabled() {
            switch await remote.searchCompanies(q: query) {
            case .ok(let r): results = r
            case .notFound: results = []
            case .failure(let m): printError(m + "\n"); throw ExitCode.failure
            }
        } else {
            results = await CompanyInfoService().searchCompanies(query)
        }

        if results.isEmpty {
            printError("該当する銘柄が見つかりませんでした: \(query)\n")
            return
        }

        if json {
            printJSON(results)
        } else {
            printTable(
                columns: [
                    TableColumn("コード", width: 6),
                    TableColumn("銘柄名", width: 40),
                    TableColumn("業種", width: 20),
                    TableColumn("所在地", width: 20),
                ],
                rows: results.map { [$0.code, $0.name, $0.sector, $0.location] }
            )
        }
    }
}
