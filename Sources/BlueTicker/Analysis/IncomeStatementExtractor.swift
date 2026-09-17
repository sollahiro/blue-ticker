import Foundation
import SwiftSoup

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

enum IncomeStatementExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> IncomeStatementResult {
        let salesItem = resolveItemPreferCurrent(fieldSet, tags: Xbrl.netSalesTags)
        // 保険は営業利益概念が無く、経常利益フォールバックも使わない（全年 null）。
        var opItem = ResolvedItem(tag: nil, current: nil, prior: nil)
        if !Xbrl.isInsuranceFiling(fieldSet) {
            opItem = resolveItemPreferCurrent(fieldSet, tags: Xbrl.operatingProfitDirectTags)
            if opItem.current == nil && opItem.prior == nil {
                opItem = resolveItemPreferCurrent(fieldSet, tags: Xbrl.ordinaryIncomeTags)
            }
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
        case "NetSalesIFRS", "TotalNetRevenuesIFRS", "RevenueIFRS",
            "RevenueIFRSSummaryOfBusinessResults", "Revenue":
            return "売上収益"
        case "Revenue2IFRS":
            return "収益"
        case "InsuranceRevenueIFRS":
            return "保険収益"
        case "NetSalesOfCompletedConstructionContractsCNS",
             "NetSalesOfCompletedConstructionContractsSummaryOfBusinessResults":
            return "完成工事高"
        case "BusinessRevenue":
            return "事業収益"
        default:
            return "売上高"
        }
    }
}
