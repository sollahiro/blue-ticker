// financials 組立向けの本表水準値パススルー（タスク #5、`docs/financials-summary-separation.md`）。
// 正本は statement（BS/PL/CF 行）。ingest 順に依存せず、同一 XBRL パスで Statement を直接解決する（#10b）。

import Foundation

/// `company_financials` 組立が読む本表水準値（円単位）。派生指標は含まない。
struct StatementFinancialsValues {
    /// 本表金額の通貨（ISO 4217、`AmountUnit.currency(unitRef:)`）。外貨建て開示（6269 の USD）を区別する。
    var currency: String?
    var sales: Double?
    var salesLabel: String?
    var operatingProfit: Double?
    var operatingProfitLabel: String?
    var netProfit: Double?
    var totalAssets: Double?
    var currentAssets: Double?
    var nonCurrentAssets: Double?
    var currentLiabilities: Double?
    var nonCurrentLiabilities: Double?
    var netAssets: Double?
    /// 親会社の所有者に帰属する持分（期末）。ROE の分母。非支配持分・新株予約権を含まない。
    var parentEquity: Double? = nil
    /// 前期末（当期首）の親会社持分。ROE の分母を期首・期末平均にするための期首側。
    var priorParentEquity: Double? = nil
    var ppeTotal: Double?
    var accountsReceivable: Double?
    var inventory: Double?
    var accountsPayable: Double?
    var cashEquivalents: Double?
    var dividendPaidCF: Double?
    /// #5c: IndividualAnalyzer 切替済。statement 行だけで取れる値。
    var grossProfit: Double?
    var grossProfitLabel: String?
    var sga: Double?
    /// 販管費の表示名。null は通常の販売費及び一般管理費。銀行（業務純益経路）は「営業経費」。
    var sgaLabel: String? = nil
    /// Jev が販管費行を選んだ（または fail-closed した）ときの非公開監査。`/financials` には出さない。
    var sgaJevAudit: SegmentNoteJevAuditPayload? = nil
    var cfo: Double?
    var cfi: Double?
    var pretaxIncome: Double?
    var incomeTax: Double?
    var dividendSS: Double?
    /// #8: IndividualAnalyzer 切替済。statement 行だけで取れる値。IFRS 支払利息の notes は組立層。
    var interestExpense: Double?
    var cfTreasuryStock: Double?
    var buyback: Double?
    /// geography カバー判定に渡すラベル。Summary 組立とは独立。
    /// 本表に売上高（NetSales*）と営業収益（OperatingRevenue*）が並ぶときは営業収益
    /// （既存の `isNonSalesRevenueLabel` → 表の総合計アンカー）。
    /// PL トップラインの金額（`geographyCoverageSales`）が取れたときはその金額で照らすので付けない。
    var geographyCoverageSalesLabel: String? = nil
    /// geography カバー判定の分母に使う連結 PL のトップライン（円）。Summary `sales` より大きいときだけ。
    /// 売上高の上に合計行がある（ソニー 6758: 売上高＋金融ビジネス収入＝売上高及び金融ビジネス収入合計）、
    /// 合計行の無い 売上高＋営業収入（9950）、Summary が個別の営業収益を拾った（2433）など。
    var geographyCoverageSales: Double? = nil
}

enum StatementFinancialsResolver {

    /// `company_financials` 組立が読む本表水準値。正本は statement（`StatementAnalyzer.resolveFromXBRL`）。
    /// US-GAAP は HTML Statement 行のラベルから仮想タグ FieldSet を組み立て、既存 Extractor へ渡す。
    /// J-GAAP / IFRS は Statement が採用したタグだけを許可した FieldSet で Extractor を回す
    /// （SummaryOfBusinessResults 等の本表外タグは混ぜない。コンテキストは元 fact を保持）。
    /// 例外: 本表が業種別営業収益に分割され合計行が無い会社は、
    /// `statementSalesSummaryTotalTags` を売上 FieldSet へ載せる。それも無ければ
    /// `operatingRevenueSplitGroups` の内訳を合算する（9127 S100Y90D）。
    /// `edinetIndustry` は EDINET 提出者業種（銀行判定 `Xbrl.isBankFiling` に渡す。不明なら nil）。
    static func resolve(
        xbrlDir: URL, edinetIndustry: String? = nil,
        sgaTagPolicy: SgaTagPolicy = .all
    ) -> StatementFinancialsValues? {
        resolveBundle(
            xbrlDir: xbrlDir, edinetIndustry: edinetIndustry, sgaTagPolicy: sgaTagPolicy
        )?.values
    }

    /// タグ経路が nil のときだけ Jev に既存 PL 行を選ばせる。銀行・保険・US-GAAP は呼ばない。
    static func resolve(
        xbrlDir: URL, edinetIndustry: String? = nil,
        sgaTagPolicy: SgaTagPolicy = .all,
        sgaLineDecider: (any SgaLineDeciding)?
    ) async -> StatementFinancialsValues? {
        guard var bundle = resolveBundle(
            xbrlDir: xbrlDir, edinetIndustry: edinetIndustry, sgaTagPolicy: sgaTagPolicy)
        else { return nil }
        await SgaLineJevPicker.applyIfNeeded(
            to: &bundle.values,
            incomeStatement: bundle.incomeStatement,
            skip: bundle.skipSgaJev,
            decider: sgaLineDecider,
            docID: docIDFromXbrlDir(xbrlDir))
        return bundle.values
    }

    private struct ResolveBundle {
        var values: StatementFinancialsValues
        var incomeStatement: [StatementLineItem]
        var skipSgaJev: Bool
    }

    private static func docIDFromXbrlDir(_ xbrlDir: URL) -> String {
        xbrlDir.lastPathComponent.replacingOccurrences(of: "_xbrl", with: "")
    }

    private static func resolveBundle(
        xbrlDir: URL, edinetIndustry: String?, sgaTagPolicy: SgaTagPolicy
    ) -> ResolveBundle? {
        let tagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        guard !tagElements.isEmpty else { return nil }
        let accountingStandard = detectAccountingStandard(tagElements)

        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir,
            docID: nil,
            statementTypes: [.balanceSheet, .incomeStatement, .cashFlow, .changesInEquity]
        ) else { return nil }

        var bundle: ResolveBundle
        if accountingStandard == "US-GAAP" {
            bundle = ResolveBundle(
                values: resolveFromUSGAAPStatement(year, tagElements: tagElements),
                incomeStatement: year.incomeStatement,
                skipSgaJev: true)
        } else {
            bundle = resolveFromStructuredStatement(
                year, tagElements: tagElements, accountingStandard: accountingStandard,
                edinetIndustry: edinetIndustry, sgaTagPolicy: sgaTagPolicy)
        }
        bundle.values.currency = year.currency
        return bundle
    }

    // MARK: - J-GAAP / IFRS（構造化 XBRL タグ）

    private static func resolveFromStructuredStatement(
        _ year: StatementYear, tagElements: XbrlTagElements, accountingStandard: String,
        edinetIndustry: String?, sgaTagPolicy: SgaTagPolicy
    ) -> ResolveBundle {
        // Statement 行のタグを許可リストにし、元 fact のコンテキストを保った FieldSet を組む。
        // CF の期首/期末で同タグが並ぶ会社でも Instant CurrentYear を正しく拾える
        // （行値だけを辞書化すると先勝ちで期首や計算派生値に引きずられる）。
        // SS は dividend_ss / buyback と、PL に親会社帰属純利益が無いときの net_profit 用。
        // 済み本表 Extractor（sales 等）の候補には混ぜない。
        // Statement は role カバレッジで個別 J-GAAP PL を選ぶことがある
        // （ベイカレント S100TI4B: `Revenue` / `OperatingIncome`）。
        // IFRS 本表 P&L（`RevenueIFRS` 等）はマスクに残し、Summary の Duration
        // FieldSet だけで NonConsolidatedMember をスロット単位フォールバックする
        // （同一スロットに連結候補がある期は埋めない。notes / breakdown には使わない）。
        let mainTags = Set(
            (year.balanceSheet + year.incomeStatement + year.cashFlow).map(\.tag)
        ).union(Xbrl.summaryIfrsPnLTags)
        let equityTags = Set(year.changesInEquity.map(\.tag))
        let maskedMain = tagElements.filter { mainTags.contains($0.key) }
        let maskedEquity = tagElements.filter { mainTags.union(equityTags).contains($0.key) }
        var durationFS = fieldSetFromDuration(
            maskedMain, fillMissingIfrsPnLFromNonConsolidated: true)
        var instantFS = fieldSetFromInstant(maskedMain)
        var equityDurationFS = fieldSetFromDuration(maskedEquity)
        // Statement 本表の当期行を FieldSet に載せる。CF 合計は既に本表行を直接読む。
        // 非連結のみ企業（ニッカトー 5367 / S100Y9NY）は PL/BS が
        // `CurrentYearDuration_NonConsolidatedMember` にだけあり、連結 FieldSet が空のまま
        // sales / OP / NP / BS が全年 null、CF だけ埋まる。IBD の
        // `overlayStatementCurrentValues` と同じ「本表当期を載せる」投影だが、
        // PL/BS では statement 組立の `nilAsZero: true` 合成 0（xsi:nil）は載せない。
        overlayStatementLineCurrents(&durationFS, lines: year.incomeStatement)
        overlayStatementLineCurrents(&instantFS, lines: year.balanceSheet)
        overlayStatementLineCurrents(&equityDurationFS, lines: year.changesInEquity)

        // 売上だけ、本表に合計行が無いときの連結営業収益合計（主要な経営指標等）を載せる。
        // 合計タグが無ければ resolveNetSales が業種別内訳を合算する。
        // OP/GP など他 Extractor の durationFS には混ぜない。
        var salesFS = durationFS
        overlayStatementSalesSummaryTotals(&salesFS, tagElements: tagElements)

        let is_ = IncomeStatementExtractor.extract(
            fieldSet: salesFS, accountingStandard: accountingStandard)
        let op = OperatingProfitExtractor.extract(
            fieldSet: durationFS, accountingStandard: accountingStandard,
            sgaTagPolicy: sgaTagPolicy)
        let bs = BalanceSheetExtractor.extract(
            fieldSet: instantFS, accountingStandard: accountingStandard)
        let ppe = TangibleFixedAssetsExtractor.extract(
            fieldSet: instantFS, accountingStandard: accountingStandard)
        let ar = AccountsReceivableExtractor.extract(
            fieldSet: instantFS, accountingStandard: accountingStandard)
        let inv = InventoryExtractor.extract(
            fieldSet: instantFS, accountingStandard: accountingStandard)
        let ap = AccountsPayableExtractor.extract(
            fieldSet: instantFS, accountingStandard: accountingStandard)
        let divPaid = DividendPaidExtractor.extract(
            fieldSet: durationFS, accountingStandard: accountingStandard)
        let cash = resolveItem(instantFS, tags: Xbrl.cashEquivalentsTags)
        let remaining = remainingFromStatementExtractors(
            durationFS: durationFS,
            equityDurationFS: equityDurationFS,
            maskedEquity: maskedEquity,
            accountingStandard: accountingStandard, operating: op,
            cashFlow: year.cashFlow)

        // IFRS 金融会社: 純収益 / 事業利益が PL 行にあれば sales / OP のフォールバックにする。
        let nr = NetRevenueExtractor.extract(fieldSet: durationFS)

        var sales = is_.sales
        var salesLabel = is_.salesLabel
        var operatingProfit = op.operatingProfit ?? is_.operatingProfit
        var operatingProfitLabel = op.operatingProfit != nil ? op.label : nil
        if sales == nil, let netRev = nr.netRevenue {
            sales = netRev
            salesLabel = "純収益"
        }
        // 保険の営業利益は全年 null。純収益／事業利益フォールバックで埋めない。
        if !Xbrl.isInsuranceFiling(durationFS), operatingProfit == nil, let bp = nr.businessProfit {
            operatingProfit = bp
            operatingProfitLabel = "事業利益"
        }
        var sga = remaining.sga
        var sgaLabel = remaining.sgaLabel
        let isInsurance = Xbrl.isInsuranceFiling(durationFS)
        let isBank = Xbrl.isBankFiling(instantFS, edinetIndustry: edinetIndustry)
        // 銀行（預金マーカーまたは EDINET 提出者業種＝銀行業。IBD と同じ判定）で連結の営業利益値が無い会社（経常利益に落ちる、または
        // 単体だけの OperatingIncome タグで値が空になる みずほ 8411 S100YF8Y）は
        // 業務純益 = 業務粗利益 − 営業経費 を営業利益とし、販管費は営業経費。
        // 営業利益行を持つ銀行子会社持株（HSホールディングス 8699）は対象外。
        if op.method == "ordinary_income" || op.operatingProfit == nil,
           !isInsurance, isBank {
            let bank = bankNetBusinessProfit(
                grossProfit: remaining.grossProfit, grossProfitLabel: remaining.grossProfitLabel,
                durationFS: durationFS)
            operatingProfit = bank.netBusinessProfit
            operatingProfitLabel = bank.netBusinessProfit == nil ? nil : bankNetBusinessProfitLabel
            sga = bank.operatingExpenses
            sgaLabel = bank.operatingExpenses == nil ? nil : bankOperatingExpensesLabel
        }

        var values = StatementFinancialsValues(
            sales: sales,
            salesLabel: salesLabel,
            operatingProfit: operatingProfit,
            operatingProfitLabel: operatingProfitLabel,
            netProfit: resolveParentAttributableNetProfit(
                incomeStatement: year.incomeStatement,
                changesInEquity: year.changesInEquity,
                fallback: is_.netProfit),
            totalAssets: bs.totalAssets,
            currentAssets: bs.currentAssets,
            nonCurrentAssets: bs.nonCurrentAssets,
            currentLiabilities: bs.currentLiabilities,
            nonCurrentLiabilities: bs.nonCurrentLiabilities,
            netAssets: bs.netAssets,
            parentEquity: resolveParentEquity(instantFS: instantFS, netAssets: bs.netAssets),
            priorParentEquity: resolvePriorParentEquity(
                instantFS: instantFS, priorNetAssets: bs.priorNetAssets),
            ppeTotal: ppe.total,
            accountsReceivable: ar.current,
            inventory: inv.current,
            accountsPayable: ap.current,
            cashEquivalents: cash.current,
            dividendPaidCF: divPaid.current,
            grossProfit: remaining.grossProfit,
            grossProfitLabel: remaining.grossProfitLabel,
            sga: sga,
            sgaLabel: sgaLabel,
            cfo: remaining.cfo,
            cfi: remaining.cfi,
            pretaxIncome: remaining.pretaxIncome,
            incomeTax: remaining.incomeTax,
            dividendSS: remaining.dividendSS,
            interestExpense: remaining.interestExpense,
            cfTreasuryStock: remaining.cfTreasuryStock,
            buyback: remaining.buyback,
            geographyCoverageSalesLabel: geographyCoverageSalesLabel(
                summaryLabel: salesLabel, fieldSet: salesFS)
        )
        if !isBank, !isInsurance,
           let topLine = incomeStatementTopLineRevenue(year.incomeStatement, sales: sales)
        {
            values.geographyCoverageSales = topLine
            values.geographyCoverageSalesLabel = salesLabel
        }
        return ResolveBundle(
            values: values,
            incomeStatement: year.incomeStatement,
            skipSgaJev: isBank || isInsurance)
    }

    /// 期末の親会社持分。本表に親会社持分の行（IFRS / US-GAAP）があればそれ、無ければ
    /// 純資産合計 − 非支配株主持分 − 新株予約権（日本基準。行が無い科目は 0）。
    static func resolveParentEquity(instantFS: FieldSet, netAssets: Double?) -> Double? {
        parentEquity(instantFS: instantFS, netAssets: netAssets, period: \.current)
    }

    /// 前期末（当期首）の親会社持分。期末と同じ規則で、同じ書類の前期末列から取る。
    static func resolvePriorParentEquity(instantFS: FieldSet, priorNetAssets: Double?) -> Double? {
        parentEquity(instantFS: instantFS, netAssets: priorNetAssets, period: \.prior)
    }

    private static func parentEquity(
        instantFS: FieldSet, netAssets: Double?, period: KeyPath<ResolvedItem, Double?>
    ) -> Double? {
        if let direct = resolveItem(instantFS, tags: Xbrl.parentEquityTags)[keyPath: period] { return direct }
        guard let netAssets else { return nil }
        let nonControlling = resolveItem(instantFS, tags: Xbrl.nonControllingInterestsTags)[keyPath: period] ?? 0
        let subscriptionRights =
            resolveItem(instantFS, tags: Xbrl.subscriptionRightsToSharesTags)[keyPath: period] ?? 0
        return netAssets - nonControlling - subscriptionRights
    }

    // MARK: - US-GAAP（HTML Statement ラベル → 仮想タグ）

    private static func resolveFromUSGAAPStatement(
        _ year: StatementYear, tagElements: XbrlTagElements = [:]
    ) -> StatementFinancialsValues {
        // CF 合計の最終フォールバック用（本表ラベルで取れないときだけ使う）。
        let summaryTags = fieldSetFromDuration(tagElements.filter {
            $0.key == usgaapSummaryOperatingCashFlowTag || $0.key == usgaapSummaryInvestingCashFlowTag
        })
        var durationFS: FieldSet = [:]
        var instantFS: FieldSet = [:]

        // BS 水準値: Statement 行のラベルから直接拾う。
        // 注意: `USGAAPHtml.bsLabelMap` の「信用損失引当金→AR」等は HTML 入れ子セルの親合計を
        // 取る前提で、`USGAAPStatementHtml` の行値（科目本体）とは一致しない。AR/AP は専用規則。
        for item in year.balanceSheet {
            guard let label = item.label else { continue }
            let stripped = USGAAPHtml.stripSectionPrefix(label)
            if stripped == "資産合計" {
                assignIfAbsent(&instantFS, "TotalAssetsUSGAAP", item.value)
            }
            if stripped == "流動資産合計" || stripped == "流動資産" {
                assignIfAbsent(&instantFS, "USGAAP_HTML_CurrentAssets", item.value)
            }
            if stripped == "流動負債合計" || stripped == "流動負債" {
                assignIfAbsent(&instantFS, "USGAAP_HTML_CurrentLiabilities", item.value)
            }
            if stripped == "固定負債合計" || stripped == "固定負債" || stripped == "非流動負債合計" {
                assignIfAbsent(&instantFS, "USGAAP_HTML_NonCurrentLiabilities", item.value)
            }
            if stripped == "純資産合計" || stripped == "純資産" || stripped == "資本合計" {
                assignIfAbsent(&instantFS, "USGAAP_HTML_NetAssets", item.value)
            }
            if stripped == "負債合計" {
                assignIfAbsent(&instantFS, "USGAAP_HTML_TotalLiabilities", item.value)
            }
            if stripped == "有形固定資産合計" || stripped == "有形固定資産" {
                assignIfAbsent(&instantFS, "USGAAP_HTML_PPENet", item.value)
            }
            if stripped == "棚卸資産" || stripped.hasSuffix("棚卸資産") {
                assignIfAbsent(&instantFS, "USGAAP_HTML_Inventory", item.value)
            }
            if labelContainsCashEquivalents(label) {
                assignIfAbsent(&instantFS, "CashAndCashEquivalentsUSGAAP", item.value)
            }
        }
        if let ar = resolveUSGAAPAccountsReceivable(year.balanceSheet) {
            instantFS["USGAAP_HTML_AccountsReceivable"] = FieldValue(current: ar, prior: nil)
        }
        if let ap = resolveUSGAAPAccountsPayable(year.balanceSheet) {
            instantFS["USGAAP_HTML_AccountsPayable"] = FieldValue(current: ap, prior: nil)
        }

        // PL / CF
        for item in year.incomeStatement + year.cashFlow {
            guard let label = item.label else { continue }
            if let vtag = bestMatchingVirtualTag(label: label, map: USGAAPHtml.plLabelMap) {
                assignIfAbsent(&durationFS, vtag, item.value)
            }
        }
        var salesLabelOverride: String?
        if let sales = resolveUSGAAPSales(year.incomeStatement) {
            durationFS["NetSales"] = FieldValue(current: sales.value, prior: nil)
            salesLabelOverride = sales.labelOverride
        }
        if let np = resolveUSGAAPNetProfit(year.incomeStatement)
            ?? resolveUSGAAPNetProfit(year.changesInEquity)
        {
            durationFS["NetIncomeLossAttributableToOwnersOfParentUSGAAP"] = FieldValue(
                current: np, prior: nil)
        }

        let is_ = IncomeStatementExtractor.extract(
            fieldSet: durationFS, accountingStandard: "US-GAAP")
        let op = OperatingProfitExtractor.extract(
            fieldSet: durationFS, accountingStandard: "US-GAAP")
        let bs = BalanceSheetExtractor.extract(
            fieldSet: instantFS, accountingStandard: "US-GAAP")
        let ppe = TangibleFixedAssetsExtractor.extract(
            fieldSet: instantFS, accountingStandard: "US-GAAP")
        let ar = AccountsReceivableExtractor.extract(
            fieldSet: instantFS, accountingStandard: "US-GAAP")
        let inv = InventoryExtractor.extract(
            fieldSet: instantFS, accountingStandard: "US-GAAP")
        let ap = AccountsPayableExtractor.extract(
            fieldSet: instantFS, accountingStandard: "US-GAAP")
        let divPaid = DividendPaidExtractor.extract(
            fieldSet: durationFS, accountingStandard: "US-GAAP")
        let cash = resolveItem(instantFS, tags: Xbrl.cashEquivalentsTags)

        let tax = TaxExpenseExtractor.extract(fieldSet: durationFS, accountingStandard: "US-GAAP")
        let gpItem = year.incomeStatement.first { ($0.label ?? "").contains("売上総利益") }

        // US-GAAP 非流動資産: 直接行が無いとき Total − Current。
        var nonCurrent = bs.nonCurrentAssets
        if nonCurrent == nil, let ta = bs.totalAssets, let ca = bs.currentAssets {
            nonCurrent = ta - ca
        }

        let resolvedSalesLabel = salesLabelOverride ?? is_.salesLabel ?? "売上高"
        let summaryParentEquity = resolveItem(
            fieldSetFromInstant(tagElements.filter { Xbrl.parentEquitySummaryTags.contains($0.key) }),
            tags: Xbrl.parentEquitySummaryTags)
        return StatementFinancialsValues(
            sales: is_.sales,
            salesLabel: resolvedSalesLabel,
            operatingProfit: op.operatingProfit ?? is_.operatingProfit,
            operatingProfitLabel: op.operatingProfit != nil ? op.label : nil,
            netProfit: resolveParentAttributableNetProfit(
                incomeStatement: year.incomeStatement,
                changesInEquity: year.changesInEquity,
                fallback: is_.netProfit),
            totalAssets: bs.totalAssets,
            currentAssets: bs.currentAssets,
            nonCurrentAssets: nonCurrent,
            currentLiabilities: bs.currentLiabilities,
            nonCurrentLiabilities: bs.nonCurrentLiabilities,
            netAssets: bs.netAssets,
            parentEquity: summaryParentEquity.current,
            priorParentEquity: summaryParentEquity.prior,
            ppeTotal: ppe.total,
            accountsReceivable: ar.current,
            inventory: inv.current,
            accountsPayable: ap.current,
            cashEquivalents: cash.current,
            dividendPaidCF: divPaid.current,
            grossProfit: gpItem?.value,
            grossProfitLabel: gpItem?.label.map { USGAAPHtml.stripSectionPrefix($0) },
            sga: op.sga,
            cfo: statementCashFlowTotal(year.cashFlow, tags: statementOperatingCashFlowTags)
                ?? firstByLabel(
                    year.cashFlow, contains: "営業活動によるキャッシュ・フロー",
                    excluding: ["期首", "期末", "明細"])
                ?? usgaapCashFlowActivityTotal(year.cashFlow, activity: .operating)
                ?? usgaapSummaryCashFlow(
                    summaryTags, tag: usgaapSummaryOperatingCashFlowTag),
            cfi: statementCashFlowTotal(year.cashFlow, tags: statementInvestingCashFlowTags)
                ?? firstByLabel(
                    year.cashFlow, contains: "投資活動によるキャッシュ・フロー",
                    excluding: ["期首", "期末", "明細"])
                ?? usgaapCashFlowActivityTotal(year.cashFlow, activity: .investing)
                ?? usgaapSummaryCashFlow(
                    summaryTags, tag: usgaapSummaryInvestingCashFlowTag),
            pretaxIncome: tax.pretaxIncome
                ?? firstByLabel(year.incomeStatement, contains: "税引前")
                ?? firstByLabel(year.incomeStatement, contains: "税金等調整前"),
            incomeTax: resolveUSGAAPIncomeTax(year.incomeStatement)
                ?? tax.incomeTax,
            dividendSS: resolveUSGAAPDividendSS(year.changesInEquity),
            interestExpense: resolveUSGAAPInterestExpense(year.incomeStatement),
            cfTreasuryStock: resolveUSGAAPTreasuryPurchase(year.cashFlow),
            buyback: resolveUSGAAPTreasuryPurchase(year.changesInEquity)
                ?? resolveUSGAAPTreasuryPurchase(year.cashFlow),
            geographyCoverageSalesLabel: geographyCoverageSalesLabel(
                summaryLabel: resolvedSalesLabel, fieldSet: durationFS)
        )
    }

    // MARK: - 銀行 業務純益

    static let bankNetBusinessProfitLabel = "業務純益"
    static let bankOperatingExpensesLabel = "営業経費"

    /// 銀行の業務純益 = 業務粗利益（`GrossProfitExtractor` の連結業務粗利益）− 営業経費。
    /// 持分法による投資損益は足さない（2026-10-12 決定）。
    /// 業務粗利益か営業経費が無ければ業務純益は nil（経常利益や差額で埋めない）。
    static func bankNetBusinessProfit(
        grossProfit: Double?, grossProfitLabel: String?, durationFS: FieldSet
    ) -> (netBusinessProfit: Double?, operatingExpenses: Double?) {
        let operatingExpenses = resolveItem(durationFS, tags: Xbrl.bankOperatingExpensesTags).current
        guard let grossProfit, grossProfitLabel == "連結業務粗利益", let operatingExpenses else {
            return (nil, operatingExpenses)
        }
        return (grossProfit - operatingExpenses, operatingExpenses)
    }

    /// statement 行に載る #5c / #8 フィールド。HTML/TextBlock フォールバックは付けない。
    private static func remainingFromStatementExtractors(
        durationFS: FieldSet, equityDurationFS: FieldSet, maskedEquity: XbrlTagElements,
        accountingStandard: String, operating: OperatingProfitResult,
        cashFlow: [StatementLineItem]
    ) -> (
        grossProfit: Double?, grossProfitLabel: String?, sga: Double?, sgaLabel: String?,
        cfo: Double?, cfi: Double?,
        pretaxIncome: Double?, incomeTax: Double?, dividendSS: Double?,
        interestExpense: Double?, cfTreasuryStock: Double?, buyback: Double?
    ) {
        let gp = GrossProfitExtractor.extract(
            fieldSet: durationFS, accountingStandard: accountingStandard, xbrlDir: nil)
        // 正本は CF 本表の合計行。SummaryOfBusinessResults は使わない。
        // IFRS 3社は `NetCashProvidedByUsedIn*ActivitiesIFRS` が本表にあり、旧
        // CashFlowExtractor は Summary タグで拾っていた。ここは本表タグだけを見る。
        let cfo = statementCashFlowTotal(cashFlow, tags: statementOperatingCashFlowTags)
            ?? firstByLabel(
                cashFlow, contains: "営業活動によるキャッシュ・フロー",
                excluding: ["期首", "期末", "明細"])
        let cfi = statementCashFlowTotal(cashFlow, tags: statementInvestingCashFlowTags)
            ?? firstByLabel(
                cashFlow, contains: "投資活動によるキャッシュ・フロー",
                excluding: ["期首", "期末", "明細"])
        let tax = TaxExpenseExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard)
        // PL の金融費用 (`FinanceCostsIFRS`) は支払利息ではない。現行 Extractor の最終
        // フォールバック用で、statement 正本では使わない（味の素・クボタ・スズキは注記タグ）。
        var ieFS = durationFS
        ieFS["FinanceCostsIFRS"] = nil
        let ie = InterestExpenseExtractor.extract(
            fieldSet: ieFS, accountingStandard: accountingStandard, xbrlDir: nil)
        let cfTs = CfTreasuryStockExtractor.extract(
            fieldSet: durationFS, accountingStandard: accountingStandard)
        let ncDurationFS = fieldSetFromNonConsolidatedDuration(maskedEquity)
        let equityAttrFS = fieldSetFromIFRSEquityAttributable(maskedEquity)
        let divSS = DividendSSExtractor.extract(
            fieldSet: equityDurationFS, ncFieldSet: ncDurationFS,
            equityAttributableFieldSet: equityAttrFS,
            accountingStandard: accountingStandard)
        let buyback = ShareBuybackExtractor.extract(
            fieldSet: equityDurationFS, ncFieldSet: ncDurationFS,
            equityAttributableFieldSet: equityAttrFS,
            accountingStandard: accountingStandard)
        return (
            grossProfit: gp.grossProfit,
            grossProfitLabel: gp.grossProfitLabel,
            sga: operating.sga,
            sgaLabel: operating.sgaLabel,
            cfo: cfo,
            cfi: cfi,
            pretaxIncome: tax.pretaxIncome,
            incomeTax: tax.incomeTax,
            dividendSS: divSS.current,
            interestExpense: ie.current,
            cfTreasuryStock: cfTs.current,
            buyback: buyback.current
        )
    }

    /// CF 本表合計。旧 Extractor の `Xbrl.cf*Tags` には載せない（Summary 欠測時の旧出力を変えない）。
    private static let statementOperatingCashFlowTags: [String] = [
        "CashFlowsFromUsedInOperationsIFRS",
        "CashFlowsFromUsedInOperatingActivitiesIFRS",
        "NetCashProvidedByUsedInOperatingActivities",
        "NetCashProvidedByUsedInOperatingActivitiesIFRS",
    ]
    private static let statementInvestingCashFlowTags: [String] = [
        "CashFlowsUsedInInvestingActivitiesIFRS",
        "CashFlowsFromUsedInInvestingActivitiesIFRS",
        "NetCashProvidedByUsedInInvestingActivities",
        "NetCashProvidedByUsedInInvestmentActivities",
        "NetCashProvidedByUsedInInvestingActivitiesIFRS",
        "NetCashProvidedByUsedInInvestmentActivitiesIFRS",
    ]

    /// CF 本表の合計。`SummaryOfBusinessResults` は本表ではないので候補から外す。
    private static func statementCashFlowTotal(
        _ items: [StatementLineItem], tags: [String]
    ) -> Double? {
        for tag in tags where !tag.contains("SummaryOfBusinessResults") {
            if let item = items.first(where: { $0.tag == tag }) {
                return item.value
            }
        }
        return nil
    }

    /// ラベル部分一致の先頭行。値の無い見出し行（「－」= 0 で出る行）で打ち切らず、
    /// 非ゼロ値の一致があればそれを、無ければ最初の一致（真の 0）を返す。
    private static func firstByLabel(
        _ items: [StatementLineItem], contains: String, excluding: [String] = []
    ) -> Double? {
        var firstZero: Double?
        for item in items {
            let label = item.label ?? ""
            guard label.contains(contains) else { continue }
            if excluding.contains(where: { label.contains($0) }) { continue }
            if item.value != 0 { return item.value }
            if firstZero == nil { firstZero = item.value }
        }
        return firstZero
    }

    enum USGAAPCashFlowActivity {
        case operating, investing

        var prefix: String { self == .operating ? "営業活動" : "投資活動" }
        var section: StatementLineSection { self == .operating ? .operating : .investing }
    }

    static let usgaapSummaryOperatingCashFlowTag =
        "CashFlowsFromUsedInOperatingActivitiesUSGAAPSummaryOfBusinessResults"
    static let usgaapSummaryInvestingCashFlowTag =
        "CashFlowsFromUsedInInvestingActivitiesUSGAAPSummaryOfBusinessResults"

    /// US-GAAP CF 本表の活動区分合計行の後半（空白除去後、「営業活動」「投資活動」の直後）。
    /// 手元の US-GAAP 書類 40 件で実際に出たものだけを持つ（推測の揺れは足さない）:
    /// キヤノン／オムロン／富士フイルム「によるキャッシュ・フロー」、村田「による キャッシュ・フロー合計」、
    /// 小松「による現金及び現金同等物の増加（純額）」「…の減少（純額）」、野村「に使用された現金（純額）」、
    /// オリックス「から得た現金（純額）」「に使用した現金（純額）」、
    /// ソニー（米国基準期）「から得た現金・預金及び現金同等物（純額）」「に使用した現金・預金及び現金同等物（純額）」、
    /// TDK（同）「による純現金収入」。
    static let usgaapCashFlowTotalSuffixes: [String] = [
        "によるキャッシュ・フロー合計",
        "によるキャッシュ・フロー",
        "による現金及び現金同等物の増加（純額）",
        "による現金及び現金同等物の減少（純額）",
        "から得た現金（純額）",
        "に使用した現金（純額）",
        "に使用された現金（純額）",
        "から得た現金・預金及び現金同等物（純額）",
        "に使用した現金・預金及び現金同等物（純額）",
        "による純現金収入",
    ]

    /// 活動名を括弧内で繰り返す合計行（野村 2021〜2025 年 3 月期
    /// 「営業活動から得た（△営業活動に使用された）現金（純額）」）。
    static func usgaapCashFlowRepeatedActivityTotals(_ activity: USGAAPCashFlowActivity) -> [String] {
        let p = activity.prefix
        return ["\(p)から得た（△\(p)に使用された）現金（純額）"]
    }

    /// 空白（全角含む）を除き、Ⅰ／１．等の区分接頭辞を落とした比較用ラベル。
    static func compactCashFlowLabel(_ label: String) -> String {
        let noSpace = String(label.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{3000}"
        }.map(Character.init))
        return USGAAPHtml.stripSectionPrefix(noSpace)
            .trimmingCharacters(in: CharacterSet(charactersIn: "：:"))
    }

    /// US-GAAP CF 本表の営業／投資活動合計（「営業活動に使用された現金（純額）」等のラベル揺れ）。ラベルは空白を無視して
    /// 「<活動><合計サフィックス>」と完全一致するものだけ。区分が付いた行は同じ区分に限る。
    /// 値 0 の一致（見出しが「－」で出た行）は飛ばし、非ゼロの一致が無いときだけ 0 を返す。
    static func usgaapCashFlowActivityTotal(
        _ items: [StatementLineItem], activity: USGAAPCashFlowActivity
    ) -> Double? {
        let targets = Set(usgaapCashFlowTotalSuffixes.map { activity.prefix + $0 })
            .union(usgaapCashFlowRepeatedActivityTotals(activity))
        var firstZero: Double?
        for item in items {
            guard let label = item.label else { continue }
            if let section = item.section, section != activity.section { continue }
            guard targets.contains(compactCashFlowLabel(label)) else { continue }
            if item.value != 0 { return item.value }
            if firstZero == nil { firstZero = item.value }
        }
        return firstZero
    }

    /// 経営指標等（SummaryOfBusinessResults）の US-GAAP CF。本表ラベルで取れないときだけ使う。
    static func usgaapSummaryCashFlow(_ fieldSet: FieldSet, tag: String) -> Double? {
        fieldSet[tag]?.current
    }

    /// US-GAAP 法人税等。合計行（キヤノン「Ⅴ 法人税等」）を優先し、無ければ当期税＋繰延
    /// （富士フイルム: 入れ子右セルの親合計は statement 行に出ないので内訳を足す）。
    /// 「法人税等」の部分一致は「法人税等調整額」に当たるため使わない。
    private static func resolveUSGAAPIncomeTax(_ items: [StatementLineItem]) -> Double? {
        for item in items {
            guard !AmountUnit.isPerShare(unitRef: item.unit), let label = item.label else { continue }
            let stripped = USGAAPHtml.stripSectionPrefix(label)
            if stripped == "法人税等合計" || stripped.hasSuffix("法人税等合計") {
                return item.value
            }
        }
        for item in items {
            guard !AmountUnit.isPerShare(unitRef: item.unit), let label = item.label else { continue }
            if USGAAPHtml.stripSectionPrefix(label) == "法人税等" {
                return item.value
            }
        }
        var current: Double?
        var deferred: Double?
        for item in items {
            guard !AmountUnit.isPerShare(unitRef: item.unit), let label = item.label else { continue }
            if label.contains("未払") { continue }
            let stripped = USGAAPHtml.stripSectionPrefix(label)
            if stripped.contains("法人税等調整") {
                deferred = item.value
            } else if stripped.contains("法人税")
                && (stripped.contains("住民税") || stripped.contains("事業税"))
            {
                current = item.value
            }
        }
        if current != nil || deferred != nil {
            return (current ?? 0) + (deferred ?? 0)
        }
        return nil
    }

    /// US-GAAP 支払利息。PL は △ 表示の負値。financials は費用の絶対値。
    /// 「受取利息」「未払利息」は除外する（`USGAAPHtml.extractInterestExpense` と同じ）。
    private static func resolveUSGAAPInterestExpense(_ items: [StatementLineItem]) -> Double? {
        absIfPresent(
            firstByLabel(items, contains: "支払利息", excluding: ["受取", "未払"])
                ?? firstByLabel(items, contains: "利息費用", excluding: ["受取", "未払"]))
    }

    /// US-GAAP の自己株式取得（SS 合計列 / CF 財務）。△ は負。financials はキャッシュアウト正。
    /// 「取得」を含む行だけを対象にし、売却のみの行は拾わない。
    private static func resolveUSGAAPTreasuryPurchase(_ items: [StatementLineItem]) -> Double? {
        for item in items {
            let label = item.label ?? ""
            guard label.contains("自己株式"), label.contains("取得") else { continue }
            return abs(item.value)
        }
        return nil
    }

    private static func absIfPresent(_ value: Double?) -> Double? {
        value.map { abs($0) }
    }

    /// US-GAAP の SS「当社株主への配当金」。合計列（純資産合計）に載る減少額は負。
    /// financials の `dividend_ss` はキャッシュアウト正（`DividendSSExtractor` と同じ符号反転）。
    /// 前期・当期が同一表に並ぶ場合は最後の行（当期）を使う。
    private static func resolveUSGAAPDividendSS(_ items: [StatementLineItem]) -> Double? {
        var last: Double?
        for item in items {
            let label = item.label ?? ""
            guard label.contains("当社株主への") else { continue }
            last = item.value
        }
        return last.map { -$0 }
    }

    /// Statement 本表の当期値で FieldSet を上書きする。1株当たり行は金額スロットに入れない。
    /// 同一タグが複数行あるときは後勝ち（PL/BS 本表は通常1行。CF の期首/期末はここでは重ねない）。
    ///
    /// statement 組立は既定 `nilAsZero: true` のため `xsi:nil` が 0 行になる。こちらは
    /// `nilAsZero: false` の FieldSet に載せるので、0 は overlay しない。0 を書くと
    /// `resolveItemPreferCurrent` が高優先タグの合成 0 で止まり、後位タグの実額を落とす。
    /// 真の 0 は fact 収集側に既にある。借入金 0 の IBD 投影は `overlayStatementCurrentValues`。
    static func overlayStatementLineCurrents(
        _ fieldSet: inout FieldSet, lines: [StatementLineItem]
    ) {
        for item in lines {
            guard !AmountUnit.isPerShare(unitRef: item.unit) else { continue }
            guard item.value != 0 else { continue }
            var fv = fieldSet[item.tag] ?? FieldValue(current: nil, prior: nil)
            fv.current = item.value
            fieldSet[item.tag] = fv
        }
    }

    /// 本表に連結営業収益合計行が無いときの明示合計（`statementSalesSummaryTotalTags`）。
    /// 本表が既に NetSales / RWY / ELE 等の合計を採っている会社には載せない。
    /// 連結 CurrentYearDuration を売上 FieldSet へ載せる。合計タグが無ければ
    /// `resolveNetSales` が同一グループの業種別内訳を合算する。
    static func overlayStatementSalesSummaryTotals(
        _ fieldSet: inout FieldSet, tagElements: XbrlTagElements
    ) {
        let extra = tagElements.filter { Xbrl.statementSalesSummaryTotalTags.contains($0.key) }
        guard !extra.isEmpty else { return }
        let extraFS = fieldSetFromDuration(extra)
        var overlay: FieldSet = [:]
        for tag in Xbrl.statementSalesSummaryTotalTags {
            guard let fv = extraFS[tag], fv.current != nil || fv.prior != nil else { continue }
            overlay[tag] = fv
        }
        guard !overlay.isEmpty else { return }

        let current = resolveItemPreferCurrent(fieldSet, tags: Xbrl.netSalesTags)
        let needsTotal: Bool
        if current.current == nil && current.prior == nil {
            needsTotal = true
        } else if let tag = current.tag, Xbrl.operatingRevenueSplitComponentTags.contains(tag) {
            needsTotal = true
        } else {
            needsTotal = false
        }
        guard needsTotal else { return }
        for (tag, fv) in overlay {
            fieldSet[tag] = fv
        }
    }

    /// geography カバー判定用の売上ラベル。Summary 組立とは独立。
    /// 本表 FieldSet に売上高（NetSales*）と営業収益（OperatingRevenue*）が別タグであるときは
    /// PL トップラインの営業収益を返し、既存の `isNonSalesRevenueLabel` 経路で表の総合計を
    /// アンカーにする（3382 / 8233 / 8267。売上高は小計行）。
    static func geographyCoverageSalesLabel(
        summaryLabel: String?,
        fieldSet: FieldSet
    ) -> String? {
        if fieldSetHasDistinctNetSalesAndOperatingRevenue(fieldSet) {
            return "営業収益"
        }
        return summaryLabel
    }

    /// 連結 PL のトップライン収益。営業利益行より上の収益行のうち、他の収益行の構成要素でない行の和。
    /// 合計行があればそれ（6758 `SalesAndFinancialServicesRevenueIFRS`、3382 `OperatingRevenue1`）、
    /// 合計行が無く 売上高 と 営業収入 が並ぶときは和（9950）。`sales` より大きいときだけ返す。
    /// 金融収益・その他の収益・持分法を含む IFRS の「収益合計」（HOYA 7741 / 6141 / 8698）は
    /// 営業の収益ではないので合計に使わない。IFRS で収益行が並ぶだけ（電通 4324 の 売上高 と 収益）は
    /// どれがトップラインか決まらないので立てない。
    static func incomeStatementTopLineRevenue(
        _ lines: [StatementLineItem], sales: Double?
    ) -> Double? {
        guard let sales, sales > 0 else { return nil }
        var byTag: [String: StatementLineItem] = [:]
        var revenueLines: [StatementLineItem] = []
        for line in lines {
            if isOperatingProfitLine(line) { break }
            if byTag[line.tag] == nil { byTag[line.tag] = line }
            guard !AmountUnit.isPerShare(unitRef: line.unit), isTopLineRevenueTag(line.tag),
                  !isOfWhichLine(line)
            else { continue }
            if revenueLines.contains(where: { $0.tag == line.tag }) { continue }
            revenueLines.append(line)
        }
        revenueLines = revenueLines.filter { sumsOnlyRevenue($0, byTag: byTag, depth: 0) }
        let componentTags = Set(revenueLines.flatMap { ($0.components ?? []).map(\.tag) })
        let roots = revenueLines.filter { !componentTags.contains($0.tag) }
        guard !roots.isEmpty else { return nil }
        if roots.count > 1,
           !roots.allSatisfy({ $0.tag.hasPrefix("NetSales") || $0.tag.hasPrefix("OperatingRevenue") })
        {
            return nil
        }
        // 計算リンクが無く、合計の 売上高 と内訳の 売上高（製品）等が別々の根に残ったときは足すと二重になる。
        // どれかの根が残りの根の和と一致するなら合計と内訳の関係なので立てない（Summary sales のまま）。
        if roots.count > 1 {
            let total = roots.reduce(0.0) { $0 + $1.value }
            let isTotalOfOthers = roots.contains { root in
                let others = total - root.value
                return others > 0 && abs(root.value - others) <= root.value * topLineRevenueMinimumExcess
            }
            if isTotalOfOthers { return nil }
        }
        let topLine = roots.reduce(0.0) { $0 + $1.value }
        return topLine > sales * (1 + topLineRevenueMinimumExcess) ? topLine : nil
    }

    /// 端数の丸め差（百万円表示の1単位など）でトップラインを立てない。
    private static let topLineRevenueMinimumExcess = 0.001

    private static func isTopLineRevenueTag(_ tag: String) -> Bool {
        if tag.contains("Cost") || tag.contains("Expense") || tag.contains("Profit")
            || tag.contains("Income") && !tag.contains("Revenue")
        {
            return false
        }
        if tag.hasSuffix("NOI") || tag.contains("NonOperating") { return false }
        if isNonOperatingIncomeTag(tag) { return false }
        return tag.hasPrefix("NetSales") || tag.hasPrefix("OperatingRevenue")
            || tag.hasPrefix("Revenue") || tag.contains("Revenue")
    }

    /// 金融収益・その他の収益・受取利息など。`OtherFinancialIncomeRevenueIFRS`（8698）のように
    /// Revenue を含んでも営業の収益ではない。
    private static func isNonOperatingIncomeTag(_ tag: String) -> Bool {
        let markers = [
            "FinanceIncome", "FinancialIncome", "FinancialRevenue", "OtherIncome",
            "ShareOfProfit", "InterestIncome", "DividendIncome", "GainOn",
        ]
        return markers.contains { tag.contains($0) }
    }

    /// 合計行の構成要素が（入れ子も含め）収益行だけか。
    private static func sumsOnlyRevenue(
        _ line: StatementLineItem, byTag: [String: StatementLineItem], depth: Int
    ) -> Bool {
        guard let components = line.components, !components.isEmpty else { return true }
        guard depth < 4 else { return false }
        for component in components {
            guard isTopLineRevenueTag(component.tag) else { return false }
            if let child = byTag[component.tag],
               !sumsOnlyRevenue(child, byTag: byTag, depth: depth + 1)
            {
                return false
            }
        }
        return true
    }

    /// 「（内、受取利息）」「うち、金利収益」は上の収益行の内数（8473 / 8253）。足さない。
    private static func isOfWhichLine(_ line: StatementLineItem) -> Bool {
        let tag = line.tag
        if tag.hasPrefix("Of"), let next = tag.dropFirst(2).first, next.isUppercase { return true }
        let label = (line.label ?? "").replacingOccurrences(of: " ", with: "")
        return label.hasPrefix("うち") || label.hasPrefix("（うち") || label.hasPrefix("(うち")
            || label.hasPrefix("（内") || label.hasPrefix("(内") || label.hasPrefix("内、")
    }

    private static func isOperatingProfitLine(_ line: StatementLineItem) -> Bool {
        let tag = line.tag
        if tag.hasPrefix("OperatingIncome") || tag.hasPrefix("OperatingProfit")
            || tag.hasPrefix("OperatingLoss")
        {
            return true
        }
        let label = line.label ?? ""
        return label.hasPrefix("営業利益") || label.hasPrefix("営業損失")
    }

    /// 売上高タグと営業収益タグが両方、当期値付きで載っている。
    static func fieldSetHasDistinctNetSalesAndOperatingRevenue(_ fieldSet: FieldSet) -> Bool {
        var hasNetSales = false
        var hasOperatingRevenue = false
        for (tag, value) in fieldSet {
            guard value.current != nil else { continue }
            if tag.hasPrefix("NetSales") { hasNetSales = true }
            if isGeographyOperatingRevenueTag(tag) { hasOperatingRevenue = true }
            if hasNetSales && hasOperatingRevenue { return true }
        }
        return false
    }

    private static func isGeographyOperatingRevenueTag(_ tag: String) -> Bool {
        tag.hasPrefix("OperatingRevenue") || Xbrl.operatingRevenueTags.contains(tag)
    }

    /// Summary `net_profit` は親会社株主に帰属する当期純利益を正とする。
    /// PL に親会社帰属タグがあればそれを使い、無ければ SS を見る。
    /// どちらにも無いときだけ既存の `ProfitLoss` 等（`fallback`）に戻る。
    static func resolveParentAttributableNetProfit(
        incomeStatement: [StatementLineItem],
        changesInEquity: [StatementLineItem],
        fallback: Double?
    ) -> Double? {
        firstTaggedValue(incomeStatement, tags: Xbrl.parentAttributableNetProfitTags)
            ?? firstTaggedValue(changesInEquity, tags: Xbrl.parentAttributableNetProfitTags)
            ?? fallback
    }

    private static func firstTaggedValue(
        _ items: [StatementLineItem], tags: [String]
    ) -> Double? {
        for tag in tags {
            if let item = items.first(where: { $0.tag == tag && $0.unit != "JPYPerShares" }) {
                return item.value
            }
        }
        return nil
    }

    /// US-GAAP 売掛相当。単一行（受取債権合計 / 売上債権）を優先し、無ければ流動資産内の
    /// 債権内訳を合算する（富士フイルム型。足し算親は行にしない）。
    private static func resolveUSGAAPAccountsReceivable(_ items: [StatementLineItem]) -> Double? {
        for item in items {
            guard let label = item.label else { continue }
            if label.contains("受取債権合計") { return item.value }
        }
        for item in items {
            guard let label = item.label else { continue }
            let stripped = USGAAPHtml.stripSectionPrefix(label)
            if stripped == "売上債権" || stripped.hasSuffix("売上債権") {
                return item.value
            }
        }
        return sumUSGAAPCurrentReceivableComponents(items)
    }

    /// US-GAAP 買掛相当。単一行（買入債務）を優先し、無ければ流動負債内の債務内訳を合算する
    /// （富士フイルム: 営業債務 + 設備関係債務 + 関連会社等に対する債務）。
    private static func resolveUSGAAPAccountsPayable(_ items: [StatementLineItem]) -> Double? {
        for item in items {
            guard let label = item.label else { continue }
            let stripped = USGAAPHtml.stripSectionPrefix(label)
            if stripped == "買入債務" || stripped.hasSuffix("買入債務") || label.contains("買入債務合計") {
                return item.value
            }
        }
        return sumUSGAAPCurrentPayableComponents(items)
    }

    /// 流動資産ブロック内の債権内訳合算。`長期*` と流動資産合計以降は除外。
    /// 実データ（富士フイルム S100W3XJ）: 営業債権 + リース債権 + 関連会社債権 + 信用損失引当金。
    private static func sumUSGAAPCurrentReceivableComponents(_ items: [StatementLineItem]) -> Double? {
        var total = 0.0
        var found = false
        for item in items {
            guard let label = item.label else { continue }
            let stripped = USGAAPHtml.stripSectionPrefix(label)
            if stripped.contains("流動資産合計") { break }
            if item.section == .liabilities || item.section == .netAssets { break }
            if label.contains("長期") { continue }

            let isReceivable =
                stripped.contains("営業債権")
                || stripped.contains("リース債権")
                || (stripped.contains("関連会社") && stripped.contains("債権"))
            // 引当金は債権ブロック開始後のみ（投資区分の長期引当と混同しない）
            let isAllowance = found && stripped.contains("信用損失引当金")
            guard isReceivable || isAllowance else { continue }
            total += item.value
            found = true
        }
        return found ? total : nil
    }

    /// 流動負債ブロック内の債務内訳合算。流動負債合計以降は除外。
    private static func sumUSGAAPCurrentPayableComponents(_ items: [StatementLineItem]) -> Double? {
        var total = 0.0
        var found = false
        for item in items {
            guard item.section == .liabilities else { continue }
            guard let label = item.label else { continue }
            let stripped = USGAAPHtml.stripSectionPrefix(label)
            if stripped.contains("流動負債合計") { break }

            let isPayable =
                stripped.contains("営業債務")
                || stripped.contains("設備関係債務")
                || (stripped.contains("関連会社") && stripped.contains("債務"))
            guard isPayable else { continue }
            total += item.value
            found = true
        }
        return found ? total : nil
    }

    private static func assignIfAbsent(_ fs: inout FieldSet, _ tag: String, _ value: Double) {
        if fs[tag] == nil {
            fs[tag] = FieldValue(current: value, prior: nil)
        }
    }

    /// Summary 売上の正本行。営業収益計 / 収益合計を、中間の「〜売上高」内訳より優先する
    /// （オリックス: 商品および不動産売上高 442,586 ≠ 営業収益 計 3,330,831）。
    /// 富士フイルム型の単独「売上高」、キヤノン型（製品/サービス内訳の後の「合計」）はフォールバック。
    private static func resolveUSGAAPSales(
        _ items: [StatementLineItem]
    ) -> (value: Double, labelOverride: String?)? {
        for item in items {
            guard let label = item.label, !AmountUnit.isPerShare(unitRef: item.unit) else { continue }
            let stripped = USGAAPHtml.stripSectionPrefix(label)
            if isUSGAAPRevenueTotalLabel(stripped) {
                return (item.value, stripped)
            }
        }
        for item in items {
            guard let label = item.label, !AmountUnit.isPerShare(unitRef: item.unit) else { continue }
            let stripped = USGAAPHtml.stripSectionPrefix(label)
            if stripped == "売上高" {
                return (item.value, nil)
            }
        }
        for item in items {
            guard let label = item.label, !AmountUnit.isPerShare(unitRef: item.unit) else { continue }
            let stripped = USGAAPHtml.stripSectionPrefix(label)
            if stripped.hasSuffix("売上高")
                && !stripped.contains("製品") && !stripped.contains("サービス")
            {
                return (item.value, nil)
            }
        }
        // キヤノン: 営業利益より前にある最初の「合計」（売上ブロックの合計）
        if let opIndex = items.firstIndex(where: {
            USGAAPHtml.stripSectionPrefix($0.label ?? "") == "営業利益"
        }) {
            for item in items.prefix(opIndex) {
                guard let label = item.label, !AmountUnit.isPerShare(unitRef: item.unit) else { continue }
                if USGAAPHtml.stripSectionPrefix(label) == "合計" {
                    return (item.value, nil)
                }
            }
        }
        return nil
    }

    /// オリックス「営業収益 計」/「営業収益計」、野村「収益合計」。控除後の収益合計は除外。
    private static func isUSGAAPRevenueTotalLabel(_ stripped: String) -> Bool {
        if stripped == "収益合計" || (stripped.hasPrefix("収益合計") && !stripped.contains("控除")) {
            return true
        }
        let compact = stripped
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
        return compact == "営業収益計" || compact == "営業収益合計"
    }

    private static func resolveUSGAAPNetProfit(_ items: [StatementLineItem]) -> Double? {
        for item in items {
            guard let label = item.label, !AmountUnit.isPerShare(unitRef: item.unit) else { continue }
            if label.contains("当社株主に帰属する") || label.contains("当社株主帰属当期純利益") {
                return item.value
            }
        }
        return nil
    }

    private static func labelContainsCashEquivalents(_ label: String) -> Bool {
        let s = USGAAPHtml.stripSectionPrefix(label)
        return s.contains("現金及び現金同等物")
            && !s.contains("期首") && !s.contains("期末")
            && !s.contains("増減") && !s.contains("為替")
    }

    /// ラベル部分一致の最長キーを採用（`USGAAPHtml` の extractHtmlLabels と同型）。
    private static func bestMatchingVirtualTag(label: String, map: [String: String]) -> String? {
        let stripped = USGAAPHtml.stripSectionPrefix(label)
        var bestKey: String?
        for key in map.keys {
            if stripped.contains(key) || label.contains(key) {
                if bestKey == nil || key.count > bestKey!.count {
                    bestKey = key
                }
            }
        }
        return bestKey.map { map[$0]! }
    }

}
