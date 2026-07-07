import Foundation

// MARK: - HalfYearAnalyzer
// Python の blue_ticker/services/half_year_data_service.py 相当 (XBRL パスのみ)
// FY / 2Q XBRL から H1/H2 の半期財務指標を構築する。

private let _halfCacheVersion = blueTickerVersion
private let _halfDiscoveryYears = Api.halfMaxYears

struct HalfYearAnalyzer {
    let edinetClient: EdinetAPIClient
    let cacheManager: CacheManager

    // MARK: - Public Entry Point

    func analyze(
        code: String,
        analysisYears: Int = 3,
        useCache: Bool = true
    ) async -> [HalfPeriod]? {
        let cacheKey = "half_year_periods_\(code)"

        if useCache {
            if let cached = await cacheManager.getJSON(cacheKey),
               (cached["_cache_version"] as? String) == _halfCacheVersion,
               let data = try? JSONSerialization.data(withJSONObject: cached),
               let wrapper = try? JSONDecoder().decode(HalfYearCache.self, from: data) {
                return trimPeriods(wrapper.periods, to: analysisYears)
            }
        }

        guard let periods = await fetchAndBuild(code: code) else { return nil }

        let wrapper = HalfYearCache(periods: periods)
        if let data = try? JSONEncoder().encode(wrapper),
           var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict["_cache_version"] = _halfCacheVersion
            await cacheManager.setJSON(cacheKey, value: dict)
        }
        return trimPeriods(periods, to: analysisYears)
    }

    // MARK: - Fetch and Build

    private func fetchAndBuild(code: String) async -> [HalfPeriod]? {
        let annualDocs = await EdinetDiscovery.buildDocumentIndexForCode(
            code: code, client: edinetClient, analysisYears: _halfDiscoveryYears
        )
        guard !annualDocs.isEmpty else { return nil }

        let halfDocs = await EdinetDiscovery.buildHalfYearDocumentIndexForCode(
            code: code, client: edinetClient, analysisYears: _halfDiscoveryYears,
            prebuiltAnnualDocs: annualDocs
        )
        guard !halfDocs.isEmpty else { return nil }

        let analyzer = IndividualAnalyzer(edinetClient: edinetClient, cacheManager: cacheManager)

        let fyDocs = annualDocs.filter {
            ($0["period_type"] as? String) == "FY" && ($0["_is_amendment"] as? Bool) != true
        }

        // FY / 2Q docs を並列処理（メモリピーク抑制のため並列度を制限）
        // [String: Any] は Sendable 非準拠のため @unchecked Sendable ラッパーでクロージャ境界を渡す
        struct SendableDoc: @unchecked Sendable { let value: [String: Any] }

        let fyPairs: [(String, YearEntry)] = await withBoundedTaskGroup(
            items: fyDocs.map { SendableDoc(value: $0) },
            limit: Api.xbrlProcessConcurrency
        ) { d in
            guard let fyEnd = d.value["edinet_fy_end"] as? String,
                  let entry = await analyzer.processDocument(d.value) else { return nil }
            return (fyEnd, entry)
        }
        var fyEntries: [String: YearEntry] = [:]
        for (k, v) in fyPairs { fyEntries[k] = v }

        let q2Pairs: [(String, YearEntry)] = await withBoundedTaskGroup(
            items: halfDocs.map { SendableDoc(value: $0) },
            limit: Api.xbrlProcessConcurrency
        ) { d in
            guard let fyEnd = d.value["edinet_fy_end"] as? String,
                  let entry = await analyzer.processDocument(d.value) else { return nil }
            return (fyEnd, entry)
        }
        var q2Entries: [String: YearEntry] = [:]
        for (k, v) in q2Pairs { q2Entries[k] = v }
        guard !q2Entries.isEmpty else { return nil }

        // H1: 全 Q2 エントリ（FY 有無を問わず）
        let h1Pairs = q2Entries.sorted { $0.key > $1.key }.map { (fyEnd: $0.key, entry: $0.value) }

        // H2: Q2 かつ FY が揃うもの（完結ペア）
        let h2Pairs: [(fyEnd: String, entry: YearEntry)] = h1Pairs.compactMap { (fyEnd, h1Entry) in
            guard let fyEntry = fyEntries[fyEnd] else { return nil }
            return (fyEnd, buildH2Entry(fy: fyEntry, h1: h1Entry, fyEnd: fyEnd))
        }

        // 半期別にウォーターフォール適用
        var h1YEs = h1Pairs.map { $0.entry }
        var h2YEs = h2Pairs.map { $0.entry }
        applyOperatingProfitChangeToYears(&h1YEs)
        applyOperatingProfitChangeToYears(&h2YEs)
        applyRoicWaterfallToYears(&h1YEs)
        applyRoicWaterfallToYears(&h2YEs)
        applyRoeWaterfallToYears(&h1YEs)
        applyRoeWaterfallToYears(&h2YEs)
        applyWorkingCapitalAndCCCToYears(&h1YEs)
        applyWorkingCapitalAndCCCToYears(&h2YEs)

        var periods: [HalfPeriod] = []
        for (i, (fyEnd, _)) in h1Pairs.enumerated() {
            periods.append(HalfPeriod(label: halfLabel(fyEnd, "H1"), half: "H1", fyEnd: fyEnd, yearEntry: h1YEs[i]))
        }
        for (i, (fyEnd, _)) in h2Pairs.enumerated() {
            periods.append(HalfPeriod(label: halfLabel(fyEnd, "H2"), half: "H2", fyEnd: fyEnd, yearEntry: h2YEs[i]))
        }

        // 古い順・同年内は H1 → H2
        periods.sort {
            if $0.fyEnd == $1.fyEnd { return ($0.half ?? "FY") < ($1.half ?? "FY") }
            return ($0.fyEnd ?? "") < ($1.fyEnd ?? "")
        }

        return periods.isEmpty ? nil : periods
    }

    // MARK: - H2 Derivation

    /// H2 = FY フロー - H1 フロー、BS は FY 期末値を使用。
    /// テスト容易化のため internal（モジュール内可視）。
    func buildH2Entry(fy: YearEntry, h1: YearEntry, fyEnd: String) -> YearEntry {
        var raw = RawData()
        var calc = CalculatedData()

        raw.curPerType = "H2"
        raw.curFYEn = fyEnd
        raw.salesLabel = fy.rawData.salesLabel
        raw.discDate = fy.rawData.discDate

        // フロー: FY − H1
        raw.sales   = sub(fy.rawData.sales,   h1.rawData.sales)
        raw.op      = sub(fy.rawData.op,       h1.rawData.op)
        raw.np      = sub(fy.rawData.np,       h1.rawData.np)
        raw.cfo     = sub(fy.rawData.cfo,      h1.rawData.cfo)
        raw.cfi     = sub(fy.rawData.cfi,      h1.rawData.cfi)
        raw.capex   = sub(fy.rawData.capex,    h1.rawData.capex)
        raw.rd      = sub(fy.rawData.rd,       h1.rawData.rd)
        raw.buyback = sub(fy.rawData.buyback,  h1.rawData.buyback)

        // BS: FY 期末スナップショット
        raw.netAssets              = fy.rawData.netAssets
        raw.cashEq                 = fy.rawData.cashEq
        calc.totalAssets           = fy.calculatedData.totalAssets
        calc.currentAssets         = fy.calculatedData.currentAssets
        calc.nonCurrentAssets      = fy.calculatedData.nonCurrentAssets
        calc.currentLiabilities    = fy.calculatedData.currentLiabilities
        calc.nonCurrentLiabilities = fy.calculatedData.nonCurrentLiabilities
        calc.netAssets             = fy.calculatedData.netAssets
        calc.interestBearingDebt   = fy.calculatedData.interestBearingDebt
        calc.ibdAccountingStandard = fy.calculatedData.ibdAccountingStandard
        calc.ppeTotal              = fy.calculatedData.ppeTotal
        calc.ppeAccountingStandard = fy.calculatedData.ppeAccountingStandard
        calc.balanceSheetAccountingStandard = fy.calculatedData.balanceSheetAccountingStandard
        // BS 運転資本（Instant スナップショット）: FY 期末値を使用。
        // applyWorkingCapitalAndCCCToYears が H2 の WorkingCapital/DSO/DIO/DPO/CCC を再計算する。
        calc.accountsReceivable    = fy.calculatedData.accountsReceivable
        calc.inventory             = fy.calculatedData.inventory
        calc.accountsPayable       = fy.calculatedData.accountsPayable

        // 損益フロー: FY − H1
        calc.grossProfit = sub(fy.calculatedData.grossProfit, h1.calculatedData.grossProfit)
        calc.grossProfitLabel  = fy.calculatedData.grossProfitLabel
        calc.grossProfitMethod = fy.calculatedData.grossProfitMethod
        calc.sellingGeneralAdministrativeExpenses = sub(
            fy.calculatedData.sellingGeneralAdministrativeExpenses,
            h1.calculatedData.sellingGeneralAdministrativeExpenses
        )
        calc.opLabel       = fy.calculatedData.opLabel
        calc.pretaxIncome  = sub(fy.calculatedData.pretaxIncome,  h1.calculatedData.pretaxIncome)
        calc.incomeTax     = sub(fy.calculatedData.incomeTax,     h1.calculatedData.incomeTax)
        calc.interestExpense = sub(fy.calculatedData.interestExpense, h1.calculatedData.interestExpense)

        // CF 自己株式取得・配当（フロー）: FY − H1
        calc.cfTreasuryStock = sub(fy.calculatedData.cfTreasuryStock, h1.calculatedData.cfTreasuryStock)
        calc.dividendSS      = sub(fy.calculatedData.dividendSS,      h1.calculatedData.dividendSS)
        calc.dividendPaidCF  = sub(fy.calculatedData.dividendPaidCF,  h1.calculatedData.dividendPaidCF)

        // 派生指標を再計算
        if let gp = calc.grossProfit, let s = raw.sales, s > 0 {
            calc.grossProfitMargin = (gp / s) * 100
        }
        if let op = raw.op, let s = raw.sales, s > 0 {
            calc.operatingMargin = (op / s) * 100
        }
        if let pretax = calc.pretaxIncome, pretax != 0, let tax = calc.incomeTax {
            calc.effectiveTaxRate = (tax / pretax) * 100
        }

        if let op = raw.op {
            let taxRate: Double
            if let etr = calc.effectiveTaxRate {
                taxRate = min(max(etr / 100, 0.2), 0.45)
            } else {
                taxRate = 0.3
            }
            calc.nopat = op * (1 - taxRate)
        }

        if let cash = raw.cashEq {
            let ibd = calc.interestBearingDebt ?? 0
            calc.netCash = cash - ibd
            if let na = calc.netAssets, na > 0 {
                calc.netDE = (ibd - cash) / na
            }
        }

        if let cfo = raw.cfo, let cfi = raw.cfi {
            calc.cfc = cfo + cfi
        }

        // ROE: H2 フロー / FY 期末純資産。Python の _apply_bs_snapshot と同じ設計。
        if let np = raw.np, let na = raw.netAssets, na > 0 {
            calc.roe = (np / na) * 100
        }

        if let nopat = calc.nopat, let ibd = calc.interestBearingDebt, let na = calc.netAssets {
            let ic = ibd + na
            if ic > 0 {
                calc.roic = (nopat / ic) * 100
                if let s = raw.sales, s > 0 {
                    calc.nopatMargin = (nopat / s) * 100
                    calc.investedCapitalTurnover = s / ic
                }
            }
        }

        calc.docID = fy.calculatedData.docID

        let (year, month) = extractYearMonth(fyEnd)
        let periodLabel: String = {
            if let y = year, let m = month {
                return "\(y)年\(String(format: "%02d", m))月期 (H2)"
            }
            return "H2"
        }()

        return YearEntry(fyEnd: fyEnd, financialPeriod: periodLabel, rawData: raw, calculatedData: calc)
    }

    // MARK: - Helpers

    private func halfLabel(_ fyEnd: String, _ suffix: String) -> String {
        let (year, _) = extractYearMonth(fyEnd)
        let yr = (year ?? 0) % 100
        return String(format: "%02d", yr) + suffix
    }

    private func sub(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return a - b
    }

    private func trimPeriods(_ periods: [HalfPeriod], to years: Int) -> [HalfPeriod] {
        halfYearTrimPeriods(periods, to: years)
    }
}

private struct HalfYearCache: Codable {
    var periods: [HalfPeriod]
}

// MARK: - Testable helpers

/// 完結 H1+H2 ペア N 件 + 当期 H1（FY 未公開）に trim する。
/// Python の _trim_half_year_periods と同じロジック。
/// periods は古い順（fyEnd 昇順）を前提とする。
func halfYearTrimPeriods(_ periods: [HalfPeriod], to years: Int) -> [HalfPeriod] {
    let h2Ends = Set(periods.filter { $0.half == "H2" }.compactMap { $0.fyEnd })
    let h1Ends = Set(periods.filter { $0.half == "H1" }.compactMap { $0.fyEnd })
    let currentH1Ends = h1Ends.subtracting(h2Ends)  // H1 あり H2 なし = 当期 H1

    let selected = Set(Array(h2Ends).sorted(by: >).prefix(years))
    var result = periods.filter { $0.fyEnd.map { selected.contains($0) } ?? false }

    // 当期 H1 を末尾に追加（最新 1 件）
    if let currentH1 = periods.last(where: {
        $0.half == "H1" && ($0.fyEnd.map { currentH1Ends.contains($0) } ?? false)
    }) {
        result.append(currentH1)
    }
    return result
}
