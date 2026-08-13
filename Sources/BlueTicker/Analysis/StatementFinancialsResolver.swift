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
            statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]
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
        let statementTags = Set(
            (year.balanceSheet + year.incomeStatement + year.cashFlow).map(\.tag))
        let masked = tagElements.filter { statementTags.contains($0.key) }
        let durationFS = fieldSetFromDuration(masked)
        let instantFS = fieldSetFromInstant(masked)

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
            dividendPaidCF: divPaid.current
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
            dividendPaidCF: divPaid.current
        )
    }

    /// US-GAAP 売掛相当。単一行（受取債権合計 / 売上債権）を優先し、無ければ流動資産内の
    /// 債権内訳を合算する（富士フイルム型。Statement は入れ子右セルの親小計を行値にしないため）。
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

    /// 富士フイルム型「Ⅰ 売上高」を優先し、キヤノン型（製品/サービス内訳の後の「合計」）へフォールバック。
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
