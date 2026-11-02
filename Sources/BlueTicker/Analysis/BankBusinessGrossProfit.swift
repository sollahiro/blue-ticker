// 銀行の連結業務粗利益。`Xbrl.businessGrossProfitComponents` の符号付き合算。
// GrossProfitExtractor と業種 KPI が同じ合計を使う。

import Foundation

enum BankBusinessGrossProfit {
    static func signedTotal(from fieldSet: FieldSet) -> (current: Double?, prior: Double?) {
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

        return (hasCurrentAny ? currentTotal : nil, hasPriorAny ? priorTotal : nil)
    }
}
