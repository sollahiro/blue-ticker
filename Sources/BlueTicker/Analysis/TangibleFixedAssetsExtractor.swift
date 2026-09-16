import Foundation
import SwiftSoup

struct TangibleFixedAssetsResult {
    var total: Double?
    var method: String
    var accountingStandard: String
}

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
