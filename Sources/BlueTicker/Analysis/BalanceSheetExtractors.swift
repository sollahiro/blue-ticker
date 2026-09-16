import Foundation
import SwiftSoup

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

struct WorkingCapitalResult {
    var current: Double?
    var method: String
}

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
