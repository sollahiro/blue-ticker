import ArgumentParser
import Foundation

// TickerDev（配布しない開発用ローカル解析 CLI）の唯一の public エントリポイント。
// Server/BltServerFacade.swift と同型のナロー facade: このモジュール（BlueTickerCore）内の
// 実装（EdinetAPIClient・IndividualAnalyzer・HalfYearAnalyzer 等）はすべて internal のまま保ち、
// Sources/TickerDevMain/ から到達できる公開面はこの1点のみに絞る。
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
public struct DevCLIEntry: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ticker-dev",
        abstract: "BLUE TICKER — 開発用ローカル解析 CLI（配布しない。EDINET を直接叩く）",
        version: blueTickerVersion,
        subcommands: [
            DevSearchCommand.self,
            DevAnalyzeCommand.self,
            DevSummarizeCommand.self,
            CacheCommand.self,
            DevFilingsCommand.self,
            DevFilingCommand.self,
        ]
    )

    public init() {}
}
