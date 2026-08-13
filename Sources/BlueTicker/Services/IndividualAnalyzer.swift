import Foundation

// MARK: - IndividualAnalyzer
// Python の blue_ticker/services/analyzer.py 相当
// 個別銘柄の EDINET 書類から財務指標を抽出してメトリクスを組み立てる。

private let _cacheVersion = blueTickerVersion
private let millionYen = 1_000_000.0
private let percent = 100.0

/// `IndividualAnalyzer.fetchAndBuild` の結果。「有価証券報告書が未提出」（対象外、新規上場等で
/// 初回本決算前）と「書類はあるが抽出できない」（失敗、要調査）を呼び出し元が区別できるようにする
/// （issue #86）。
enum IndividualAnalyzeOutcome {
    case result(MetricsResult)
    case notApplicable
    case failed
}

extension IndividualAnalyzeOutcome {
    /// 対象外・失敗の区別が不要な呼び出し元向けの Optional 変換。
    var resultOrNil: MetricsResult? {
        if case .result(let result) = self { return result }
        return nil
    }
}

struct IndividualAnalyzer {
    let edinetClient: EdinetAPIClient
    let cacheManager: CacheManager

    // MARK: - Public Entry Point

    /// 銘柄コードの財務指標を取得する。キャッシュがあればそれを返す。
    func analyze(
        code: String,
        analysisYears: Int = Api.analyzeDefaultYears,
        useCache: Bool = true
    ) async -> IndividualAnalyzeOutcome {
        let cacheKey = "individual_analysis_\(code)"

        if useCache {
            let cached = await cacheManager.getJSON(cacheKey)
            if individualCacheIsReusable(cached, cacheVersion: _cacheVersion, requestedYears: analysisYears),
               let result = decodeMetricsResult(cached!) {
                return .result(trimMetrics(result, to: analysisYears))
            }
        }

        let outcome = await fetchAndBuild(code: code, analysisYears: analysisYears)
        if case .result(let r) = outcome {
            if var dict = encodeMetricsResult(r) {
                dict["_cache_version"] = _cacheVersion
                dict["_requested_years"] = analysisYears
                await cacheManager.setJSON(cacheKey, value: dict)
            }
        }
        return outcome
    }

    // MARK: - Fetch and Build

    private func fetchAndBuild(code: String, analysisYears: Int) async -> IndividualAnalyzeOutcome {
        let docs = await EdinetDiscovery.buildDocumentIndexForCode(
            code: code,
            client: edinetClient,
            analysisYears: analysisYears
        )
        guard !docs.isEmpty else { return .notApplicable }

        // 最新 analysisYears 件に絞る（EdinetDiscovery は最大件数を返すが多い場合もある）
        let targetDocs = Array(docs.prefix(analysisYears))

        // 並列で XBRL ダウンロード + 抽出（メモリピーク抑制のため並列度を制限）
        // [String: Any] は Sendable 非準拠のため @unchecked Sendable ラッパーでクロージャ境界を渡す
        struct SendableDoc: @unchecked Sendable { let value: [String: Any] }
        var yearEntries: [YearEntry] = await withBoundedTaskGroup(
            items: targetDocs.map { SendableDoc(value: $0) },
            limit: Api.xbrlProcessConcurrency
        ) { d in
            await self.processDocument(d.value)
        }

        guard !yearEntries.isEmpty else { return .failed }

        // fyEnd 降順ソート（最新が先頭）
        yearEntries.sort { ($0.fyEnd ?? "") > ($1.fyEnd ?? "") }

        // ウォーターフォール分解（全年度揃ってから実行）
        applyOperatingProfitChangeToYears(&yearEntries)
        applyRoicWaterfallToYears(&yearEntries)
        applyRoeWaterfallToYears(&yearEntries)
        applyWorkingCapitalAndCCCToYears(&yearEntries)

        var result = MetricsResult()
        result.code = code
        result.latestFyEnd = yearEntries.first?.fyEnd
        result.analysisYears = yearEntries.count
        result.availableYears = yearEntries.count
        result.years = yearEntries
        result.dataValid = !yearEntries.isEmpty
        return .result(result)
    }

    // MARK: - Document Processing

    func processDocument(_ doc: [String: Any]) async -> YearEntry? {
        guard let docID = doc["docID"] as? String,
              let fyEnd = doc["edinet_fy_end"] as? String else { return nil }

        // XBRL ダウンロード（キャッシュ済みなら即返す）
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return nil }

        // XBRL 全数値要素を収集
        let allTagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        guard !allTagElements.isEmpty else { return nil }

        let accountingStandard = detectAccountingStandard(allTagElements)

        // Duration FieldSet（損益計算書・CF用）
        var durationFS = fieldSetFromDuration(allTagElements)
        // 非連結 Duration FieldSet（自己株式取得・配当金の非連結フォールバック用）
        let ncDurationFS = fieldSetFromNonConsolidatedDuration(allTagElements)
        // IFRS 親会社帰属持分 Duration FieldSet（SS配当・SS自己株の NCI除外用）
        let equityAttrFS = fieldSetFromIFRSEquityAttributable(allTagElements)
        // Instant FieldSet（貸借対照表・有利子負債用）
        var instantFS = fieldSetFromInstant(allTagElements)

        // US-GAAP: 未移行フィールド（GP/SGA/IBD/税等）用に HTML 仮想タグを注入。
        // 本表水準値は StatementFinancialsResolver（USGAAPStatementHtml）側。
        if accountingStandard == "US-GAAP" {
            for (tag, fv) in USGAAPHtml.parsePLFields(in: xbrlDir) { durationFS[tag] = fv }
            for (tag, fv) in USGAAPHtml.parseBSFields(in: xbrlDir) { instantFS[tag] = fv }
        }

        // 本表水準値は statement 正本のみ（タスク #5 / #5b-1）。旧 Extractor へのフィールド単位
        // フォールバックはしない。USGAAPHtml 注入は未移行フィールド（GP/SGA/IBD/税等）用に残す。
        let statementMain = StatementFinancialsResolver.resolve(xbrlDir: xbrlDir)

        // 未移行フィールド用の抽出器
        let cf = CashFlowExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard)
        let gp = GrossProfitExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard, xbrlDir: xbrlDir)
        let op = OperatingProfitExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard)
        let ibd = IBDExtractor.extract(fieldSet: instantFS, accountingStandard: accountingStandard, xbrlDir: xbrlDir)
        let emp = EmployeesExtractor.extract(fieldSet: instantFS, tagElements: allTagElements)
        let tax = TaxExpenseExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard)
        let ie = InterestExpenseExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard, xbrlDir: xbrlDir)
        let rd = RDExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard)
        let bb = ShareBuybackExtractor.extract(fieldSet: durationFS, ncFieldSet: ncDurationFS, equityAttributableFieldSet: equityAttrFS, accountingStandard: accountingStandard)
        let cfTs = CfTreasuryStockExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard)
        let divSS = DividendSSExtractor.extract(fieldSet: durationFS, ncFieldSet: ncDurationFS, equityAttributableFieldSet: equityAttrFS, accountingStandard: accountingStandard)

        // RawData 組み立て
        var raw = RawData()
        raw.curFYEn = fyEnd
        raw.curPerType = doc["period_type"] as? String ?? "FY"
        raw.discDate = doc["submitDateTime"] as? String
        // 売上高・営業利益・純利益・現金・純資産（百万円単位。正本は statement のみ）
        raw.sales = statementMain?.sales.map { $0 / millionYen }
        raw.op = statementMain?.operatingProfit.map { $0 / millionYen }
        raw.np = statementMain?.netProfit.map { $0 / millionYen }
        raw.netAssets = statementMain?.netAssets.map { $0 / millionYen }
        raw.cfo = cf.cfo.map { $0 / millionYen }
        raw.cfi = cf.cfi.map { $0 / millionYen }
        // 設備投資は notes overview タグ → CF タグ（タスク #6）
        raw.capex = StatementNotesResolver.financialsCanonicalCapex(
            xbrlDir: xbrlDir, accountingStandard: accountingStandard
        ).map { $0 / millionYen }
        raw.rd = rd.current.map { $0 / millionYen }
        raw.buyback = bb.current.map { $0 / millionYen }
        raw.salesLabel = statementMain?.salesLabel
        raw.cashEq = statementMain?.cashEquivalents.map { $0 / millionYen }
        // 基本EPS（円・連結当期）と発行済普通株式数（期末残高・株）は notes 正本からパススルー
        raw.eps = StatementNotesResolver.financialsCanonicalEps(xbrlDir: xbrlDir)
        raw.shOutFY = StatementNotesResolver.financialsCanonicalIssuedShares(xbrlDir: xbrlDir)

        // CalculatedData 組み立て
        var calc = CalculatedData()
        calc.docID = docID
        calc.grossProfit = gp.grossProfit.map { $0 / millionYen }
        calc.grossProfitLabel = gp.grossProfitLabel
        calc.grossProfitMethod = gp.method
        if let gp_ = calc.grossProfit, let s = raw.sales, s > 0 {
            calc.grossProfitMargin = (gp_ / s) * percent
        }
        calc.sellingGeneralAdministrativeExpenses = op.sga.map { $0 / millionYen }
        calc.opLabel = statementMain?.operatingProfitLabel ?? op.label

        // BS 項目（正本は statement のみ）
        calc.totalAssets = statementMain?.totalAssets.map { $0 / millionYen }
        calc.currentAssets = statementMain?.currentAssets.map { $0 / millionYen }
        calc.nonCurrentAssets = statementMain?.nonCurrentAssets.map { $0 / millionYen }
        calc.currentLiabilities = statementMain?.currentLiabilities.map { $0 / millionYen }
        calc.nonCurrentLiabilities = statementMain?.nonCurrentLiabilities.map { $0 / millionYen }
        calc.netAssets = statementMain?.netAssets.map { $0 / millionYen }
        calc.balanceSheetAccountingStandard = accountingStandard

        // 有利子負債
        calc.interestBearingDebt = ibd.total.map { $0 / millionYen }
        calc.ibdAccountingStandard = ibd.accountingStandard

        // 従業員数
        if let e = emp.current { calc.employees = Int(e) }

        // 税金・支払利息
        calc.pretaxIncome = tax.pretaxIncome.map { $0 / millionYen }
        calc.incomeTax = tax.incomeTax.map { $0 / millionYen }
        calc.effectiveTaxRate = tax.effectiveTaxRate.map { $0 * percent }
        calc.interestExpense = ie.current.map { $0 / millionYen }

        // 有形固定資産（正本は statement のみ）
        calc.ppeTotal = statementMain?.ppeTotal.map { $0 / millionYen }
        calc.ppeAccountingStandard = accountingStandard

        // CF自己株式・配当SS は未移行。運転資本・配当CF は statement のみ
        calc.cfTreasuryStock = cfTs.current.map { $0 / millionYen }
        calc.dividendSS = divSS.current.map { $0 / millionYen }
        calc.dividendPaidCF = statementMain?.dividendPaidCF.map { $0 / millionYen }
        calc.accountsReceivable = statementMain?.accountsReceivable.map { $0 / millionYen }
        calc.inventory = statementMain?.inventory.map { $0 / millionYen }
        calc.accountsPayable = statementMain?.accountsPayable.map { $0 / millionYen }

        // 営業利益率
        if let s = raw.sales, s > 0, let rawOP = raw.op {
            calc.operatingMargin = (rawOP / s) * percent
        }

        // NOPAT
        if let op_ = raw.op, let taxRate = tax.effectiveTaxRate {
            let clampedTax = min(max(taxRate, Financial.nopatMinNormalTaxRate), Financial.nopatMaxNormalTaxRate)
            calc.nopat = op_ * (1.0 - clampedTax)
        } else if let op_ = raw.op {
            calc.nopat = op_ * (1.0 - Financial.nopatFallbackTaxRate)
        }

        // ネットキャッシュ・ネットD/E
        if let cash = raw.cashEq {
            let ibdM = calc.interestBearingDebt ?? 0
            calc.netCash = cash - ibdM
            if let na = calc.netAssets, na > 0 {
                calc.netDE = (ibdM - cash) / na
            }
        }

        // FCF
        if let cfo = raw.cfo, let cfi = raw.cfi {
            calc.cfc = cfo + cfi
        }

        // ROE
        if let np = raw.np, let eq = raw.netAssets, eq > 0 {
            calc.roe = (np / eq) * percent
        }

        // ROIC (NOPAT / 投下資本)
        if let nopat = calc.nopat,
           let ibd = calc.interestBearingDebt,
           let na = calc.netAssets {
            let investedCapital = ibd + na
            if investedCapital > 0 {
                calc.roic = (nopat / investedCapital) * percent
                if let s = raw.sales, s > 0 {
                    calc.nopatMargin = (nopat / s) * percent
                    calc.investedCapitalTurnover = s / investedCapital
                }
            }
        }

        let period = formatFinancialPeriod(fyEnd: fyEnd, perType: raw.curPerType ?? "FY")

        return YearEntry(
            fyEnd: fyEnd,
            financialPeriod: period,
            rawData: raw,
            calculatedData: calc
        )
    }

    // MARK: - Helpers

    private func formatFinancialPeriod(fyEnd: String, perType: String) -> String {
        let (year, month) = extractYearMonth(fyEnd)
        var period = ""
        if let y = year, let m = month {
            period = "\(y)年\(String(format: "%02d", m))月期"
        }
        if perType == "2Q" { period += " (2Q)" }
        return period
    }

    private func trimMetrics(_ result: MetricsResult, to years: Int) -> MetricsResult {
        guard let ys = result.years, ys.count > years else { return result }
        var r = result
        r.years = Array(ys.prefix(years))
        r.analysisYears = years
        r.availableYears = years
        return r
    }

    private func decodeMetricsResult(_ dict: [String: Any]) -> MetricsResult? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let result = try? JSONDecoder().decode(MetricsResult.self, from: data) else { return nil }
        return result
    }

    private func encodeMetricsResult(_ result: MetricsResult) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(result),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict
    }
}

// MARK: - Testable helpers

/// individual_analysis キャッシュが再利用可能か判定する。
///
/// キャッシュキー（`individual_analysis_<code>`）は年数を含まないため、
/// 要求年数より少ない年数で構築されたキャッシュを再利用すると
/// `trimMetrics`（縮小のみ）では要求年数まで拡張できず結果が不足する。
/// バージョン一致かつ構築時要求年数 `_requested_years` が要求年数以上のときのみ true。
func individualCacheIsReusable(_ cached: [String: Any]?, cacheVersion: String, requestedYears: Int) -> Bool {
    guard let c = cached,
          (c["_cache_version"] as? String) == cacheVersion,
          (c["_requested_years"] as? Int ?? 0) >= requestedYears else { return false }
    return true
}
