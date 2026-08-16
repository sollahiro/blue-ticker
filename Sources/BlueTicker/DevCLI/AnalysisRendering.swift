import Foundation

// ticker waterfall / summary / filing の表示ロジック。remote 経路（Ticker* コマンド）と
// ローカル経路（Dev* コマンド、DevCLI/）の両方から呼ばれる共通コード。取得手段（remote/local）に
// 依存せず、共通のドメインモデル（YearEntry / ExtractedBreakdown 等）だけを受け取る。

// MARK: - ticker waterfall（増減分析）

enum WaterfallRendering {
    /// 年次の増減分析を表示する。`commandPrefix` は案内文言に使うコマンド名（既定 `ticker-dev`）。
    static func renderAnnual(_ yearsData: [YearEntry], commandPrefix: String = "ticker-dev") {
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
        printError("\n水準値の一覧は \(commandPrefix) summary で確認できます。\n")
    }

    // MARK: - 5ブロック描画

    private static func render<T>(periods: [T], priors: [T?], columnLabels: [String], entry: @escaping (T) -> YearEntry, latest: YearEntry?) {
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

    private static func printNum<T>(_ periods: [T], _ entry: @escaping (T) -> YearEntry, _ metrics: [(String, (YearEntry) -> Double?)]) {
        MetricsTable.printNumericRows(periods, metrics.map { (l, g) in (l, { g(entry($0)) }) })
    }

    private static func printDelta<T>(_ periods: [T], _ priors: [T?], _ entry: @escaping (T) -> YearEntry, _ metrics: [(String, (YearEntry, YearEntry) -> Double?)]) {
        MetricsTable.printDeltaRows(periods, priors: priors, metrics.map { (l, g) in (l, { g(entry($0), entry($1)) }) })
    }

    /// 両者が非 nil のときのみ a − b を返す。
    private static func optDelta(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return a - b
    }
}

// MARK: - ticker summary（水準値一覧）

enum SummaryRendering {
    static func printYearTable(result: MetricsResult) {
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
        MetricsTable.printNumericRows(periods, levelMetrics(latest: periods.last))
        MetricsTable.printStringRows(periods, [("DocID", { $0.calculatedData.docID })])
        printError(MetricsTable.separator(columns: periods.count) + "\n")
    }

    // MARK: - レベル指標定義

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

// MARK: - ticker filing（セクション本文・セグメント表）

enum FilingRendering {
    /// セクション本文・セグメント表を人間向けに整形表示する。
    static func renderSections(
        docID: String, extracted: [String: String], extractedBreakdowns: [String: ExtractedBreakdown]
    ) {
        printError("\n[書類 \(docID)]\n")
        for (key, text) in extracted.sorted(by: { $0.key < $1.key }) {
            let def = xbrlSections[key]
            let title = def?.title ?? key
            printError("\n## \(title)\n")
            if text.isEmpty {
                printError("（見つかりませんでした）\n")
            } else {
                let truncated = text.count > 2000 ? String(text.prefix(2000)) + "..." : text
                printError(truncated + "\n")
            }
        }
        for (key, seg) in extractedBreakdowns.sorted(by: { $0.key < $1.key }) {
            let title = BreakdownExtractor.specialSectionTitles[key] ?? key
            printError("\n## \(title)\n")
            printExtractedBreakdown(seg)
        }
    }

    private static func printExtractedBreakdown(_ seg: ExtractedBreakdown) {
        switch seg.method {
        case "html_table":
            for t in seg.tables {
                let period = t.period.map { "（\($0)）" } ?? ""
                printError("\n### \(t.heading)\(period)\n\(t.markdown)\n")
            }
        case "xbrl_facts":
            printError("（HTML表未検出・dimensionファクト \(seg.facts.count) 件を集計）\n")
            printBreakdownFactsAsTable(seg.facts)
        default:
            printError("（見つかりませんでした）\n")
        }
    }

    private static func printBreakdownFactsAsTable(_ facts: [BreakdownFact]) {
        guard !facts.isEmpty else { return }

        func periodOf(_ ctx: String) -> (label: String, order: Int) {
            let patterns: [(String, String, Int)] = [
                ("Prior1YearDuration",    "前期",    0),
                ("Prior1InterimDuration", "前中間期", 1),
                ("CurrentYearDuration",   "当期",    2),
                ("CurrentYTDDuration",    "当期",    2),
                ("InterimDuration",       "中間期",   3),
                ("Prior1YearInstant",     "前期末",   4),
                ("Prior1InterimInstant",  "前中間末", 5),
                ("CurrentYearInstant",    "当期末",   6),
                ("InterimInstant",        "中間末",   7),
            ]
            for (prefix, label, order) in patterns {
                if ctx.hasPrefix(prefix) { return (label, order) }
            }
            return (ctx, 99)
        }

        func memberShortName(_ m: String) -> String {
            switch m {
            case "ReportableSegmentsMember": return "計"
            case "ReconcilingItemsMember":   return "調整"
            case "CorporateSharedMember":    return "全社"
            case "NonConsolidatedMember":    return "単体"
            case Xbrl.entityTotalMemberName: return "連結"
            default:
                var n = m
                for sfx in ["ReportableSegmentsMember", "ReportabelSegmentsMember",
                             "SegmentsMember", "Member"] {
                    if n.hasSuffix(sfx) { n = String(n.dropLast(sfx.count)); break }
                }
                if n.hasSuffix("BusinessUnit") { n = String(n.dropLast("BusinessUnit".count)) }
                return n.isEmpty ? m : n
            }
        }

        func memberSortOrder(_ m: String) -> Int {
            if m == "ReportableSegmentsMember" { return 90 }
            if m.contains("Corporate")         { return 91 }
            if m.contains("Reconciling")       { return 92 }
            if m == Xbrl.entityTotalMemberName { return 93 }
            if m.contains("NonConsolidated")   { return 95 }
            return 0
        }

        // primary segment member: prefer OperatingSegments/BusinessSegment/ReportableSegment axis
        let segAxisKeywords = ["OperatingSegments", "BusinessSegment", "ReportableSegment",
                                "GeographicArea", "Geography", "Country", "Region"]
        func primaryMember(_ f: BreakdownFact) -> String? {
            for (k, v) in f.dimensions {
                if segAxisKeywords.contains(where: { k.contains($0) }) { return v }
            }
            return f.dimensions.values.first
        }

        func fmtValue(_ v: Double, _ unit: String?) -> String {
            let u = (unit ?? "").uppercased()
            let isMonetary = u.isEmpty || u == "JPY" || u.hasPrefix("JPY")
            if isMonetary && abs(v) >= 1_000_000 {
                let m = v / 1_000_000
                return m == Double(Int(m))
                    ? String(format: "%.0f", m)
                    : String(format: "%.1f", m)
            }
            return String(format: "%.0f", v)
        }

        // Build pivot: periodLabel -> metricLabel -> member -> (value, unit)
        struct PKey: Hashable { let label: String; let order: Int }
        var memberSet = Set<String>()
        var pivot: [PKey: [String: [String: (Double, String?)]]] = [:]
        var allMetrics: [String] = []  // insertion-order unique

        for f in facts {
            guard let member = primaryMember(f) else { continue }
            let (pLabel, pOrder) = periodOf(f.contextRef)
            let pKey = PKey(label: pLabel, order: pOrder)
            let metric = f.label ?? f.tag
            memberSet.insert(member)
            if pivot[pKey] == nil { pivot[pKey] = [:] }
            if pivot[pKey]![metric] == nil {
                pivot[pKey]![metric] = [:]
                if !allMetrics.contains(metric) { allMetrics.append(metric) }
            }
            // first-write wins (prefer consolidated over non-consolidated)
            if pivot[pKey]![metric]![member] == nil {
                pivot[pKey]![metric]![member] = (f.value, f.unitRef)
            }
        }

        guard !memberSet.isEmpty, !pivot.isEmpty else {
            printError("（ファクトを表形式に変換できませんでした）\n")
            return
        }

        let sortedMembers = memberSet.sorted {
            let oa = memberSortOrder($0), ob = memberSortOrder($1)
            return oa != ob ? oa < ob : $0 < $1
        }
        let shortHeaders = sortedMembers.map { memberShortName($0) }
        let hasMonetary = facts.contains { f in
            let u = (f.unitRef ?? "").uppercased()
            return (u.isEmpty || u == "JPY" || u.hasPrefix("JPY")) && abs(f.value) >= 1_000_000
        }
        if hasMonetary { printError("（単位: 百万円）\n") }

        for pKey in pivot.keys.sorted(by: { $0.order < $1.order }) {
            guard let metrics = pivot[pKey], !metrics.isEmpty else { continue }
            printError("\n【\(pKey.label)】\n")
            let header = "| 指標 | " + shortHeaders.joined(separator: " | ") + " |"
            let sep    = "|---|" + shortHeaders.map { _ in "---:" }.joined(separator: "|") + "|"
            printError(header + "\n" + sep + "\n")
            for metric in allMetrics {
                guard let vals = metrics[metric] else { continue }
                let cells = sortedMembers.map { m -> String in
                    guard let (v, u) = vals[m] else { return "-" }
                    return fmtValue(v, u)
                }
                printError("| \(metric) | " + cells.joined(separator: " | ") + " |\n")
            }
        }
    }
}
