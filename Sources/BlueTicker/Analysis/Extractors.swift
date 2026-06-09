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
            // US-GAAP 非流動資産: XBRL 積み上げフォールバック
            if item.field == "NonCurrentAssets" && resolved.current == nil {
                resolved = resolveAggregate(fieldSet, componentTagLists: Xbrl.usgaapXbrlNCAComponents)
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

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> GrossProfitResult {
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
}

// MARK: - Operating Profit Extractor

enum OperatingProfitExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> OperatingProfitResult {
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

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> IBDResult {
        // 直接タグ
        let directItem = resolveItem(fieldSet, tags: Xbrl.ibdDirectTags)
        if let total = directItem.current {
            return IBDResult(total: total, priorTotal: directItem.prior,
                             components: [], method: "direct",
                             accountingStandard: accountingStandard)
        }

        // IFRS 集約タグ（流動 + 非流動）
        if accountingStandard == "IFRS" {
            let clItem = resolveItem(fieldSet, tags: Xbrl.ibdIFRSCLTags)
            let nclItem = resolveItem(fieldSet, tags: Xbrl.ibdIFRSNCLTags)
            if clItem.current != nil || nclItem.current != nil {
                let total = (clItem.current ?? 0) + (nclItem.current ?? 0)
                let prior: Double? = (clItem.prior != nil || nclItem.prior != nil)
                    ? (clItem.prior ?? 0) + (nclItem.prior ?? 0) : nil
                return IBDResult(total: total, priorTotal: prior,
                                 components: [], method: "ifrs_aggregate",
                                 accountingStandard: accountingStandard)
            }
        }

        // コンポーネント積み上げ（流動 + 非流動）
        var totalCurrent = 0.0
        var totalPrior = 0.0
        var currentFound = false
        var priorFound = false
        var components: [(label: String, current: Double?, prior: Double?)] = []

        let componentDefs: [(label: String, tags: [String])] = [
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

        for (label, tags) in componentDefs {
            let item = resolveItem(fieldSet, tags: tags)
            if item.current != nil || item.prior != nil {
                components.append((label: label, current: item.current, prior: item.prior))
                if let c = item.current { totalCurrent += c; currentFound = true }
                if let p = item.prior { totalPrior += p; priorFound = true }
            }
        }

        if currentFound {
            return IBDResult(
                total: totalCurrent,
                priorTotal: priorFound ? totalPrior : nil,
                components: components,
                method: "components",
                accountingStandard: accountingStandard
            )
        }

        return IBDResult(total: nil, priorTotal: nil, components: [],
                         method: "not_found", accountingStandard: accountingStandard)
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

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> InterestExpenseResult {
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
        // 直接タグ
        let directItem = resolveItem(fieldSet, tags: Xbrl.ppeTotalTags)
        if let v = directItem.current {
            return TangibleFixedAssetsResult(total: v, method: "direct",
                                              accountingStandard: accountingStandard)
        }

        // IFRS: 取得原価 - 累計減価償却
        let costItem = resolveItem(fieldSet, tags: Xbrl.ppeTotalCostTags)
        let depItem = resolveItem(fieldSet, tags: Xbrl.ppeTotalDepTags)
        if let c = costItem.current, let d = depItem.current {
            return TangibleFixedAssetsResult(total: c - d, method: "cost_minus_dep",
                                              accountingStandard: accountingStandard)
        }

        return TangibleFixedAssetsResult(total: nil, method: "not_found",
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
