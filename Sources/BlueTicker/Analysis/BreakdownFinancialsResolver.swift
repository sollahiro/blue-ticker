// financials 組立が読む breakdown 正本（employees / rd の分母）。
// ingest 順に依存せず、同一 XBRL パスで breakdown が分母に使う値を直接解決する（#10b）。
// PL の研究開発行や statement マスクは使わない。

import Foundation

enum BreakdownFinancialsResolver {

    /// business / geography 軸の売上分母。正本は statement PL の連結売上（`StatementFinancialsResolver`）。
    static func financialsCanonicalSales(xbrlDir: URL) -> Double? {
        StatementFinancialsResolver.resolve(xbrlDir: xbrlDir)?.sales
    }

    /// financials の `employees`。正本は breakdown `employees` 軸の分母。
    static func financialsCanonicalEmployees(xbrlDir: URL) -> Double? {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let instantFS = fieldSetFromInstant(allTags)
        return EmployeesExtractor.extract(fieldSet: instantFS, tagElements: allTags).current
    }

    /// financials の `rd`。正本は breakdown `research_and_development` 軸の分母。
    static func financialsCanonicalRd(xbrlDir: URL) -> Double? {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        return RDExtractor.extract(
            fieldSet: fieldSetFromDuration(allTags),
            accountingStandard: detectAccountingStandard(allTags)
        ).current
    }
}
