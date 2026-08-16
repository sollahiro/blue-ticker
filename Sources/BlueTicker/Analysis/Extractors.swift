// XBRL 分析抽出器群

import Foundation
import SwiftSoup

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
    var method: String
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
    /// 採用した実タグ名（`current` が nil の場合も nil）。breakdown 側の denominatorTag 表示用。
    var tag: String?
}

struct NetRevenueResult {
    var netRevenue: Double?
    var businessProfit: Double?
    var found: Bool
}

struct ShareBuybackResult {
    var current: Double?
    var method: String
}

struct CfTreasuryStockResult {
    var current: Double?
    var method: String
}

struct DividendResult {
    var current: Double?
    var method: String
}

struct WorkingCapitalResult {
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

        // 直接法: GrossProfit タグ
        let directItem = resolveItem(fieldSet, tags: Xbrl.grossProfitDirectTags)
        if directItem.tag != nil {
            return GrossProfitResult(
                grossProfit: directItem.current,
                grossProfitPrior: directItem.prior,
                grossProfitLabel: nil,
                method: "direct",
                accountingStandard: accountingStandard
            )
        }

        // 銀行業: 連結業務粗利益を構成要素から積み上げ
        if let bankGP = extractBankBusinessGrossProfit(fieldSet: fieldSet, accountingStandard: accountingStandard) {
            return bankGP
        }

        // 営業総利益（倉庫・運輸等）
        let opGpItem = resolveItem(fieldSet, tags: Xbrl.operatingGrossProfitDirectTags)
        if opGpItem.tag != nil {
            return GrossProfitResult(
                grossProfit: opGpItem.current,
                grossProfitPrior: opGpItem.prior,
                grossProfitLabel: "営業総利益",
                method: "operating_gross_profit",
                accountingStandard: accountingStandard
            )
        }

        let salesItem = resolveItem(fieldSet, tags: Xbrl.grossProfitSalesTags)
        let costsItem = resolveItem(fieldSet, tags: Xbrl.grossProfitCostsTags)

        // IFRS Summary型: 売上原価タグが存在しない場合、TextBlockから粗利益を抽出する
        if accountingStandard == "IFRS", costsItem.tag == nil,
           let dir = xbrlDir,
           let textblockResult = extractIfrsGPFromTextblock(in: dir) {
            return textblockResult
        }

        // 計算法: 売上高 − 売上原価（売上原価タグがない場合は 0 扱い）
        if salesItem.tag != nil {
            let gpCurrent: Double? = salesItem.current.map { $0 - (costsItem.current ?? 0.0) }
            let gpPrior: Double? = salesItem.prior.map { $0 - (costsItem.prior ?? 0.0) }
            if gpCurrent != nil || gpPrior != nil {
                return GrossProfitResult(
                    grossProfit: gpCurrent,
                    grossProfitPrior: gpPrior,
                    grossProfitLabel: nil,
                    method: "computed",
                    accountingStandard: accountingStandard
                )
            }
        }

        return GrossProfitResult(
            grossProfit: nil, grossProfitPrior: nil, grossProfitLabel: nil,
            method: "not_found", accountingStandard: accountingStandard
        )
    }

    /// IFRS連結損益計算書TextBlockから売上総利益を抽出する。
    private static func extractIfrsGPFromTextblock(in xbrlDir: URL) -> GrossProfitResult? {
        let table = XBRLUtils.extractIfrsTextblockTable(
            in: xbrlDir,
            textblockTag: "ConsolidatedStatementOfIncomeIFRSTextBlock"
        )
        guard let gp = table["売上総利益"], gp.current != nil || gp.prior != nil else { return nil }
        return GrossProfitResult(
            grossProfit: gp.current.map { $0 * Financial.millionYen },
            grossProfitPrior: gp.prior.map { $0 * Financial.millionYen },
            grossProfitLabel: nil,
            method: "ifrs_textblock",
            accountingStandard: "IFRS"
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

        // 直接法: OPERATING_PROFIT_DIRECT_TAGS
        let opItem = resolveItem(fieldSet, tags: Xbrl.operatingProfitDirectTags)
        if opItem.tag != nil {
            let sga = resolveSGA(fieldSet)
            return OperatingProfitResult(
                operatingProfit: opItem.current,
                operatingProfitPrior: opItem.prior,
                sga: sga.current,
                sgaPrior: sga.prior,
                label: "営業利益",
                method: "direct",
                accountingStandard: accountingStandard
            )
        }

        // 計算法: GrossProfit − SGA（OperatingProfitLossIFRS が存在しない IFRS 企業向け）
        let computed = deriveSubtraction(
            fieldSet,
            minuendTags: Xbrl.grossProfitDirectTags,
            subtrahendTags: Xbrl.sgaDirectTags
        )
        if computed.current != nil || computed.prior != nil {
            let sga = resolveSGA(fieldSet)
            return OperatingProfitResult(
                operatingProfit: computed.current,
                operatingProfitPrior: computed.prior,
                sga: sga.current,
                sgaPrior: sga.prior,
                label: "営業利益",
                method: "computed",
                accountingStandard: accountingStandard
            )
        }

        // 経常利益フォールバック（J-GAAP 金融機関向け）
        // IFRS企業では連結コンテキストに経常利益タグが残存しても使わない。
        if accountingStandard != "IFRS" {
            let oiItem = resolveItem(fieldSet, tags: Xbrl.ordinaryIncomeTags)
            if oiItem.tag != nil {
                return OperatingProfitResult(
                    operatingProfit: oiItem.current,
                    operatingProfitPrior: oiItem.prior,
                    sga: nil,
                    sgaPrior: nil,
                    label: "経常利益",
                    method: "ordinary_income",
                    accountingStandard: accountingStandard
                )
            }
        }

        return OperatingProfitResult(
            operatingProfit: nil, operatingProfitPrior: nil,
            sga: nil, sgaPrior: nil,
            label: "営業利益", method: "not_found", accountingStandard: accountingStandard
        )
    }

    /// SGA を解決する。結合タグ優先、なければ販売費＋一般管理費を合算。
    private static func resolveSGA(_ fieldSet: FieldSet) -> (current: Double?, prior: Double?) {
        let combined = resolveItem(fieldSet, tags: Xbrl.sgaDirectTags)
        if combined.tag != nil { return (combined.current, combined.prior) }

        let selling = resolveItem(fieldSet, tags: Xbrl.sgaSellingIFRSTags)
        let ga = resolveItem(fieldSet, tags: Xbrl.sgaGaIFRSTags)
        guard selling.current != nil || ga.current != nil else { return (nil, nil) }
        let current = (selling.current ?? 0.0) + (ga.current ?? 0.0)
        let prior: Double? = (selling.prior != nil || ga.prior != nil)
            ? (selling.prior ?? 0.0) + (ga.prior ?? 0.0) : nil
        return (current, prior)
    }
}

// MARK: - Interest Bearing Debt Extractor

enum IBDExtractor {

    // コンポーネント表示用ラベル
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
        } else if let dir = xbrlDir,
                  let scheduleResult = BorrowingsSchedule.extract(xbrlDir: dir, accountingStandard: accountingStandard) {
            // 連結BSに有利子負債タグが無い企業（リース債務が明細表のみに記載される等）:
            // 連結附属明細表「借入金等明細表」から積み上げる。合計にはリース債務が含まれるため、
            // 後続のリース加算をスキップして即返す。
            return scheduleResult
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
            return size > Xbrl.zeroDebtMinInstanceBytes
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

            guard pretax.current != nil || tax.current != nil else {
                return TaxExpenseResult(
                    pretaxIncome: nil, incomeTax: nil, effectiveTaxRate: nil,
                    accountingStandard: "US-GAAP", method: "not_found"
                )
            }
            let rate: Double? = (pretax.current != nil && tax.current != nil && pretax.current != 0)
                ? tax.current! / pretax.current! : nil
            return TaxExpenseResult(
                pretaxIncome: pretax.current,
                incomeTax: tax.current,
                effectiveTaxRate: rate,
                accountingStandard: "US-GAAP",
                method: "usgaap_html"
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

        guard pretaxItem.tag != nil || taxItem.tag != nil else {
            return TaxExpenseResult(
                pretaxIncome: nil, incomeTax: nil, effectiveTaxRate: nil,
                accountingStandard: accountingStandard, method: "not_found"
            )
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
            accountingStandard: accountingStandard,
            method: "computed"
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
        if item.tag != nil {
            return InterestExpenseResult(
                current: item.current, prior: item.prior,
                method: "direct", accountingStandard: accountingStandard
            )
        }

        // IFRS注記の文章中に支払利息が出るケース（トヨタ型）を拾う
        if let dir = xbrlDir, let textblock = extractIfrsIEFromTextblock(in: dir) {
            return textblock
        }

        return InterestExpenseResult(
            current: nil, prior: nil,
            method: "not_found", accountingStandard: accountingStandard
        )
    }

    /// IFRS注記テキストブロックから支払利息を抽出する。
    /// 「支払利息は、…それぞれ X百万円 および Y百万円」の文章パターン（前期・当期の順）。
    private static func extractIfrsIEFromTextblock(in xbrlDir: URL) -> InterestExpenseResult? {
        let pattern = try? NSRegularExpression(
            pattern: "支払利息は、.*?それぞれ\\s*([0-9,]+)百万円\\s*および\\s*([0-9,]+)百万円",
            options: [.dotMatchesLineSeparators]
        )
        guard let pattern = pattern,
              let enumerator = FileManager.default.enumerator(at: xbrlDir, includingPropertiesForKeys: nil)
        else { return nil }

        let candidates = enumerator.compactMap { $0 as? URL }
            .filter { ["htm", "html", "xbrl"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in candidates {
            guard let data = try? Data(contentsOf: file) else { continue }
            let content = String(decoding: data, as: UTF8.self)
            guard content.contains("支払利息"), content.contains("百万円") else { continue }

            let text = (try? SwiftSoup.parse(content).text()) ?? content
            guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let priorRange = Range(match.range(at: 1), in: text),
                  let currentRange = Range(match.range(at: 2), in: text),
                  let prior = Double(text[priorRange].replacingOccurrences(of: ",", with: "")),
                  let current = Double(text[currentRange].replacingOccurrences(of: ",", with: ""))
            else { continue }

            return InterestExpenseResult(
                current: current * Financial.millionYen,
                prior: prior * Financial.millionYen,
                method: "ifrs_textblock",
                accountingStandard: "IFRS"
            )
        }
        return nil
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
        if let v = commonItem.current { return RDResult(current: v, method: "common", tag: commonItem.tag) }

        let specificTags = accountingStandard == "IFRS" ? Xbrl.rdExpenseIFRSTags : Xbrl.rdExpenseJGAAPTags
        let specificItem = resolveItem(fieldSet, tags: specificTags)
        if let v = specificItem.current { return RDResult(current: v, method: "specific", tag: specificItem.tag) }

        return RDResult(current: nil, method: "not_found", tag: nil)
    }
}

// MARK: - Net Revenue Extractor（IFRS金融会社向け純収益フォールバック）

enum NetRevenueExtractor {

    static func extract(fieldSet: FieldSet) -> NetRevenueResult {
        let nrItem = resolveItem(fieldSet, tags: Xbrl.netRevenueIFRSTags)
        let bpItem = resolveItem(fieldSet, tags: Xbrl.businessProfitIFRSSRTags)
        let found = nrItem.current != nil || bpItem.current != nil
        return NetRevenueResult(netRevenue: nrItem.current, businessProfit: bpItem.current, found: found)
    }
}

// MARK: - Share Buyback Extractor

enum ShareBuybackExtractor {

    /// 自己株式取得額（正値、円単位）を抽出する。
    ///
    /// XBRL の SS・CF 値は負値（キャッシュアウトフロー）で報告されるため符号反転して返す。
    /// US-GAAP HTML 仮想タグはすでに正値のためそのまま返す。
    static func extract(
        fieldSet: FieldSet,
        ncFieldSet: FieldSet,
        equityAttributableFieldSet: FieldSet,
        accountingStandard: String
    ) -> ShareBuybackResult {
        if accountingStandard == "US-GAAP" {
            let item = resolveItem(fieldSet, tags: ["USGAAP_HTML_CFTreasuryStock"])
            if let v = item.current {
                return ShareBuybackResult(current: v, method: "usgaap_html")
            }
            let ncItem = resolveItem(ncFieldSet, tags: Xbrl.shareBuybackSSJGAAPTags)
            if ncItem.tag != nil, let v = ncItem.current {
                return ShareBuybackResult(current: -v, method: "ss_nonconsolidated")
            }
            return ShareBuybackResult(current: nil, method: "not_found")
        }

        let ssTags = accountingStandard == "J-GAAP" ? Xbrl.shareBuybackSSJGAAPTags : Xbrl.shareBuybackSSIFRSTags
        let cfTags = accountingStandard == "J-GAAP" ? Xbrl.shareBuybackCFJGAAPTags : Xbrl.shareBuybackCFIFRSTags

        // 1. 株主資本等変動計算書（IFRS は親会社帰属持分コンテキストを優先）
        let ssFieldSet = accountingStandard == "IFRS" ? equityAttributableFieldSet : fieldSet
        let ssItem = resolveItem(ssFieldSet, tags: ssTags)
        if ssItem.tag != nil, let v = ssItem.current {
            return ShareBuybackResult(current: -v, method: accountingStandard == "IFRS" ? "ss_equity_parent" : "ss_consolidated")
        }

        // 2. CF計算書・財務活動
        let cfItem = resolveItem(fieldSet, tags: cfTags)
        if cfItem.tag != nil {
            return ShareBuybackResult(current: cfItem.current.map { -$0 }, method: "cf_financing")
        }

        // 3. 株主資本等変動計算書・非連結（単独決算企業のフォールバック）
        let ncItem = resolveItem(ncFieldSet, tags: ssTags)
        if ncItem.tag != nil, let v = ncItem.current {
            return ShareBuybackResult(current: -v, method: "ss_nonconsolidated")
        }

        return ShareBuybackResult(current: nil, method: "not_found")
    }
}

// MARK: - CF Treasury Stock Extractor

enum CfTreasuryStockExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> CfTreasuryStockResult {
        if accountingStandard == "US-GAAP" {
            let item = resolveItem(fieldSet, tags: ["USGAAP_HTML_CFTreasuryStock"])
            if item.tag != nil {
                return CfTreasuryStockResult(current: item.current.map { -$0 }, method: "usgaap_html")
            }
            return CfTreasuryStockResult(current: nil, method: "not_found")
        }
        let cfTags = accountingStandard == "J-GAAP"
            ? Xbrl.shareBuybackCFJGAAPTags
            : Xbrl.shareBuybackCFIFRSTags
        let item = resolveItem(fieldSet, tags: cfTags)
        guard item.tag != nil else {
            return CfTreasuryStockResult(current: nil, method: "not_found")
        }
        return CfTreasuryStockResult(current: item.current.map { -$0 }, method: "cf_financing")
    }
}

// MARK: - Dividend SS Extractor

enum DividendSSExtractor {

    static func extract(
        fieldSet: FieldSet,
        ncFieldSet: FieldSet,
        equityAttributableFieldSet: FieldSet,
        accountingStandard: String
    ) -> DividendResult {
        if accountingStandard == "US-GAAP" {
            let item = resolveItem(fieldSet, tags: ["USGAAP_HTML_DividendSS"])
            if item.tag != nil {
                return DividendResult(current: item.current.map { -$0 }, method: "usgaap_html")
            }
            return DividendResult(current: nil, method: "not_found")
        }
        let ssTags = accountingStandard == "J-GAAP"
            ? Xbrl.dividendSSJGAAPTags
            : Xbrl.dividendSSIFRSTags

        // IFRS: 親会社帰属持分コンテキストを優先（NCI除外）
        if accountingStandard == "IFRS" {
            let item = resolveItem(equityAttributableFieldSet, tags: ssTags)
            if item.tag != nil {
                return DividendResult(current: item.current.map { -$0 }, method: "ss_equity_parent")
            }
        }

        let item = resolveItem(fieldSet, tags: ssTags)
        if item.tag != nil {
            return DividendResult(current: item.current.map { -$0 }, method: "ss_equity")
        }

        // 非連結フォールバック（単体決算企業用）
        let ncItem = resolveItem(ncFieldSet, tags: ssTags)
        if ncItem.tag != nil {
            return DividendResult(current: ncItem.current.map { -$0 }, method: "ss_nonconsolidated")
        }

        return DividendResult(current: nil, method: "not_found")
    }
}

// MARK: - Dividend Paid CF Extractor

enum DividendPaidExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> DividendResult {
        if accountingStandard == "US-GAAP" {
            let item = resolveItem(fieldSet, tags: ["USGAAP_HTML_DividendPaidCF"])
            if item.tag != nil {
                return DividendResult(current: item.current.map { -$0 }, method: "usgaap_html")
            }
            return DividendResult(current: nil, method: "not_found")
        }
        let cfTags = accountingStandard == "J-GAAP"
            ? Xbrl.dividendPaidCFJGAAPTags
            : Xbrl.dividendPaidCFIFRSTags
        let item = resolveItem(fieldSet, tags: cfTags)
        guard item.tag != nil else {
            return DividendResult(current: nil, method: "not_found")
        }
        return DividendResult(current: item.current.map { -$0 }, method: "cf_financing")
    }
}

// MARK: - Accounts Receivable Extractor

enum AccountsReceivableExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> WorkingCapitalResult {
        if accountingStandard == "US-GAAP" {
            let item = resolveItem(fieldSet, tags: ["USGAAP_HTML_AccountsReceivable"])
            return WorkingCapitalResult(current: item.current, method: item.tag != nil ? "usgaap_html" : "not_found")
        }
        let tags = accountingStandard == "IFRS"
            ? Xbrl.accountsReceivableIFRSTags
            : Xbrl.accountsReceivableJGAAPTags
        // 会計基準移行年は前期列が旧科目（prior のみ）になるため current 値を持つタグを優先する。
        // prior のみの先頭候補（旧科目）に引きずられて当期値を取りこぼすのを防ぐ。
        let item = resolveItemPreferCurrent(fieldSet, tags: tags)
        guard item.current != nil else {
            return WorkingCapitalResult(current: nil, method: "not_found")
        }
        return WorkingCapitalResult(current: item.current, method: "direct")
    }
}

// MARK: - Inventory Extractor

enum InventoryExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> WorkingCapitalResult {
        if accountingStandard == "US-GAAP" {
            let item = resolveItem(fieldSet, tags: ["USGAAP_HTML_Inventory"])
            return WorkingCapitalResult(current: item.current, method: item.tag != nil ? "usgaap_html" : "not_found")
        }
        let tags = accountingStandard == "IFRS"
            ? Xbrl.inventoryIFRSTags
            : Xbrl.inventoryJGAAPTags
        // current 値を持つタグを優先（移行年の prior のみ科目に引きずられない）。
        let item = resolveItemPreferCurrent(fieldSet, tags: tags)
        if item.current != nil {
            return WorkingCapitalResult(current: item.current, method: "direct")
        }
        if accountingStandard == "J-GAAP" {
            let agg = resolveAggregate(fieldSet, componentTagLists: Xbrl.inventoryJGAAPComponents)
            if agg.current != nil {
                return WorkingCapitalResult(current: agg.current, method: "aggregated")
            }
        }
        return WorkingCapitalResult(current: nil, method: "not_found")
    }
}

// MARK: - Accounts Payable Extractor

enum AccountsPayableExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> WorkingCapitalResult {
        if accountingStandard == "US-GAAP" {
            let item = resolveItem(fieldSet, tags: ["USGAAP_HTML_AccountsPayable"])
            return WorkingCapitalResult(current: item.current, method: item.tag != nil ? "usgaap_html" : "not_found")
        }
        let tags = accountingStandard == "IFRS"
            ? Xbrl.accountsPayableIFRSTags
            : Xbrl.accountsPayableJGAAPTags
        // 会計基準移行年は前期列が旧科目（prior のみ）になるため current 値を持つタグを優先する。
        let item = resolveItemPreferCurrent(fieldSet, tags: tags)
        guard item.current != nil else {
            return WorkingCapitalResult(current: nil, method: "not_found")
        }
        return WorkingCapitalResult(current: item.current, method: "direct")
    }
}

// MARK: - PerShareExtractor（基本EPS・発行済普通株式数）

struct PerShareResult {
    var eps: Double?           // 基本1株当たり当期利益（円・連結当期）
    var issuedShares: Double?  // 発行済普通株式数（期末残高・株）
}

enum PerShareExtractor {

    /// 基本EPS（連結当期）と発行済普通株式数（期末残高）を抽出する。
    /// eps は durationFS 経由で連結 CurrentYearDuration を解決する（本表→Summary の優先順は
    /// `Xbrl.basicEpsTags`）。issuedShares は文脈・株式クラスの指定が要るため tagElements を直接参照する。
    static func extract(durationFS: FieldSet, tagElements: XbrlTagElements) -> PerShareResult {
        let eps = resolveItem(durationFS, tags: Xbrl.basicEpsTags).current
        return PerShareResult(eps: eps, issuedShares: issuedCommonSharesFYEnd(tagElements))
    }

    /// 発行済普通株式数（期末残高）。
    /// 1) 【株式の総数】表の普通株式（OrdinaryShareMember）→ 単一クラス企業の base 文脈
    /// 2) 主要な経営指標等の推移の期末発行済株式総数（CurrentYearInstant）
    private static func issuedCommonSharesFYEnd(_ el: XbrlTagElements) -> Double? {
        if let ctxs = el[Xbrl.issuedSharesFYEndTag] {
            if let v = firstContextValue(ctxs, containing: Xbrl.ordinaryShareMemberSuffix) { return v }
            if let v = ctxs[Xbrl.filingDateInstantContext] { return v }
        }
        if let ctxs = el[Xbrl.issuedSharesSummaryTag],
           let v = firstContextValue(ctxs, containing: Xbrl.currentYearInstantContext) {
            return v
        }
        return nil
    }

    /// contextRef に substring を含む最初の値を返す（辞書順で決定的に選ぶ）。
    private static func firstContextValue(_ ctxs: [String: Double], containing needle: String) -> Double? {
        for key in ctxs.keys.sorted() where key.contains(needle) {
            return ctxs[key]
        }
        return nil
    }
}
