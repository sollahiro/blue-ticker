import ArgumentParser
import Foundation

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "銘柄の財務指標を増減分析（前年差分解）します"
    )

    @Argument(help: "銘柄コード")
    var code: String

    @Flag(name: .long, help: "JSON 形式で出力")
    var json = false

    @Flag(name: .long, help: "半期データを表示")
    var half = false

    func run() async throws {
        let remote = try await RemoteBackend.client()
        let codeTrimmed = code.trimmingCharacters(in: .whitespaces)

        if half {
            let years = Api.halfMaxYears
            let resp: HalfFinancialsResponse
            switch await remote.getHalfAnalysis(code: codeTrimmed, years: years) {
            case .ok(let r): resp = r
            case .notFound(let m), .failure(let m): printError(m + "\n"); throw ExitCode.failure
            }
            let periods = resp.toPeriods()
            guard !periods.isEmpty else {
                printError("エラー: 半期財務データの取得に失敗しました。\n")
                throw ExitCode.failure
            }
            printError("\n分析中: \(codeTrimmed) \(resp.name) ...\n")
            printError(AnalyzeRendering.halfAnalysisPeriodText(periods) + "\n")
            if json { MetricsJSON.print(periods); return }
            AnalyzeRendering.renderHalf(periods)
            return
        }

        let years = Api.financialsYearsDefault
        let resp: FinancialsResponse
        switch await remote.getAnalysis(code: codeTrimmed, years: years) {
        case .ok(let r): resp = r
        case .notFound(let m), .failure(let m): printError(m + "\n"); throw ExitCode.failure
        }

        let result = resp.toMetricsResult()
        guard let yearsData = result.years, !yearsData.isEmpty else {
            printError("エラー: 財務データの取得に失敗しました。\n")
            throw ExitCode.failure
        }
        printError("\n分析中: \(codeTrimmed) \(resp.name) ...\n")
        printError("分析対象期間: 直近 \(years) 年分\n")
        if json { MetricsJSON.print(result); return }
        AnalyzeRendering.renderAnnual(yearsData)
    }
}
