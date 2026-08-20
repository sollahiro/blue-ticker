// financials 組立が読む breakdown 正本（employees / rd の分母）。
// ingest 順に依存せず、同一 XBRL パスで breakdown が分母に使う値を直接解決する（#10b）。
// PL の研究開発行や statement マスクは使わない。

import Foundation

enum BreakdownFinancialsResolver {
    struct CanonicalValue {
        let value: Double?
        let tag: String?
    }

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
        financialsCanonicalRdItem(xbrlDir: xbrlDir).value
    }

    /// financials の `rd` 分母と、その由来タグを返す。
    static func financialsCanonicalRdItem(xbrlDir: URL) -> CanonicalValue {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let result = RDExtractor.extract(
            fieldSet: fieldSetFromDuration(allTags),
            accountingStandard: detectAccountingStandard(allTags)
        )
        return CanonicalValue(value: result.current, tag: result.tag)
    }

    /// financials の `capex`。正本は breakdown の
    /// `capital_expenditures_overview` と同じ Overview XBRL タグ→CFタグフォールバック。
    /// company_breakdowns の格納順には依存せず、financials と breakdown が同じ低レベル
    /// XBRL解決経路を共有する。
    static func financialsCanonicalCapex(
        xbrlDir: URL, accountingStandard: String
    ) -> CanonicalValue {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let result = CapexExtractor.extract(
            fieldSet: fieldSetFromDuration(allTags), accountingStandard: accountingStandard)
        return CanonicalValue(value: result.current, tag: result.tag)
    }

    /// financials の `goodwill`。正本は breakdown `goodwill` 軸の分母。
    /// `Xbrl.goodwillSegmentTags` の無dimension fact から決定論で解決する。
    static func financialsCanonicalGoodwillItem(xbrlDir: URL) -> CanonicalValue {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let instantFS = fieldSetFromInstant(allTags)
        let item = resolveItem(instantFS, tags: Xbrl.goodwillSegmentTags)
        return CanonicalValue(value: item.current, tag: item.tag)
    }
}
