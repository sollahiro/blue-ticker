// financials 組立向けの本表水準値パススルー（タスク #5、`docs/financials-summary-separation-concept.md`）。
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
    /// J-GAAP / IFRS は Statement 行の実タグだけで FieldSet を作り、SummaryOfBusinessResults 等を混ぜない。
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
        return resolveFromStructuredStatement(year, accountingStandard: accountingStandard)
    }

    // MARK: - J-GAAP / IFRS（構造化 XBRL タグ）

    private static func resolveFromStructuredStatement(
        _ year: StatementYear, accountingStandard: String
    ) -> StatementFinancialsValues {
        let durationFS = fieldSetFromLineItems(year.incomeStatement + year.cashFlow)
        let instantFS = fieldSetFromLineItems(year.balanceSheet)

        // 空 FieldSet でも Extractor は動くが、行が無い会社は全 nil で返す。
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

    /// 富士フイルムは「受取債権合計」、キヤノンは「売上債権」。引当金行は使わない。
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
        return nil
    }

    /// キヤノン「買入債務」。関連会社債務の明細行は使わない。
    private static func resolveUSGAAPAccountsPayable(_ items: [StatementLineItem]) -> Double? {
        for item in items {
            guard let label = item.label else { continue }
            let stripped = USGAAPHtml.stripSectionPrefix(label)
            if stripped == "買入債務" || stripped.hasSuffix("買入債務") || label.contains("買入債務合計") {
                return item.value
            }
        }
        return nil
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

    private static func fieldSetFromLineItems(_ items: [StatementLineItem]) -> FieldSet {
        var fs: FieldSet = [:]
        for item in items {
            // 同じタグが CF 期首/期末などで複数行ある場合は先勝ち（本表水準値は BS Instant /
            // PL Duration / CF 合計タグが主で、期末現金は BS の cash タグ側で取る）。
            if fs[item.tag] == nil {
                fs[item.tag] = FieldValue(current: item.value, prior: nil)
            }
        }
        return fs
    }
}
