import ArgumentParser
import Foundation

// NOTE: XBRL 解析（Phase 3）未実装のため、このコマンドは Phase 3 完了まで stub。
struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "銘柄の財務データを分析します（Phase 3 実装予定）"
    )

    @Argument(help: "銘柄コード")
    var code: String

    @Option(name: .shortAndLong, help: "分析年数")
    var years: Int = Api.analyzeDefaultYears

    @Flag(name: .long, help: "JSON 形式で出力")
    var json = false

    @Flag(name: .long, help: "キャッシュを使用しない")
    var noCache = false

    func run() async throws {
        fputs("[analyze] XBRL 解析は Phase 3 で実装予定です。\n", stderr)
        throw ExitCode.failure
    }
}
