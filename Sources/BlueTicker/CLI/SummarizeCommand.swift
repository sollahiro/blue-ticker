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

    @Flag(name: .long, help: "キャッシュを使用しない")
    var noCache = false

    @Flag(name: .long, help: "半期データを表示")
    var half = false

    func run() async throws {
        if let remote = try await RemoteBackend.clientIfEnabled() {
            try await runRemote(remote)
            return
        }

        let ctx = try await MetricsLoader.prepare(rawCode: code)
        printError("\n集計中: \(ctx.code) \(ctx.name) ...\n")
        printError("対象期間: 直近 \(years) 年分\n")

        if half {
            let halfAnalyzer = HalfYearAnalyzer(edinetClient: ctx.client, cacheManager: ctx.cacheManager)
            guard let periods = await halfAnalyzer.analyze(code: ctx.code, analysisYears: years, useCache: !noCache) else {
                printError("エラー: 半期財務データの取得に失敗しました。APIキーが正しいか、書類が存在するか確認してください。\n")
                throw ExitCode.failure
            }
            if json { MetricsJSON.print(periods); return }
            printHalfTable(periods: periods)
            return
        }

        let analyzer = IndividualAnalyzer(edinetClient: ctx.client, cacheManager: ctx.cacheManager)
        guard let result = await analyzer.analyze(code: ctx.code, analysisYears: years, useCache: !noCache) else {
            printError("エラー: 財務データの取得に失敗しました。APIキーが正しいか、書類が存在するか確認してください。\n")
            throw ExitCode.failure
        }
        if json { MetricsJSON.print(result); return }
        printYearTable(result: result)
        printError("\n増減分析は ticker analyze、定性情報は ticker filing で確認できます。\n")
    }

    /// remote バックエンド経路。計算済み財務データを受け取り、ローカルと同じ水準値一覧を表示する。
    private func runRemote(_ remote: RemoteAPIClient) async throws {
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
            printHalfTable(periods: periods)
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
        printYearTable(result: result)
        printError("\n増減分析は ticker analyze、定性情報は ticker filing で確認できます。\n")
    }

    // MARK: - 年次テーブル

    private func printYearTable(result: MetricsResult) {
        guard let yearsData = result.years, !yearsData.isEmpty else {
            printError("指標データが見つかりませんでした。\n")
            return
        }
        let periods = yearsData.reversed().map { $0 }  // 古い順

        printError("\n[主要財務指標の推移]\n")
        MetricsTable.printHeader(
            title: "項目 \\ 年度",
            columnLabels: periods.map { MetricsTable.yearColumnLabel($0) }
        )
        MetricsTable.printNumericRows(periods, Self.levelMetrics(latest: periods.last))
        MetricsTable.printStringRows(periods, [("DocID", { $0.calculatedData.docID })])
        printError(MetricsTable.separator(columns: periods.count) + "\n")
    }

    // MARK: - 半期テーブル

    private func printHalfTable(periods: [HalfPeriod]) {
        guard !periods.isEmpty else {
            printError("半期データが見つかりませんでした。\n")
            return
        }

        printError("\n[半期財務推移]\n")
        MetricsTable.printHeader(title: "項目 \\ 期", columnLabels: periods.map { $0.label })

        // 年次と同じレベル指標を半期に適用（getter を yearEntry 経由に変換）
        let metrics = Self.levelMetrics(latest: periods.last?.yearEntry).map { (label, getter) in
            (label, { (p: HalfPeriod) in getter(p.yearEntry) })
        }
        MetricsTable.printNumericRows(periods, metrics)
        MetricsTable.printStringRows(periods, [("DocID", { $0.yearEntry.calculatedData.docID })])
        printError(MetricsTable.separator(columns: periods.count) + "\n")
    }

    // MARK: - レベル指標定義（年次・半期で共有）

    private static func levelMetrics(latest: YearEntry?) -> [(String, (YearEntry) -> Double?)] {
        let salesLabel = latest?.rawData.salesLabel.map { "\($0) (百万)" } ?? "売上高 (百万)"
        let gpLabel = "\(latest?.calculatedData.grossProfitLabel ?? "売上総利益") (百万)"
        let gpMarginLabel: String = {
            let l = latest?.calculatedData.grossProfitLabel ?? "売上総利益"
            return l == "売上総利益" ? "粗利率 (%)" : "\(l)率 (%)"
        }()
        let opLabel = (latest?.calculatedData.opLabel ?? "営業利益") + " (百万)"
        let opMarginLabel = (latest?.calculatedData.opLabel ?? "営業利益") + "率 (%)"

        return [
            (salesLabel,                 { $0.rawData.sales }),
            (gpLabel,                    { $0.calculatedData.grossProfit }),
            (gpMarginLabel,              { $0.calculatedData.grossProfitMargin }),
            ("販管費 (百万)",             { $0.calculatedData.sellingGeneralAdministrativeExpenses }),
            (opLabel,                    { $0.rawData.op }),
            (opMarginLabel,              { $0.calculatedData.operatingMargin }),
            ("NOPAT (百万)",             { $0.calculatedData.nopat }),
            ("純利益 (百万)",             { $0.rawData.np }),
            ("実効税率 (%)",              { $0.calculatedData.effectiveTaxRate }),
            ("ROE (%)",                  { $0.calculatedData.roe }),
            ("ROIC (%)",                 { $0.calculatedData.roic }),
            ("NOPATマージン (%)",         { $0.calculatedData.nopatMargin }),
            ("投下資本回転率 (倍)",       { $0.calculatedData.investedCapitalTurnover }),
            ("有利子負債合計 (百万)",     { $0.calculatedData.interestBearingDebt }),
            ("支払利息（P/L）(百万)",      { $0.calculatedData.interestExpense }),
            ("総資産 (百万)",             { $0.calculatedData.totalAssets }),
            ("流動資産 (百万)",           { $0.calculatedData.currentAssets }),
            ("  売掛金 (百万)",           { $0.calculatedData.accountsReceivable }),
            ("  棚卸資産 (百万)",         { $0.calculatedData.inventory }),
            ("固定資産 (百万)",           { $0.calculatedData.nonCurrentAssets }),
            ("  有形固定資産合計 (百万)", { $0.calculatedData.ppeTotal }),
            ("流動負債 (百万)",           { $0.calculatedData.currentLiabilities }),
            ("  買掛金 (百万)",           { $0.calculatedData.accountsPayable }),
            ("固定負債 (百万)",           { $0.calculatedData.nonCurrentLiabilities }),
            ("純資産 (百万)",             { $0.calculatedData.netAssets }),
            ("現金及び現金同等物 (百万)", { $0.rawData.cashEq }),
            ("ネットキャッシュ (百万)",   { $0.calculatedData.netCash }),
            ("ネットD/E (倍)",            { $0.calculatedData.netDE }),
            ("営業CF (百万)",             { $0.rawData.cfo }),
            ("投資CF (百万)",             { $0.rawData.cfi }),
            ("フリーCF (百万)",           { $0.calculatedData.cfc }),
            ("設備投資 (百万)",           { $0.rawData.capex }),
            ("自己株式取得（SS）(百万)",  { $0.rawData.buyback }),
            ("自己株式取得（CF）(百万)",  { $0.calculatedData.cfTreasuryStock }),
            ("配当（SS）(百万)",          { $0.calculatedData.dividendSS }),
            ("配当（CF）(百万)",          { $0.calculatedData.dividendPaidCF }),
            ("研究開発費 (百万)",         { $0.rawData.rd }),
        ]
    }
}
