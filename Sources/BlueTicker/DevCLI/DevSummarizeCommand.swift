import ArgumentParser
import Foundation

/// `ticker summarize` のローカル解析版（開発用。EDINET を直接叩き in-process で計算する）。
struct DevSummarizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summarize",
        abstract: "銘柄の主要財務指標を一覧表示します（ローカル解析）"
    )

    @Argument(help: "銘柄コード")
    var code: String

    @Option(name: .shortAndLong, help: "分析年数")
    var years: Int = Api.analyzeDefaultYears

    @Flag(name: .long, help: "JSON 形式で出力")
    var json = false

    @Flag(name: .long, help: "キャッシュを使用しない")
    var noCache = false

    @Flag(name: .long, help: "半期データを表示")
    var half = false

    func run() async throws {
        let ctx = try await MetricsLoader.prepare(rawCode: code)
        printError("\n集計中: \(ctx.code) \(ctx.name) ...\n")
        printError("対象期間: 直近 \(years) 年分\n")

        if half {
            let halfAnalyzer = HalfYearAnalyzer(edinetClient: ctx.client, cacheManager: ctx.cacheManager)
            guard let periods = await halfAnalyzer.analyze(code: ctx.code, analysisYears: years, useCache: !noCache).periodsOrNil else {
                printError("エラー: 半期財務データの取得に失敗しました。APIキーが正しいか、書類が存在するか確認してください。\n")
                throw ExitCode.failure
            }
            if json { MetricsJSON.print(periods); return }
            SummarizeRendering.printHalfTable(periods: periods)
            return
        }

        let analyzer = IndividualAnalyzer(edinetClient: ctx.client, cacheManager: ctx.cacheManager)
        guard let result = await analyzer.analyze(code: ctx.code, analysisYears: years, useCache: !noCache).resultOrNil else {
            printError("エラー: 財務データの取得に失敗しました。APIキーが正しいか、書類が存在するか確認してください。\n")
            throw ExitCode.failure
        }
        if json { MetricsJSON.print(result); return }
        SummarizeRendering.printYearTable(result: result)
        printError("\n増減分析は ticker-dev analyze、定性情報は ticker-dev filing で確認できます。\n")
    }
}
