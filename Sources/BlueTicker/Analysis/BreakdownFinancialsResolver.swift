// financials 組立が読む breakdown 正本（employees / rd の分母）。
// ingest 順に依存せず、同一 XBRL パスで breakdown が分母に使う値を直接解決する（#10b）。
// PL の研究開発行や statement マスクは使わない。

import Foundation

enum BreakdownFinancialsResolver {
    struct CanonicalValue {
        let value: Double?
        let tag: String?
    }

    /// geography 軸と Summary の売上分母。正本は statement PL の連結売上（`StatementFinancialsResolver`）。
    /// 三菱商事等の本表 `Revenue2IFRS`「収益」も含む。product_service 軸は
    /// `breakdownBusinessSalesDenominatorItem`（収益認識表なら顧客契約）。
    static func financialsCanonicalSales(xbrlDir: URL) -> Double? {
        StatementFinancialsResolver.resolve(xbrlDir: xbrlDir)?.sales
    }

    /// product_service 軸の売上分母。`breakdownBusinessSalesDenominatorItem` の値だけ。
    static func breakdownBusinessSalesDenominator(xbrlDir: URL) -> Double? {
        breakdownBusinessSalesDenominatorItem(xbrlDir: xbrlDir).value
    }

    /// product_service 軸の分母と由来タグ。収益認識へ swap した表は顧客契約連結（`llm_table_subtotal`）。
    /// 三菱商事: セグメント表が顧客契約ベース。PL「収益」はその他源泉込みで Summary とは分母が違う。
    /// 報告セグメント表のままなら Summary sales（`income_statement.sales`）。無ければ顧客契約、
    /// さらに無ければ未マスク FieldSet の売上相当タグ。偽の `income_statement.sales` は出さない。
    /// `tables` を渡すと `extractSegmentInfo` の再走査を避ける（ingest 経路）。
    static func breakdownBusinessSalesDenominatorItem(
        xbrlDir: URL, tables: [BreakdownTable]? = nil
    ) -> CanonicalValue {
        let sales = financialsCanonicalSales(xbrlDir: xbrlDir)
        let rrTables = tables ?? BreakdownExtractor.extractSegmentInfo(xbrlDir: xbrlDir).tables
        if rrTables.contains(where: {
            $0.heading == BreakdownExtractor.revenueRecognitionHeading
        }), let yen = BreakdownExtractor.customerContractConsolidatedYen(tables: rrTables), yen != 0
        {
            return CanonicalValue(value: yen, tag: "llm_table_subtotal")
        }
        if let sales, sales != 0 {
            return CanonicalValue(value: sales, tag: "income_statement.sales")
        }
        if let yen = BreakdownExtractor.customerContractConsolidatedYen(tables: rrTables) {
            return CanonicalValue(value: yen, tag: "llm_table_subtotal")
        }
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let salesItem = resolveNetSales(fieldSetFromDuration(allTags))
        guard let unmasked = salesItem.current, unmasked != 0 else {
            return CanonicalValue(value: nil, tag: nil)
        }
        return CanonicalValue(value: unmasked, tag: salesItem.tag)
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
    /// 活動タグの全社合計が無く販管費タグに落ち、研究開発活動の本文総額が
    /// 製造費用込みの注記と一致するときは、その注記を分母にする。
    static func financialsCanonicalRdItem(xbrlDir: URL) -> CanonicalValue {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let fieldSet = fieldSetFromDuration(allTags)
        let result = RDExtractor.extract(
            fieldSet: fieldSet,
            accountingStandard: detectAccountingStandard(allTags)
        )
        let noteTag = Xbrl.rdExpenseIncludedInGaAndManufacturingCostTag
        if let text = ResearchAndDevelopmentProseTotalDecision.activityPlainText(in: xbrlDir),
            ResearchAndDevelopmentProseTotalDecision.confirmsManufacturingNote(
                extractedTag: result.tag, extractedYen: result.current,
                noteYen: fieldSet[noteTag]?.current, plainText: text)
        {
            return CanonicalValue(value: fieldSet[noteTag]?.current, tag: noteTag)
        }
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
