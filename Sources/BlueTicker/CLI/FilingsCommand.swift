import ArgumentParser
import Foundation

struct FilingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "filings",
        abstract: "銘柄の有価証券報告書一覧を表示します（Phase 3 実装予定）"
    )

    @Argument(help: "銘柄コード")
    var code: String

    @Option(name: .shortAndLong, help: "取得年数")
    var years: Int = Api.filingsDefaultYears

    @Flag(name: .long, help: "JSON 形式で出力")
    var json = false

    func run() async throws {
        fputs("[filings] Phase 3 で実装予定です。\n", stderr)
        throw ExitCode.failure
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
