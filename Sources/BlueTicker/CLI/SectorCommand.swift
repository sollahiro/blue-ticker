import ArgumentParser
import Foundation

struct SectorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sector",
        abstract: "東証33業種の一覧と銘柄数を表示します"
    )

    @Flag(name: .long, help: "JSON 形式で出力")
    var json = false

    func run() async throws {
        let remote = try await RemoteBackend.client()
        let sectors: [SectorSummary]
        switch await remote.getSectors() {
        case .ok(let r): sectors = r
        case .notFound: sectors = []
        case .failure(let m): printError(m + "\n"); throw ExitCode.failure
        }

        if json {
            printJSON(sectors)
        } else {
            printTable(
                columns: [
                    TableColumn("業種名", width: 30),
                    TableColumn("銘柄数", width: 6, rightAlign: true),
                ],
                rows: sectors.map { [$0.name, String($0.count)] }
            )
        }
    }
}
