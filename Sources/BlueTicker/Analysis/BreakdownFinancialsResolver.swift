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
    /// Summary の `sales` と一致させる。本表に売上相当行が無い会社では nil（三菱商事の `Revenue2IFRS`「収益」は
    /// `netSalesTags` 外のため Summary は null のまま）。
    static func financialsCanonicalSales(xbrlDir: URL) -> Double? {
        StatementFinancialsResolver.resolve(xbrlDir: xbrlDir)?.sales
    }

    /// business 軸の売上分母。`breakdownBusinessSalesDenominatorItem` の値だけ。
    static func breakdownBusinessSalesDenominator(xbrlDir: URL) -> Double? {
        breakdownBusinessSalesDenominatorItem(xbrlDir: xbrlDir).value
    }

    /// business 軸の分母と由来タグ。Summary sales があれば `income_statement.sales`。
    /// 無ければ収益認識表の「顧客との契約」連結金額（`llm_table_subtotal`）、さらに無ければ
    /// 未マスク FieldSet の売上相当タグ（`RevenueIFRSSummaryOfBusinessResults` 等）。
    /// 偽の `income_statement.sales` は出さない。geography / Summary は変えない。
    /// `tables` を渡すと `extractSegmentInfo` の再走査を避ける（ingest 経路）。
    static func breakdownBusinessSalesDenominatorItem(
        xbrlDir: URL, tables: [BreakdownTable]? = nil
    ) -> CanonicalValue {
        if let sales = financialsCanonicalSales(xbrlDir: xbrlDir), sales != 0 {
            return CanonicalValue(value: sales, tag: "income_statement.sales")
        }
        let rrTables = tables ?? BreakdownExtractor.extractSegmentInfo(xbrlDir: xbrlDir).tables
        if let yen = BreakdownExtractor.customerContractConsolidatedYen(tables: rrTables) {
            return CanonicalValue(value: yen, tag: "llm_table_subtotal")
        }
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let salesItem = resolveItemPreferCurrent(
            fieldSetFromDuration(allTags), tags: Xbrl.netSalesTags)
        guard let sales = salesItem.current, sales != 0 else {
            return CanonicalValue(value: nil, tag: nil)
        }
        return CanonicalValue(value: sales, tag: salesItem.tag)
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

    /// breakdown `capital_expenditures_overview` の会社全体総額。CF fallbackは使わず、
    /// Overviewタグだけを解決する（セグメントdimensionが無い企業のdenominator-only用）。
    static func breakdownCanonicalCapexOverviewItem(xbrlDir: URL) -> CanonicalValue {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let item = resolveItem(
            fieldSetFromDuration(allTags), tags: Xbrl.capexOverviewTags)
        return CanonicalValue(value: item.current, tag: item.tag)
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
