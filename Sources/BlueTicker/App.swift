import ArgumentParser
import Foundation

// @main は Sources/BlueTickerMain/main.swift に移動
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
public struct Ticker: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ticker",
        abstract: "BLUE TICKER — 日本株財務データ CLI",
        version: blueTickerVersion,
        subcommands: [
            SearchCommand.self,
            AnalyzeCommand.self,
            SummarizeCommand.self,
            ConfigCommand.self,
            CacheCommand.self,
            FilingsCommand.self,
            FilingCommand.self,
            SectorCommand.self,
        ]
    )

    public init() {}
}
