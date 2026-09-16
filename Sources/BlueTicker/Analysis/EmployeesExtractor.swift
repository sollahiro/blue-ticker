import Foundation
import SwiftSoup

struct EmployeesResult {
    var current: Double?
    var prior: Double?
    var method: String
    var scope: String
}

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
