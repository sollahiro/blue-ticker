import Foundation
@testable import BlueTickerCore

/// Snapshot of tags the current extractors already treat as standard-field sources.
/// A fact whose local name is in this set is "mapped" and is not exported as a candidate.
enum PocJevMappedTags {
    static let canonicalRawKeys: [String] = [
        "sales", "gross_profit", "sga", "operating_profit", "net_profit",
        "interest_bearing_debt", "interest_expense",
        "total_assets", "current_assets", "non_current_assets", "ppe_total",
        "current_liabilities", "non_current_liabilities", "net_assets",
        "accounts_receivable", "inventory", "accounts_payable",
        "cash_equivalents", "cfo", "cfi", "capex", "buyback", "rd",
        "cf_treasury_stock", "dividend_ss", "dividend_paid_cf",
        "eps", "bps", "issued_shares", "employees",
    ]

    static let all: Set<String> = {
        var tags = Set<String>()
        func add(_ xs: [String]) { tags.formUnion(xs) }
        func addSet(_ xs: Set<String>) { tags.formUnion(xs) }
        func addGroups(_ groups: [[String]]) {
            for g in groups { tags.formUnion(g) }
        }

        add(Xbrl.operatingRevenueTags)
        add(Xbrl.ordinaryRevenueTags)
        add(Xbrl.netSalesTags)
        add(Xbrl.businessRevenueTags)
        add(Xbrl.operatingRevenueWithoutMerchandiseCogsTags)
        add(Xbrl.insuranceSalesTags)
        add(Xbrl.parentAttributableNetProfitTags)
        add(Xbrl.netProfitTags)
        add(Xbrl.basicEpsTags)
        add(Xbrl.dilutedEpsTags)
        add(Xbrl.netAssetsPerShareTags)
        add(Xbrl.equityPerShareUSGAAPTags)
        add(Xbrl.capitalStockTags)
        add(Xbrl.capitalReserveTags)
        add(Xbrl.ordinaryIncomeTags)
        add(Xbrl.operatingProfitDirectTags)
        add(Xbrl.sgaDirectTags)
        add(Xbrl.sgaSellingIFRSTags)
        add(Xbrl.sgaGaIFRSTags)
        add(Xbrl.insuranceSgaTags)
        add(Xbrl.grossProfitDirectTags)
        add(Xbrl.operatingGrossProfitDirectTags)
        add(Xbrl.operatingRevenueForOpexSgaGrossProfitTags)
        add(Xbrl.operatingExpenseTotalTags)
        add(Xbrl.grossProfitSalesTags)
        add(Xbrl.grossProfitCostsTags)
        add(Xbrl.cfOperatingTags)
        add(Xbrl.cfInvestingTags)
        add(Xbrl.ibdDirectTags)
        add(Xbrl.leaseLiabilitiesBSTags)
        add(Xbrl.propertyPlantEquipmentScheduleBSTags)
        add(Xbrl.ibdIFRSCLTags)
        add(Xbrl.ibdIFRSNCLTags)
        add(Xbrl.interestExpenseJGAAPTags)
        add(Xbrl.interestExpenseIFRSTags)
        add(Xbrl.pretaxIncomeJGAAPTags)
        add(Xbrl.pretaxIncomeIFRSTags)
        add(Xbrl.ppeTotalIFRSDirectTags)
        add(Xbrl.ppeTotalJGAAPDirectTags)
        add(Xbrl.ppeTagsUSGAAPTotal)
        add(Xbrl.ppeTotalCostTags)
        add(Xbrl.ppeTotalDepTags)
        add(Xbrl.employeeTags)
        add(Xbrl.rdExpenseCommonTags)
        add(Xbrl.rdExpenseJGAAPTags)
        add(Xbrl.rdExpenseIFRSTags)
        add(Xbrl.capexOverviewTags)
        add(Xbrl.capexCFJGAAPTags)
        add(Xbrl.capexCFIFRSTags)
        add(Xbrl.cashEquivalentsTags)
        add(Xbrl.netRevenueIFRSTags)
        add(Xbrl.businessProfitIFRSSRTags)
        add(Xbrl.shareBuybackSSJGAAPTags)
        add(Xbrl.shareBuybackCFJGAAPTags)
        add(Xbrl.shareBuybackSSIFRSTags)
        add(Xbrl.shareBuybackCFIFRSTags)
        add(Xbrl.dividendSSJGAAPTags)
        add(Xbrl.dividendSSIFRSTags)
        add(Xbrl.dividendPaidCFJGAAPTags)
        add(Xbrl.dividendPaidCFIFRSTags)
        add(Xbrl.accountsReceivableJGAAPTags)
        add(Xbrl.accountsReceivableIFRSTags)
        add(Xbrl.inventoryJGAAPTags)
        add(Xbrl.inventoryIFRSTags)
        addGroups(Xbrl.inventoryJGAAPComponents)
        add(Xbrl.accountsPayableJGAAPTags)
        add(Xbrl.accountsPayableIFRSTags)
        for item in Xbrl.allStandardBSItems {
            add(item.tags)
            if let d = item.deriveMinus {
                add(d.minuend)
                add(d.subtrahend)
            }
        }
        addGroups(Xbrl.ibdCurrentComponents)
        addGroups(Xbrl.ibdNonCurrentComponents)
        return tags
    }()
}
