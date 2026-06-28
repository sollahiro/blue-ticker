import ArgumentParser
import Foundation

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "銘柄の財務指標を増減分析（前年差分解）します"
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
        printError("\n分析中: \(ctx.code) \(ctx.name) ...\n")
        printError("分析対象期間: 直近 \(years) 年分\n")

        if half {
            let halfAnalyzer = HalfYearAnalyzer(edinetClient: ctx.client, cacheManager: ctx.cacheManager)
            guard let periods = await halfAnalyzer.analyze(code: ctx.code, analysisYears: years, useCache: !noCache) else {
                printError("エラー: 半期財務データの取得に失敗しました。APIキーが正しいか、書類が存在するか確認してください。\n")
                throw ExitCode.failure
            }
            renderHalf(periods)
            return
        }

        let analyzer = IndividualAnalyzer(edinetClient: ctx.client, cacheManager: ctx.cacheManager)
        guard let result = await analyzer.analyze(code: ctx.code, analysisYears: years, useCache: !noCache),
              let yearsData = result.years, !yearsData.isEmpty else {
            printError("エラー: 財務データの取得に失敗しました。APIキーが正しいか、書類が存在するか確認してください。\n")
            throw ExitCode.failure
        }
        if json { MetricsJSON.print(result); return }
        renderAnnual(yearsData)
    }

    /// remote バックエンド経路。計算済み財務データを受け取り、ローカルと同じ増減分析を表示する。
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
            printError("\n分析中: \(codeTrimmed) \(resp.name) ...\n")
            printError("分析対象期間: 直近 \(years) 年分\n")
            renderHalf(periods)
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
        printError("\n分析中: \(codeTrimmed) \(resp.name) ...\n")
        printError("分析対象期間: 直近 \(years) 年分\n")
        if json { MetricsJSON.print(result); return }
        renderAnnual(yearsData)
    }

    /// 半期の増減分析を表示する（ローカル・remote 共通）。
    private func renderHalf(_ periods: [HalfPeriod]) {
        if json { MetricsJSON.print(periods); return }
        printError("\n[半期 増減分析]\n")
        // 前期 = 同じ半期（H1/H2）の直近の過去期。欠落期があってもラベル意味（前年同期差）を保つ。
        let priors: [HalfPeriod?] = periods.indices.map { i in
            periods[..<i].last { $0.half == periods[i].half }
        }
        render(
            periods: periods,
            priors: priors,
            columnLabels: periods.map { $0.label },
            entry: { $0.yearEntry },
            latest: periods.last?.yearEntry
        )
    }

    /// 年次の増減分析を表示する（ローカル・remote 共通）。
    private func renderAnnual(_ yearsData: [YearEntry]) {
        let periods = yearsData.reversed().map { $0 }  // 古い順（前年差の基準）
        printError("\n[増減分析]\n")
        // 前期 = 直前の年度（年次は 1 期前）
        let priors: [YearEntry?] = periods.indices.map { $0 > 0 ? periods[$0 - 1] : nil }
        render(
            periods: periods,
            priors: priors,
            columnLabels: periods.map { MetricsTable.yearColumnLabel($0) },
            entry: { $0 },
            latest: periods.last
        )
        printError("\n水準値の一覧は ticker summarize で確認できます。\n")
    }

    // MARK: - 5ブロック描画（年次・半期で共有）

    private func render<T>(periods: [T], priors: [T?], columnLabels: [String], entry: @escaping (T) -> YearEntry, latest: YearEntry?) {
        MetricsTable.printHeader(title: "項目 \\ 期", columnLabels: columnLabels)

        let opLabel = latest?.calculatedData.opLabel ?? "営業利益"
        // 金融機関（経常利益・事業利益ベース）は事業利益分解の対象外（Waterfall の financialOPLabels と一致）
        let bpAvailable = !["経常利益", "事業利益"].contains(opLabel)

        // ① 事業利益増減分析
        if bpAvailable {
            printError("[① 事業利益増減分析]\n")
            printNum(periods, entry, [
                ("事業利益 (百万)",   { $0.calculatedData.businessProfit }),
                ("事業利益率 (%)",    { $0.calculatedData.businessProfitMargin }),
                ("事業利益前年差",     { $0.calculatedData.businessProfitChange }),
                ("  売上差影響",       { $0.calculatedData.salesChangeImpact }),
                ("  粗利率差影響",     { $0.calculatedData.grossMarginChangeImpact }),
                ("  販管費差影響",     { $0.calculatedData.sgaChangeImpact }),
            ])
        }

        // ② ROIC増減分析
        printError("[② ROIC増減分析]\n")
        printNum(periods, entry, [
            ("ROIC (%)",              { $0.calculatedData.roic }),
            ("NOPATマージン (%)",      { $0.calculatedData.nopatMargin }),
            ("投下資本回転率 (倍)",    { $0.calculatedData.investedCapitalTurnover }),
            ("ROIC前年差 (%)",        { $0.calculatedData.roicDelta }),
            ("  NOPATマージン差影響",  { $0.calculatedData.roicMarginEffect }),
            ("  投下資本回転率差影響", { $0.calculatedData.roicTurnoverEffect }),
        ])

        // ③ ROE増減分析
        printError("[③ ROE増減分析]\n")
        printNum(periods, entry, [
            ("ROE (%)",               { $0.calculatedData.roe }),
            ("純利益率 (%)",           { $0.calculatedData.netMargin }),
            ("総資産回転率 (倍)",      { $0.calculatedData.assetTurnover }),
            ("財務レバレッジ (倍)",    { $0.calculatedData.financialLeverage }),
            ("ROE前年差 (%)",         { $0.calculatedData.roeDelta }),
            ("  純利益率差影響",       { $0.calculatedData.roeNetMarginEffect }),
            ("  総資産回転率差影響",   { $0.calculatedData.roeAssetTurnoverEffect }),
            ("  財務レバレッジ差影響", { $0.calculatedData.roeLeverageEffect }),
        ])

        // ④ ネットキャッシュ増減分析（ネットキャッシュ = 現金 − 有利子負債）
        printError("[④ ネットキャッシュ増減分析]\n")
        printNum(periods, entry, [
            ("現金及び現金同等物 (百万)", { $0.rawData.cashEq }),
            ("有利子負債合計 (百万)",     { $0.calculatedData.interestBearingDebt }),
            ("ネットキャッシュ (百万)",   { $0.calculatedData.netCash }),
        ])
        printDelta(periods, priors, entry, [
            ("ネットキャッシュ前年差", { optDelta($0.calculatedData.netCash, $1.calculatedData.netCash) }),
            ("  現金差影響",           { optDelta($0.rawData.cashEq, $1.rawData.cashEq) }),
            ("  負債差影響",           { optDelta($1.calculatedData.interestBearingDebt, $0.calculatedData.interestBearingDebt) }),
        ])
        printNum(periods, entry, [
            ("ネットD/E (倍)",         { $0.calculatedData.netDE }),
        ])

        // ⑤ 運転資本・CCC増減分析
        printError("[⑤ 運転資本・CCC増減分析]\n")
        printNum(periods, entry, [
            ("売掛金 (百万)",   { $0.calculatedData.accountsReceivable }),
            ("棚卸資産 (百万)", { $0.calculatedData.inventory }),
            ("買掛金 (百万)",   { $0.calculatedData.accountsPayable }),
            ("運転資本 (百万)", { $0.calculatedData.workingCapital }),
        ])
        printDelta(periods, priors, entry, [
            ("運転資本前年差",       { optDelta($0.calculatedData.workingCapital, $1.calculatedData.workingCapital) }),
            ("  売掛金差影響",       { optDelta($0.calculatedData.accountsReceivable, $1.calculatedData.accountsReceivable) }),
            ("  棚卸資産差影響",     { optDelta($0.calculatedData.inventory, $1.calculatedData.inventory) }),
            ("  買掛金差影響",       { optDelta($1.calculatedData.accountsPayable, $0.calculatedData.accountsPayable) }),
        ])
        printNum(periods, entry, [
            ("DSO 売上債権回転日数 (日)", { $0.calculatedData.dso }),
            ("DIO 棚卸資産回転日数 (日)", { $0.calculatedData.dio }),
            ("DPO 仕入債務回転日数 (日)", { $0.calculatedData.dpo }),
            ("CCC (日)",                  { $0.calculatedData.ccc }),
        ])
        printDelta(periods, priors, entry, [
            ("CCC前年差 (日)",   { optDelta($0.calculatedData.ccc, $1.calculatedData.ccc) }),
            ("  DSO差影響",      { optDelta($0.calculatedData.dso, $1.calculatedData.dso) }),
            ("  DIO差影響",      { optDelta($0.calculatedData.dio, $1.calculatedData.dio) }),
            ("  DPO差影響",      { optDelta($1.calculatedData.dpo, $0.calculatedData.dpo) }),
        ])

        printError(MetricsTable.separator(columns: columnLabels.count) + "\n")
    }

    // MARK: - 描画ヘルパー（YearEntry ベースの定義を T へ橋渡し）

    private func printNum<T>(_ periods: [T], _ entry: @escaping (T) -> YearEntry, _ metrics: [(String, (YearEntry) -> Double?)]) {
        MetricsTable.printNumericRows(periods, metrics.map { (l, g) in (l, { g(entry($0)) }) })
    }

    private func printDelta<T>(_ periods: [T], _ priors: [T?], _ entry: @escaping (T) -> YearEntry, _ metrics: [(String, (YearEntry, YearEntry) -> Double?)]) {
        MetricsTable.printDeltaRows(periods, priors: priors, metrics.map { (l, g) in (l, { g(entry($0), entry($1)) }) })
    }

    /// 両者が非 nil のときのみ a − b を返す。
    private func optDelta(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return a - b
    }
}
