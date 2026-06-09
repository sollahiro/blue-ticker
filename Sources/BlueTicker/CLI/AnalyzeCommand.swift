import ArgumentParser
import Foundation

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "銘柄の財務データを分析します"
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
        let apiKey = await settingsStore.get(.edinetApiKey)
        guard let key = apiKey, !key.isEmpty else {
            fputs("エラー: EDINET API キーが設定されていません。ticker config set edinet-key <key> で設定してください。\n", stderr)
            throw ExitCode.failure
        }

        let codeTrimmed = code.trimmingCharacters(in: .whitespaces)
        guard !codeTrimmed.isEmpty else {
            fputs("エラー: 銘柄コードを指定してください。\n", stderr)
            throw ExitCode.failure
        }

        let cacheDirStr = await settingsStore.get(.cacheDir) ?? ""
        let cacheDir = URL(fileURLWithPath: cacheDirStr)
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        let client = EdinetAPIClient(apiKey: key, cacheStore: store)
        let derivedDir = derivedCacheDir(cacheDir)
        let cacheManager = CacheManager(cacheDir: derivedDir)
        let masterDataManager = MasterDataManager()
        await masterDataManager.loadIfNeeded()

        let info = await masterDataManager.getByCode(codeTrimmed)
        let name = info?.coName ?? codeTrimmed
        let market = info?.mktNm ?? ""

        fputs("\n分析中: \(codeTrimmed) \(name) (\(market)) ...\n", stderr)
        fputs("分析対象期間: 直近 \(years) 年分\n", stderr)

        let analyzer = IndividualAnalyzer(edinetClient: client, cacheManager: cacheManager)
        guard let result = await analyzer.analyze(code: codeTrimmed, analysisYears: years, useCache: !noCache) else {
            fputs("エラー: 財務データの取得に失敗しました。APIキーが正しいか、書類が存在するか確認してください。\n", stderr)
            throw ExitCode.failure
        }

        if json {
            let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
            if let data = try? JSONEncoder().encode(result),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let outData = try? JSONSerialization.data(withJSONObject: dict, options: opts),
               let str = String(data: outData, encoding: .utf8) {
                print(str)
            }
            return
        }

        printTable(result: result)
        fputs("\n定性情報は ticker filing コマンドで抽出できます。\n", stderr)
    }

    // MARK: - Table Display

    private func printTable(result: MetricsResult) {
        guard let yearsData = result.years, !yearsData.isEmpty else {
            fputs("指標データが見つかりませんでした。\n", stderr)
            return
        }

        // 古い順に並べる（表示用）
        let periods = yearsData.reversed().map { $0 }

        fputs("\n[主要財務指標の推移]\n", stderr)

        let labelWidth = 22
        let colWidth = 11

        // ヘッダー
        var header = padRight("項目 \\ 年度", width: labelWidth)
        for p in periods {
            let fy = p.fyEnd ?? "不明"
            let (year, month) = extractYearMonth(fy)
            var label = ""
            if let y = year, let m = month {
                label = "\(y % 100)/\(String(format: "%02d", m))"
            } else {
                label = fy
            }
            if (p.rawData.curPerType ?? "FY") == "2Q" { label += "(2Q)" }
            header += padLeft(label, width: colWidth)
        }

        let sep = String(repeating: "-", count: labelWidth + colWidth * periods.count)
        fputs(sep + "\n", stderr)
        fputs(header + "\n", stderr)
        fputs(sep + "\n", stderr)

        let metricsToShow: [(String, (YearEntry) -> Double?)] = buildMetricsToShow(periods: periods)

        for (label, getter) in metricsToShow {
            let vals = periods.map { getter($0) }
            if vals.allSatisfy({ $0 == nil }) { continue }

            var row = padRight(label, width: labelWidth)
            for val in vals {
                if let v = val {
                    row += padLeft(String(format: "%.2f", v), width: colWidth)
                } else {
                    row += padLeft("-", width: colWidth)
                }
            }
            fputs(row + "\n", stderr)
        }

        // 文字列メトリクス（DocID等）
        let stringMetrics: [(String, (YearEntry) -> String?)] = [
            ("DocID", { $0.calculatedData.docID }),
        ]
        for (label, getter) in stringMetrics {
            let vals = periods.map { getter($0) }
            if vals.allSatisfy({ $0 == nil }) { continue }
            var row = padRight(label, width: labelWidth)
            for val in vals {
                row += padLeft(val ?? "-", width: colWidth)
            }
            fputs(row + "\n", stderr)
        }

        fputs(sep + "\n", stderr)
    }

    private func buildMetricsToShow(periods: [YearEntry]) -> [(String, (YearEntry) -> Double?)] {
        let latest = periods.last
        let salesLabel = latest?.rawData.salesLabel.map { "\($0) (百万)" } ?? "売上高 (百万)"
        let gpLabel: String = {
            let l = latest?.calculatedData.grossProfitLabel ?? "売上総利益"
            return "\(l) (百万)"
        }()
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
            ("支払利息 (百万)",           { $0.calculatedData.interestExpense }),
            ("総資産 (百万)",             { $0.calculatedData.totalAssets }),
            ("流動資産 (百万)",           { $0.calculatedData.currentAssets }),
            ("固定資産 (百万)",           { $0.calculatedData.nonCurrentAssets }),
            ("  有形固定資産合計 (百万)", { $0.calculatedData.ppeTotal }),
            ("流動負債 (百万)",           { $0.calculatedData.currentLiabilities }),
            ("固定負債 (百万)",           { $0.calculatedData.nonCurrentLiabilities }),
            ("純資産 (百万)",             { $0.calculatedData.netAssets }),
            ("現金及び現金同等物 (百万)", { $0.rawData.cashEq }),
            ("ネットキャッシュ (百万)",   { $0.calculatedData.netCash }),
            ("ネットD/E (倍)",            { $0.calculatedData.netDE }),
            ("営業CF (百万)",             { $0.rawData.cfo }),
            ("投資CF (百万)",             { $0.rawData.cfi }),
            ("フリーCF (百万)",           { $0.calculatedData.cfc }),
            ("設備投資 (百万)",           { $0.rawData.capex }),
            ("研究開発費 (百万)",         { $0.rawData.rd }),
        ]
    }

    private func padRight(_ s: String, width: Int) -> String {
        s.count >= width ? String(s.prefix(width)) : s + String(repeating: " ", count: width - s.count)
    }

    private func padLeft(_ s: String, width: Int) -> String {
        s.count >= width ? String(s.prefix(width)) : String(repeating: " ", count: width - s.count) + s
    }
}
