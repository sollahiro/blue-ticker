import ArgumentParser
import Foundation

struct SummarizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summarize",
        abstract: "銘柄の主要財務指標を一覧表示します"
    )

    @Argument(help: "銘柄コード")
    var code: String

    @Option(name: .shortAndLong, help: "分析年数")
    var years: Int = Api.analyzeDefaultYears

    @Flag(name: .long, help: "JSON 形式で出力")
    var json = false

    @Flag(name: .long, help: "半期データを表示")
    var half = false

    func run() async throws {
        let remote = try await RemoteBackend.client()
        let codeTrimmed = code.trimmingCharacters(in: .whitespaces)

        if half {
            let resp: HalfFinancialsResponse
            switch await remote.getHalfFinancials(code: codeTrimmed, years: years) {
            case .ok(let r): resp = r
            case .notFound(let m), .failure(let m): printError(m + "\n"); throw ExitCode.failure
            }
            let periods = resp.toPeriods()
            guard !periods.isEmpty else {
                printError("エラー: 半期財務データの取得に失敗しました。\n")
                throw ExitCode.failure
            }
            printError("\n集計中: \(codeTrimmed) \(resp.name) ...\n")
            printError("対象期間: 直近 \(years) 年分\n")
            if json { MetricsJSON.print(periods); return }
            SummarizeRendering.printHalfTable(periods: periods)
            return
        }

        let resp: FinancialsResponse
        switch await remote.getFinancials(code: codeTrimmed, years: years) {
        case .ok(let r): resp = r
        case .notFound(let m), .failure(let m): printError(m + "\n"); throw ExitCode.failure
        }

        let result = resp.toMetricsResult()
        guard let yearsData = result.years, !yearsData.isEmpty else {
            printError("エラー: 財務データの取得に失敗しました。\n")
            throw ExitCode.failure
        }
        printError("\n集計中: \(codeTrimmed) \(resp.name) ...\n")
        printError("対象期間: 直近 \(years) 年分\n")
        if json { MetricsJSON.print(result); return }
        SummarizeRendering.printYearTable(result: result)
        printError("\n増減分析は ticker analyze、定性情報は ticker filing で確認できます。\n")
    }
}
