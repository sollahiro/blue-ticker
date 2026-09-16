import Foundation
import SwiftSoup

struct RDResult {
    var current: Double?
    var method: String
    /// 採用した実タグ名（`current` が nil の場合も nil）。breakdown 側の denominatorTag 表示用。
    var tag: String?
}

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
