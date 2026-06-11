import ArgumentParser
import Foundation

@main
struct Ticker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ticker",
        abstract: "BLUE TICKER — 日本株財務データ CLI",
        version: "26.6.0",
        subcommands: [
            SearchCommand.self,
            SummarizeCommand.self,
            ConfigCommand.self,
            CacheCommand.self,
            FilingsCommand.self,
            FilingCommand.self,
            SectorCommand.self,
        ]
    )
}
