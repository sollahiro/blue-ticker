// XBRL 分析抽出器群
// Python の blue_ticker/analysis/{income_statement,cash_flow,balance_sheet,...}.py 相当

import Foundation

// MARK: - Result Types

struct IncomeStatementResult {
    var sales: Double?
    var salesPrior: Double?
    var operatingProfit: Double?
    var operatingProfitPrior: Double?
    var netProfit: Double?
    var netProfitPrior: Double?
    var accountingStandard: String
    var salesLabel: String?
    var method: String
}

struct CashFlowResult {
    var cfo: Double?
    var cfoPrior: Double?
    var cfi: Double?
    var cfiPrior: Double?
    var accountingStandard: String
}

struct GrossProfitResult {
    var grossProfit: Double?
    var grossProfitPrior: Double?
    var grossProfitLabel: String?
    var method: String
    var accountingStandard: String
}

struct OperatingProfitResult {
    var operatingProfit: Double?
    var operatingProfitPrior: Double?
    var sga: Double?
    var sgaPrior: Double?
    var label: String
    var method: String
    var accountingStandard: String
}

struct BalanceSheetResultValue {
    var totalAssets: Double?
    var currentAssets: Double?
    var nonCurrentAssets: Double?
    var currentLiabilities: Double?
    var nonCurrentLiabilities: Double?
    var netAssets: Double?
    var priorNetAssets: Double?
    var accountingStandard: String
    var method: String
    var components: [(label: String, current: Double?, prior: Double?)]
}

struct IBDResult {
    var total: Double?
    var priorTotal: Double?
    var components: [(label: String, current: Double?, prior: Double?)]
    var method: String
    var accountingStandard: String
}

struct EmployeesResult {
    var current: Double?
    var prior: Double?
    var method: String
    var scope: String
}

struct TaxExpenseResult {
    var pretaxIncome: Double?
    var incomeTax: Double?
    var effectiveTaxRate: Double?
    var accountingStandard: String
}

struct InterestExpenseResult {
    var current: Double?
    var prior: Double?
    var method: String
    var accountingStandard: String
}

struct TangibleFixedAssetsResult {
    var total: Double?
    var method: String
    var accountingStandard: String
}

struct CapexResult {
    var current: Double?
    var method: String
}

struct RDResult {
    var current: Double?
    var method: String
}

// MARK: - Income Statement Extractor

enum IncomeStatementExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> IncomeStatementResult {
        let salesItem = resolveItemPreferCurrent(fieldSet, tags: Xbrl.netSalesTags)
        var opItem = resolveItemPreferCurrent(fieldSet, tags: Xbrl.operatingProfitDirectTags)
        if opItem.current == nil && opItem.prior == nil {
            opItem = resolveItemPreferCurrent(fieldSet, tags: Xbrl.ordinaryIncomeTags)
        }
        let npItem = resolveItemPreferCurrent(fieldSet, tags: Xbrl.netProfitTags)

        let salesLabel = salesLabelForTag(salesItem.tag)

        let foundTags = [salesItem.current != nil ? "sales" : nil,
                         opItem.current != nil ? "operating_profit" : nil,
                         npItem.current != nil ? "net_profit" : nil].compactMap { $0 }
        let method = foundTags.isEmpty ? "not_found" : foundTags.joined(separator: ",")

        return IncomeStatementResult(
            sales: salesItem.current,
            salesPrior: salesItem.prior,
            operatingProfit: opItem.current,
            operatingProfitPrior: opItem.prior,
            netProfit: npItem.current,
            netProfitPrior: npItem.prior,
            accountingStandard: accountingStandard,
            salesLabel: salesItem.tag != nil ? salesLabel : nil,
            method: method
        )
    }

    private static func salesLabelForTag(_ tag: String?) -> String {
        guard let tag = tag else { return "売上高" }
        if Xbrl.ordinaryRevenueTags.contains(tag) { return "経常収益" }
        if Xbrl.operatingRevenueTags.contains(tag) { return "営業収益" }
        switch tag {
        case "NetSalesIFRS", "RevenueIFRS", "RevenueIFRSSummaryOfBusinessResults", "Revenue":
            return "売上収益"
        case "NetSalesOfCompletedConstructionContractsCNS",
             "NetSalesOfCompletedConstructionContractsSummaryOfBusinessResults":
            return "完成工事高"
        default:
            return "売上高"
        }
    }
}

// MARK: - Cash Flow Extractor

enum CashFlowExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> CashFlowResult {
        let cfoItem = resolveItem(fieldSet, tags: Xbrl.cfOperatingTags)
        let cfiItem = resolveItem(fieldSet, tags: Xbrl.cfInvestingTags)
        return CashFlowResult(
            cfo: cfoItem.current, cfoPrior: cfoItem.prior,
            cfi: cfiItem.current, cfiPrior: cfiItem.prior,
            accountingStandard: accountingStandard
        )
    }
}

// MARK: - Balance Sheet Extractor

enum BalanceSheetExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> BalanceSheetResultValue {
        var components: [(label: String, current: Double?, prior: Double?)] = []
        var labelToValue: [String: Double?] = [:]
        var priorNetAssets: Double? = nil

        for item in Xbrl.allStandardBSItems {
            var resolved = resolveItem(fieldSet, tags: item.tags)
            if resolved.tag == nil, let d = item.deriveMinus {
                resolved = deriveSubtraction(fieldSet, minuendTags: d.minuend, subtrahendTags: d.subtrahend)
            }
            // US-GAAP 非流動資産: HTML 仮想タグ積み上げ → XBRL 積み上げフォールバック
            if item.field == "NonCurrentAssets" && resolved.current == nil {
                resolved = resolveAggregate(fieldSet, componentTagLists: Xbrl.usgaapHtmlNCAComponents)
                if resolved.current == nil {
                    resolved = resolveAggregate(fieldSet, componentTagLists: Xbrl.usgaapXbrlNCAComponents)
                }
            }

            components.append((label: item.label, current: resolved.current, prior: resolved.prior))
            labelToValue[item.label] = resolved.current
            if item.field == "NetAssets" && resolved.prior != nil {
                priorNetAssets = resolved.prior
            }
        }

        let totalAssets = labelToValue["資産合計"] ?? nil
        let currentAssets = labelToValue["流動資産"] ?? nil
        let nonCurrentAssets = labelToValue["非流動資産"] ?? nil
        let currentLiabilities = labelToValue["流動負債"] ?? nil
        let nonCurrentLiabilities = labelToValue["非流動負債"] ?? nil
        let netAssets = labelToValue["純資産/資本合計"] ?? nil

        let hasAny = [totalAssets, currentAssets, nonCurrentAssets,
                      currentLiabilities, nonCurrentLiabilities, netAssets].contains(where: { $0 != nil })

        return BalanceSheetResultValue(
            totalAssets: totalAssets,
            currentAssets: currentAssets,
            nonCurrentAssets: nonCurrentAssets,
            currentLiabilities: currentLiabilities,
            nonCurrentLiabilities: nonCurrentLiabilities,
            netAssets: netAssets,
            priorNetAssets: priorNetAssets,
            accountingStandard: accountingStandard,
            method: hasAny ? "field_parser" : "not_found",
            components: components
        )
    }
}

// MARK: - Gross Profit Extractor

enum GrossProfitExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String, xbrlDir: URL? = nil) -> GrossProfitResult {
        // US-GAAP 企業: 連結損益計算書HTML(0105010)から直接解析
        if accountingStandard == "US-GAAP" {
            if let dir = xbrlDir, let fv = USGAAPHtml.extractGrossProfit(in: dir) {
                return GrossProfitResult(
                    grossProfit: fv.current,
                    grossProfitPrior: fv.prior,
                    grossProfitLabel: nil,
                    method: "usgaap_html",
                    accountingStandard: "US-GAAP"
                )
            }
            return GrossProfitResult(
                grossProfit: nil, grossProfitPrior: nil, grossProfitLabel: nil,
                method: "not_found", accountingStandard: "US-GAAP"
            )
        }

        // 直接タグで試行
        let directItem = resolveItemPreferCurrent(fieldSet, tags: Xbrl.grossProfitDirectTags)
        if directItem.current != nil {
            return GrossProfitResult(
                grossProfit: directItem.current,
                grossProfitPrior: directItem.prior,
                grossProfitLabel: nil,
                method: "direct",
                accountingStandard: accountingStandard
            )
        }

        // 営業総利益（倉庫・運輸等）
        let opGpItem = resolveItemPreferCurrent(fieldSet, tags: Xbrl.operatingGrossProfitDirectTags)
        if opGpItem.current != nil {
            return GrossProfitResult(
                grossProfit: opGpItem.current,
                grossProfitPrior: opGpItem.prior,
                grossProfitLabel: "営業総利益",
                method: "operating_gross_profit",
                accountingStandard: accountingStandard
            )
        }

        // 銀行業: 連結業務粗利益を構成要素から積み上げ
        if let bankGP = extractBankBusinessGrossProfit(fieldSet: fieldSet, accountingStandard: accountingStandard) {
            return bankGP
        }

        // 計算法: 売上高 − 売上原価
        let salesItem = resolveItem(fieldSet, tags: Xbrl.grossProfitSalesTags)
        let costsItem = resolveItem(fieldSet, tags: Xbrl.grossProfitCostsTags)
        if let s = salesItem.current, let c = costsItem.current {
            let gp = s - c
            let gpPrior: Double? = salesItem.prior != nil && costsItem.prior != nil
                ? salesItem.prior! - costsItem.prior! : nil
            return GrossProfitResult(
                grossProfit: gp,
                grossProfitPrior: gpPrior,
                grossProfitLabel: nil,
                method: "derived",
                accountingStandard: accountingStandard
            )
        }

        return GrossProfitResult(
            grossProfit: nil, grossProfitPrior: nil, grossProfitLabel: nil,
            method: "not_found", accountingStandard: accountingStandard
        )
    }

    private static func extractBankBusinessGrossProfit(fieldSet: FieldSet, accountingStandard: String) -> GrossProfitResult? {
        var currentTotal = 0.0
        var priorTotal = 0.0
        var hasCurrentAny = false
        var hasPriorAny = false

        for comp in Xbrl.businessGrossProfitComponents {
            let item = resolveItem(fieldSet, tags: comp.tags)
            if let c = item.current {
                currentTotal += Double(comp.sign) * c
                hasCurrentAny = true
            }
            if let p = item.prior {
                priorTotal += Double(comp.sign) * p
                hasPriorAny = true
            }
        }

        guard hasCurrentAny || hasPriorAny else { return nil }

        return GrossProfitResult(
            grossProfit: hasCurrentAny ? currentTotal : nil,
            grossProfitPrior: hasPriorAny ? priorTotal : nil,
            grossProfitLabel: "連結業務粗利益",
            method: "business_gross_profit",
            accountingStandard: accountingStandard
        )
    }
}

// MARK: - Operating Profit Extractor

enum OperatingProfitExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> OperatingProfitResult {
        // US-GAAP 企業: HTML 仮想タグ（USGAAPHtml.parsePLFields が注入）を使用
        if accountingStandard == "US-GAAP" {
            let opItem = resolveItem(fieldSet, tags: ["USGAAP_HTML_OperatingIncome"])
            if opItem.current != nil || opItem.prior != nil {
                let sgaItem = resolveItem(fieldSet, tags: ["USGAAP_HTML_SGA"])
                return OperatingProfitResult(
                    operatingProfit: opItem.current,
                    operatingProfitPrior: opItem.prior,
                    sga: sgaItem.current,
                    sgaPrior: sgaItem.current != nil ? sgaItem.prior : nil,
                    label: "営業利益",
                    method: "usgaap_html",
                    accountingStandard: "US-GAAP"
                )
            }
            return OperatingProfitResult(
                operatingProfit: nil, operatingProfitPrior: nil,
                sga: nil, sgaPrior: nil,
                label: "営業利益", method: "not_found", accountingStandard: "US-GAAP"
            )
        }

        var opItem = resolveItemPreferCurrent(fieldSet, tags: Xbrl.operatingProfitDirectTags)
        var label = "営業利益"
        var method = "direct"

        if opItem.current == nil && opItem.prior == nil {
            // 経常利益フォールバック（金融機関等）
            opItem = resolveItemPreferCurrent(fieldSet, tags: Xbrl.ordinaryIncomeTags)
            if opItem.current != nil || opItem.prior != nil {
                label = "経常利益"
                method = "ordinary_income"
            }
        }

        // SGA
        var sgaItem = resolveItem(fieldSet, tags: Xbrl.sgaDirectTags)
        if sgaItem.current == nil {
            // 販売費 + 一般管理費で積み上げ
            let sell = resolveItem(fieldSet, tags: Xbrl.sgaSellingIFRSTags)
            let ga = resolveItem(fieldSet, tags: Xbrl.sgaGaIFRSTags)
            if sell.current != nil || ga.current != nil {
                let c: Double? = (sell.current ?? 0) + (ga.current ?? 0) > 0
                    ? (sell.current ?? 0) + (ga.current ?? 0) : nil
                let p: Double? = (sell.prior != nil || ga.prior != nil)
                    ? (sell.prior ?? 0) + (ga.prior ?? 0) : nil
                sgaItem = ResolvedItem(tag: "sell+ga", current: c, prior: p)
            }
        }

        if opItem.current == nil && opItem.prior == nil {
            method = "not_found"
        }

        return OperatingProfitResult(
            operatingProfit: opItem.current,
            operatingProfitPrior: opItem.prior,
            sga: sgaItem.current,
            sgaPrior: sgaItem.prior,
            label: label,
            method: method,
            accountingStandard: accountingStandard
        )
    }
}

// MARK: - Interest Bearing Debt Extractor

enum IBDExtractor {

    // コンポーネント表示用ラベル（Python: COMPONENT_DEFINITIONS）
    private static let componentDefs: [(label: String, tags: [String])] = [
        ("短期借入金", ["ShortTermLoansPayable", "BorrowingsCLIFRS"]),
        ("コマーシャル・ペーパー", ["CommercialPapersLiabilities", "CommercialPapersCLIFRS"]),
        ("短期社債", ["ShortTermBondsPayable"]),
        ("1年内償還予定の社債", ["CurrentPortionOfBonds", "RedeemableBondsWithinOneYear",
                                 "BondsPayableCLIFRS", "CurrentPortionOfBondsCLIFRS"]),
        ("1年内返済予定の長期借入金", ["CurrentPortionOfLongTermLoansPayable",
                                      "CurrentPortionOfLongTermBorrowingsCLIFRS",
                                      "CurrentPortionOfLongTermDebtCLIFRS"]),
        ("リース負債（流動）", ["LeaseObligationsCL", "LeaseLiabilitiesCLIFRS"]),
        ("社債", ["BondsPayable", "BondsPayableNCLIFRS"]),
        ("長期借入金", ["LongTermLoansPayable", "BorrowingsNCLIFRS", "LongTermDebtNCLIFRS"]),
        ("リース負債（非流動）", ["LeaseObligationsNCL", "LeaseLiabilitiesNCLIFRS"]),
    ]

    private static let tagToLabel: [String: String] = {
        var map: [String: String] = [:]
        for (label, tags) in componentDefs {
            for tag in tags { map[tag] = label }
        }
        return map
    }()

    static func extract(fieldSet: FieldSet, accountingStandard: String, xbrlDir: URL? = nil) -> IBDResult {
        // 銀行業: DepositsLiabilitiesBNK が存在すれば銀行業コンポーネント積み上げ
        if let bankResult = extractBankIBD(fieldSet: fieldSet, accountingStandard: accountingStandard) {
            return bankResult
        }

        let resolved = resolveIBD(fieldSet)
        var result: IBDResult

        if let tag = resolved.tag {
            let components: [IBDComponentEntry] = tag.split(separator: "+").map { t in
                let tagName = String(t)
                let fv = fieldSet[tagName]
                return (label: tagToLabel[tagName] ?? tagName,
                        current: fv?.current, prior: fv?.prior)
            }
            result = IBDResult(
                total: resolved.current,
                priorTotal: resolved.prior,
                components: components,
                method: "field_parser",
                accountingStandard: accountingStandard
            )
        } else if accountingStandard == "IFRS",
                  let dir = xbrlDir,
                  let textblockResult = IFRSLease.extractIBDFromTextblock(xbrlDir: dir) {
            // IFRS Summary型XBRLでは連結借入金タグが存在しないため、TextBlockから抽出する
            result = textblockResult
        } else if let dir = xbrlDir, hasLargeXbrlFile(in: dir) {
            // インスタンス文書が十分大きいのにIBDタグが皆無 → 無借金企業とみなす
            result = IBDResult(total: 0.0, priorTotal: 0.0, components: [],
                               method: "zero_debt", accountingStandard: accountingStandard)
            if accountingStandard != "IFRS" { return result }
        } else {
            return IBDResult(total: nil, priorTotal: nil, components: [],
                             method: "not_found", accountingStandard: accountingStandard)
        }

        // IFRS適用企業: リース負債を追加（XBRLタグで既に取得済みの場合はスキップ）
        if accountingStandard == "IFRS" {
            let resolvedTags = Set((resolved.tag ?? "").split(separator: "+").map(String.init))
            if !resolvedTags.isDisjoint(with: IFRSLease.leaseXbrlTags) {
                return result
            }
            let lease = IFRSLease.extractLeaseLiabilities(fieldSet: fieldSet, xbrlDir: xbrlDir)
            if lease.current != nil || lease.prior != nil {
                result = IBDResult(
                    total: (result.total ?? 0) + (lease.current ?? 0),
                    priorTotal: (result.priorTotal ?? 0) + (lease.prior ?? 0),
                    components: result.components + lease.components,
                    method: result.method + "+lease_textblock",
                    accountingStandard: accountingStandard
                )
            }
        }

        // US-GAAP適用企業: オペレーティング・リース負債を追加（ASC 842）
        if accountingStandard == "US-GAAP" {
            let lease = extractUSGAAPLeaseLiabilities(fieldSet: fieldSet)
            if let leaseC = lease.current {
                result = IBDResult(
                    total: (result.total ?? 0) + leaseC,
                    priorTotal: lease.prior != nil
                        ? (result.priorTotal ?? 0) + lease.prior! : result.priorTotal,
                    components: result.components + lease.components,
                    method: result.method + "+lease_html",
                    accountingStandard: accountingStandard
                )
            }
        }

        return result
    }

    /// 解決順: 直接法 → IFRS集約タグ → コンポーネント積み上げ → US-GAAP HTML仮想タグ。
    private static func resolveIBD(_ fieldSet: FieldSet) -> ResolvedItem {
        let direct = resolveItem(fieldSet, tags: Xbrl.ibdDirectTags)
        if direct.tag != nil { return direct }

        let ifrsAgg = resolveAggregate(fieldSet, componentTagLists: [Xbrl.ibdIFRSCLTags, Xbrl.ibdIFRSNCLTags])
        if ifrsAgg.tag != nil { return ifrsAgg }

        let comp = resolveAggregate(fieldSet, componentTagLists: Xbrl.ibdCurrentComponents + Xbrl.ibdNonCurrentComponents)
        if comp.tag != nil { return comp }

        return resolveAggregate(fieldSet, componentTagLists: [["USGAAP_HTML_IBDCurrent"], ["USGAAP_HTML_IBDNonCurrent"]])
    }

    /// US-GAAP BS HTMLから取得済みのオペレーティング・リース負債残高を返す（ASC 842）。
    private static func extractUSGAAPLeaseLiabilities(
        fieldSet: FieldSet
    ) -> (current: Double?, prior: Double?, components: [IBDComponentEntry]) {
        let clFV = resolveItem(fieldSet, tags: ["USGAAP_HTML_LeaseLiabilitiesCurrent"])
        let nclFV = resolveItem(fieldSet, tags: ["USGAAP_HTML_LeaseLiabilitiesNonCurrent"])
        guard clFV.current != nil || nclFV.current != nil else { return (nil, nil, []) }

        let totalC = (clFV.current ?? 0) + (nclFV.current ?? 0)
        let hasP = clFV.prior != nil || nclFV.prior != nil
        let totalP: Double? = hasP ? (clFV.prior ?? 0) + (nclFV.prior ?? 0) : nil
        var components: [IBDComponentEntry] = []
        if clFV.current != nil {
            components.append((label: "リース負債（流動）", current: clFV.current, prior: clFV.prior))
        }
        if nclFV.current != nil {
            components.append((label: "リース負債（非流動）", current: nclFV.current, prior: nclFV.prior))
        }
        return (totalC, totalP, components)
    }

    /// インスタンス文書に 100KB 超のファイルがあるか（zero_debt 判定）。
    private static func hasLargeXbrlFile(in dir: URL) -> Bool {
        XBRLUtils.findXbrlFiles(in: dir).contains { url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return (size ?? 0) > 100_000
        }
    }

    private static func extractBankIBD(fieldSet: FieldSet, accountingStandard: String) -> IBDResult? {
        let marker = resolveItem(fieldSet, tags: ["DepositsLiabilitiesBNK"])
        guard marker.current != nil || marker.prior != nil else { return nil }

        var totalCurrent = 0.0
        var totalPrior = 0.0
        var hasCurrentAny = false
        var hasPriorAny = false
        var components: [(label: String, current: Double?, prior: Double?)] = []

        for comp in Xbrl.bankIBDComponents {
            let item = resolveItem(fieldSet, tags: comp.tags)
            if let c = item.current { totalCurrent += c; hasCurrentAny = true }
            if let p = item.prior { totalPrior += p; hasPriorAny = true }
            if item.current != nil || item.prior != nil {
                components.append((label: comp.label, current: item.current, prior: item.prior))
            }
        }

        return IBDResult(
            total: hasCurrentAny ? totalCurrent : nil,
            priorTotal: hasPriorAny ? totalPrior : nil,
            components: components,
            method: "bank_components",
            accountingStandard: accountingStandard
        )
    }
}

// MARK: - Employees Extractor

enum EmployeesExtractor {

    static func extract(fieldSet: FieldSet, tagElements: XbrlTagElements) -> EmployeesResult {
        let item = resolveItem(fieldSet, tags: Xbrl.employeeTags)
        guard let tag = item.tag else {
            return EmployeesResult(current: nil, prior: nil, method: "not_found", scope: "unknown")
        }
        let ctxMap = tagElements[tag] ?? [:]
        let scope: String = ctxMap.keys.contains(where: {
            ContextHelpers.isConsolidatedInstant($0) || ContextHelpers.isConsolidatedPriorInstant($0)
        }) ? "consolidated" : "nonconsolidated"
        return EmployeesResult(current: item.current, prior: item.prior, method: "direct", scope: scope)
    }
}

// MARK: - Tax Expense Extractor

enum TaxExpenseExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> TaxExpenseResult {
        // US-GAAP 企業: HTML 仮想タグ（USGAAPHtml.parsePLFields が注入）を使用
        if accountingStandard == "US-GAAP" {
            let pretax = resolveItem(fieldSet, tags: ["USGAAP_HTML_PreTaxIncome"])
            var tax = resolveItem(fieldSet, tags: ["USGAAP_HTML_IncomeTax"])

            // 合計行がない場合は個別成分（法人税・調整額）で補完する
            if tax.current == nil {
                let taxC = resolveItem(fieldSet, tags: ["USGAAP_HTML_IncomeTaxCurrent"])
                let taxD = resolveItem(fieldSet, tags: ["USGAAP_HTML_IncomeTaxDeferred"])
                if taxC.current != nil || taxD.current != nil {
                    tax.current = (taxC.current ?? 0) + (taxD.current ?? 0)
                }
            }

            let rate: Double? = (pretax.current != nil && tax.current != nil && pretax.current != 0)
                ? tax.current! / pretax.current! : nil
            return TaxExpenseResult(
                pretaxIncome: pretax.current,
                incomeTax: tax.current,
                effectiveTaxRate: rate,
                accountingStandard: "US-GAAP"
            )
        }

        let pretaxItem: ResolvedItem
        let taxItem: ResolvedItem

        if accountingStandard == "IFRS" {
            pretaxItem = resolveItem(fieldSet, tags: Xbrl.pretaxIncomeIFRSTags)
            taxItem = resolveItem(fieldSet, tags: Xbrl.incomeTaxIFRSTags)
        } else {
            pretaxItem = resolveItem(fieldSet, tags: Xbrl.pretaxIncomeJGAAPTags)
            taxItem = resolveItem(fieldSet, tags: Xbrl.incomeTaxJGAAPTags)
        }

        let rate: Double?
        if let pt = pretaxItem.current, let tx = taxItem.current, pt != 0 {
            rate = tx / pt
        } else {
            rate = nil
        }

        return TaxExpenseResult(
            pretaxIncome: pretaxItem.current,
            incomeTax: taxItem.current,
            effectiveTaxRate: rate,
            accountingStandard: accountingStandard
        )
    }
}

// MARK: - Interest Expense Extractor

enum InterestExpenseExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String, xbrlDir: URL? = nil) -> InterestExpenseResult {
        // US-GAAP 企業: 連結損益計算書HTML(0105010)から直接解析
        if accountingStandard == "US-GAAP" {
            if let dir = xbrlDir, let fv = USGAAPHtml.extractInterestExpense(in: dir) {
                return InterestExpenseResult(
                    current: fv.current, prior: fv.prior,
                    method: "usgaap_html", accountingStandard: "US-GAAP"
                )
            }
            return InterestExpenseResult(
                current: nil, prior: nil,
                method: "not_found", accountingStandard: "US-GAAP"
            )
        }

        let tags = accountingStandard == "IFRS"
            ? Xbrl.interestExpenseIFRSTags
            : Xbrl.interestExpenseJGAAPTags
        let item = resolveItem(fieldSet, tags: tags)
        let method = item.tag != nil ? "direct" : "not_found"
        return InterestExpenseResult(
            current: item.current, prior: item.prior,
            method: method, accountingStandard: accountingStandard
        )
    }
}

// MARK: - Tangible Fixed Assets Extractor

enum TangibleFixedAssetsExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> TangibleFixedAssetsResult {
        let total: Double?
        switch accountingStandard {
        case "IFRS":
            // 直接タグ → 取得原価 + 減価償却累計（負値）のフォールバック
            if let direct = resolveItem(fieldSet, tags: Xbrl.ppeTotalIFRSDirectTags).current {
                total = direct
            } else if let cost = resolveItem(fieldSet, tags: Xbrl.ppeTotalCostTags).current {
                let dep = resolveItem(fieldSet, tags: Xbrl.ppeTotalDepTags).current ?? 0.0
                total = cost + dep
            } else {
                total = nil
            }
        case "J-GAAP":
            total = resolveItem(fieldSet, tags: Xbrl.ppeTotalJGAAPDirectTags).current
        default:
            total = resolveItem(fieldSet, tags: Xbrl.ppeTagsUSGAAPTotal).current
        }

        guard let t = total else {
            return TangibleFixedAssetsResult(total: nil, method: "not_found",
                                              accountingStandard: accountingStandard)
        }
        return TangibleFixedAssetsResult(total: t, method: "field_parser",
                                          accountingStandard: accountingStandard)
    }
}

// MARK: - Capex Extractor

enum CapexExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> CapexResult {
        // 設備投資等の概要タグを優先（正値）
        let overview = resolveItem(fieldSet, tags: Xbrl.capexOverviewTags)
        if let v = overview.current {
            return CapexResult(current: v, method: "overview")
        }
        // CF計算書フォールバック（負値を正値へ変換）
        let cfTags = accountingStandard == "IFRS" ? Xbrl.capexCFIFRSTags : Xbrl.capexCFJGAAPTags
        let item = resolveItem(fieldSet, tags: cfTags)
        if let v = item.current {
            return CapexResult(current: abs(v), method: "cf_investing")
        }
        let fallbackTags = accountingStandard == "IFRS" ? Xbrl.capexCFJGAAPTags : Xbrl.capexCFIFRSTags
        let fallback = resolveItem(fieldSet, tags: fallbackTags)
        if let v = fallback.current {
            return CapexResult(current: abs(v), method: "cf_investing_fallback")
        }
        return CapexResult(current: nil, method: "not_found")
    }
}

// MARK: - R&D Extractor

enum RDExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> RDResult {
        let commonItem = resolveItem(fieldSet, tags: Xbrl.rdExpenseCommonTags)
        if let v = commonItem.current { return RDResult(current: v, method: "common") }

        let specificTags = accountingStandard == "IFRS" ? Xbrl.rdExpenseIFRSTags : Xbrl.rdExpenseJGAAPTags
        let specificItem = resolveItem(fieldSet, tags: specificTags)
        if let v = specificItem.current { return RDResult(current: v, method: "specific") }

        return RDResult(current: nil, method: "not_found")
    }
}
