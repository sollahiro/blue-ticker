import Foundation
import SwiftSoup

struct TaxExpenseResult {
    var pretaxIncome: Double?
    var incomeTax: Double?
    var effectiveTaxRate: Double?
    var accountingStandard: String
    var method: String
}

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
