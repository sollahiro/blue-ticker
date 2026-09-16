import Foundation
import SwiftSoup

struct NetRevenueResult {
    var netRevenue: Double?
    var businessProfit: Double?
    var found: Bool
}

enum NetRevenueExtractor {

    static func extract(fieldSet: FieldSet) -> NetRevenueResult {
        let nrItem = resolveItem(fieldSet, tags: Xbrl.netRevenueIFRSTags)
        let bpItem = resolveItem(fieldSet, tags: Xbrl.businessProfitIFRSSRTags)
        let found = nrItem.current != nil || bpItem.current != nil
        return NetRevenueResult(netRevenue: nrItem.current, businessProfit: bpItem.current, found: found)
    }
}
