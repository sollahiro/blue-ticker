import ArgumentParser
import Foundation

/// `ticker waterfall` のローカル解析版（開発用。EDINET を直接叩き in-process で計算する）。
struct DevWaterfallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "waterfall",
        abstract: "銘柄の財務指標を増減分析（前年差分解）します（ローカル解析）"
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
        let ctx = try await MetricsLoader.prepare(rawCode: code)
        printError("\n分析中: \(ctx.code) \(ctx.name) ...\n")
        printError("分析対象期間: 直近 \(years) 年分\n")

        let analyzer = IndividualAnalyzer(edinetClient: ctx.client, cacheManager: ctx.cacheManager)
        guard let result = await analyzer.analyze(code: ctx.code, analysisYears: years, useCache: !noCache).resultOrNil,
              let yearsData = result.years, !yearsData.isEmpty else {
            printError("エラー: 財務データの取得に失敗しました。APIキーが正しいか、書類が存在するか確認してください。\n")
            throw ExitCode.failure
        }
        if json { MetricsJSON.print(result); return }
        WaterfallRendering.renderAnnual(yearsData, commandPrefix: "ticker-dev")
    }
}
