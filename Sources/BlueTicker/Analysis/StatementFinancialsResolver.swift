// financials 組立向けの本表水準値パススルー（タスク #5、`docs/financials-summary-separation.md`）。
// 正本は statement（BS/PL/CF 行）。ingest 順に依存せず、同一 XBRL パスで Statement を直接解決する（#10b）。

import Foundation

/// `company_financials` 組立が読む本表水準値（円単位）。派生指標は含まない。
struct StatementFinancialsValues {
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
    var cfo: Double?
    var cfi: Double?
    var pretaxIncome: Double?
    var incomeTax: Double?
    var dividendSS: Double?
    /// #8: IndividualAnalyzer 切替済。statement 行だけで取れる値。IFRS 支払利息の notes は組立層。
    var interestExpense: Double?
    var cfTreasuryStock: Double?
    var buyback: Double?
}

enum StatementFinancialsResolver {

    /// `company_financials` 組立が読む本表水準値。正本は statement（`StatementAnalyzer.resolveFromXBRL`）。
    /// US-GAAP は HTML Statement 行のラベルから仮想タグ FieldSet を組み立て、既存 Extractor へ渡す。
    /// J-GAAP / IFRS は Statement が採用したタグだけを許可した FieldSet で Extractor を回す
    /// （SummaryOfBusinessResults 等の本表外タグは混ぜない。コンテキストは元 fact を保持）。
    static func resolve(xbrlDir: URL) -> StatementFinancialsValues? {
        let tagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        guard !tagElements.isEmpty else { return nil }
        let accountingStandard = detectAccountingStandard(tagElements)

        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir,
            docID: nil,
            statementTypes: [.balanceSheet, .incomeStatement, .cashFlow, .changesInEquity]
        ) else { return nil }

        if accountingStandard == "US-GAAP" {
            return resolveFromUSGAAPStatement(year)
        }
        return resolveFromStructuredStatement(
            year, tagElements: tagElements, accountingStandard: accountingStandard)
    }

    // MARK: - J-GAAP / IFRS（構造化 XBRL タグ）

    private static func resolveFromStructuredStatement(
        _ year: StatementYear, tagElements: XbrlTagElements, accountingStandard: String
    ) -> StatementFinancialsValues {
        // Statement 行のタグを許可リストにし、元 fact のコンテキストを保った FieldSet を組む。
        // CF の期首/期末で同タグが並ぶ会社でも Instant CurrentYear を正しく拾える
        // （行値だけを辞書化すると先勝ちで期首や計算派生値に引きずられる）。
        // SS は dividend_ss / buyback 専用。済み本表 Extractor（sales 等）の候補に混ぜない。
        let mainTags = Set(
            (year.balanceSheet + year.incomeStatement + year.cashFlow).map(\.tag))
        let equityTags = Set(year.changesInEquity.map(\.tag))
        let maskedMain = tagElements.filter { mainTags.contains($0.key) }
        let maskedEquity = tagElements.filter { mainTags.union(equityTags).contains($0.key) }
        let durationFS = fieldSetFromDuration(maskedMain)
        let instantFS = fieldSetFromInstant(maskedMain)

        let is_ = IncomeStatementExtractor.extract(
            fieldSet: durationFS, accountingStandard: accountingStandard)
        let op = OperatingProfitExtractor.extract(
            fieldSet: durationFS, accountingStandard: accountingStandard)
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
            equityDurationFS: fieldSetFromDuration(maskedEquity),
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
        if operatingProfit == nil, let bp = nr.businessProfit {
            operatingProfit = bp
            operatingProfitLabel = "事業利益"
        }

        return StatementFinancialsValues(
            sales: sales,
            salesLabel: salesLabel,
            operatingProfit: operatingProfit,
            operatingProfitLabel: operatingProfitLabel,
            netProfit: is_.netProfit,
            totalAssets: bs.totalAssets,
            currentAssets: bs.currentAssets,
            nonCurrentAssets: bs.nonCurrentAssets,
            currentLiabilities: bs.currentLiabilities,
            nonCurrentLiabilities: bs.nonCurrentLiabilities,
            netAssets: bs.netAssets,
            ppeTotal: ppe.total,
            accountsReceivable: ar.current,
            inventory: inv.current,
            accountsPayable: ap.current,
            cashEquivalents: cash.current,
            dividendPaidCF: divPaid.current,
            grossProfit: remaining.grossProfit,
            grossProfitLabel: remaining.grossProfitLabel,
            sga: remaining.sga,
            cfo: remaining.cfo,
            cfi: remaining.cfi,
            pretaxIncome: remaining.pretaxIncome,
            incomeTax: remaining.incomeTax,
            dividendSS: remaining.dividendSS,
            interestExpense: remaining.interestExpense,
            cfTreasuryStock: remaining.cfTreasuryStock,
            buyback: remaining.buyback
        )
    }

    // MARK: - US-GAAP（HTML Statement ラベル → 仮想タグ）

    private static func resolveFromUSGAAPStatement(_ year: StatementYear) -> StatementFinancialsValues {
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
            if stripped == "純資産合計" || stripped == "純資産" {
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
        if let sales = resolveUSGAAPSales(year.incomeStatement) {
            durationFS["NetSales"] = FieldValue(current: sales, prior: nil)
        }
        if let np = resolveUSGAAPNetProfit(year.incomeStatement) {
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

        return StatementFinancialsValues(
            sales: is_.sales,
            salesLabel: is_.salesLabel ?? "売上高",
            operatingProfit: op.operatingProfit ?? is_.operatingProfit,
            operatingProfitLabel: op.operatingProfit != nil ? op.label : nil,
            netProfit: is_.netProfit,
            totalAssets: bs.totalAssets,
            currentAssets: bs.currentAssets,
            nonCurrentAssets: nonCurrent,
            currentLiabilities: bs.currentLiabilities,
            nonCurrentLiabilities: bs.nonCurrentLiabilities,
            netAssets: bs.netAssets,
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
                    excluding: ["期首", "期末", "明細"]),
            cfi: statementCashFlowTotal(year.cashFlow, tags: statementInvestingCashFlowTags)
                ?? firstByLabel(
                    year.cashFlow, contains: "投資活動によるキャッシュ・フロー",
                    excluding: ["期首", "期末", "明細"]),
            pretaxIncome: tax.pretaxIncome
                ?? firstByLabel(year.incomeStatement, contains: "税引前")
                ?? firstByLabel(year.incomeStatement, contains: "税金等調整前"),
            incomeTax: resolveUSGAAPIncomeTax(year.incomeStatement)
                ?? tax.incomeTax,
            dividendSS: resolveUSGAAPDividendSS(year.changesInEquity),
            interestExpense: resolveUSGAAPInterestExpense(year.incomeStatement),
            cfTreasuryStock: resolveUSGAAPTreasuryPurchase(year.cashFlow),
            buyback: resolveUSGAAPTreasuryPurchase(year.changesInEquity)
                ?? resolveUSGAAPTreasuryPurchase(year.cashFlow)
        )
    }

    /// statement 行に載る #5c / #8 フィールド。HTML/TextBlock フォールバックは付けない。
    private static func remainingFromStatementExtractors(
        durationFS: FieldSet, equityDurationFS: FieldSet, maskedEquity: XbrlTagElements,
        accountingStandard: String, operating: OperatingProfitResult,
        cashFlow: [StatementLineItem]
    ) -> (
        grossProfit: Double?, grossProfitLabel: String?, sga: Double?, cfo: Double?, cfi: Double?,
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

    private static func firstByLabel(
        _ items: [StatementLineItem], contains: String, excluding: [String] = []
    ) -> Double? {
        for item in items {
            let label = item.label ?? ""
            guard label.contains(contains) else { continue }
            if excluding.contains(where: { label.contains($0) }) { continue }
            return item.value
        }
        return nil
    }

    /// US-GAAP 法人税等。合計行（キヤノン「Ⅴ 法人税等」）を優先し、無ければ当期税＋繰延
    /// （富士フイルム: 入れ子右セルの親合計は statement 行に出ないので内訳を足す）。
    /// 「法人税等」の部分一致は「法人税等調整額」に当たるため使わない。
    private static func resolveUSGAAPIncomeTax(_ items: [StatementLineItem]) -> Double? {
        for item in items {
            guard item.unit != "JPYPerShares", let label = item.label else { continue }
            let stripped = USGAAPHtml.stripSectionPrefix(label)
            if stripped == "法人税等合計" || stripped.hasSuffix("法人税等合計") {
                return item.value
            }
        }
        for item in items {
            guard item.unit != "JPYPerShares", let label = item.label else { continue }
            if USGAAPHtml.stripSectionPrefix(label) == "法人税等" {
                return item.value
            }
        }
        var current: Double?
        var deferred: Double?
        for item in items {
            guard item.unit != "JPYPerShares", let label = item.label else { continue }
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

    /// 富士フイルム型「売上高」を優先し、キヤノン型（製品/サービス内訳の後の「合計」）へフォールバック。
    private static func resolveUSGAAPSales(_ items: [StatementLineItem]) -> Double? {
        for item in items {
            guard let label = item.label, item.unit != "JPYPerShares" else { continue }
            let stripped = USGAAPHtml.stripSectionPrefix(label)
            if stripped == "売上高" || (stripped.hasSuffix("売上高")
                && !stripped.contains("製品") && !stripped.contains("サービス"))
            {
                return item.value
            }
        }
        // キヤノン: 営業利益より前にある最初の「合計」（売上ブロックの合計）
        if let opIndex = items.firstIndex(where: {
            USGAAPHtml.stripSectionPrefix($0.label ?? "") == "営業利益"
        }) {
            for item in items.prefix(opIndex) {
                guard let label = item.label, item.unit != "JPYPerShares" else { continue }
                if USGAAPHtml.stripSectionPrefix(label) == "合計" {
                    return item.value
                }
            }
        }
        return nil
    }

    private static func resolveUSGAAPNetProfit(_ items: [StatementLineItem]) -> Double? {
        for item in items {
            guard let label = item.label, item.unit != "JPYPerShares" else { continue }
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
