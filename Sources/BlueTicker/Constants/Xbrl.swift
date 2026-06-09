// XBRL コンテキストパターン・タグ定数
// Python の blue_ticker/constants/xbrl.py 相当

enum Xbrl {
    // Duration（損益計算書・CF）コンテキストパターン
    static let durationContextPatterns: [String] = [
        "CurrentYearDuration",
        "FilingDateDuration",
        "InterimDuration",
        "CurrentYTDDuration",
    ]

    static let priorDurationContextPatterns: [String] = [
        "Prior1YearDuration",
        "PriorYearDuration",
        "Prior1InterimDuration",
        "Prior1YTDDuration",
    ]

    // Instant（貸借対照表）コンテキストパターン
    static let instantContextPatterns: [String] = [
        "CurrentYearInstant",
        "CurrentQuarterInstant",
        "InterimInstant",
        "FilingDateInstant",
    ]

    static let priorInstantContextPatterns: [String] = [
        "Prior1YearInstant",
        "PriorYearInstant",
        "Prior1QuarterInstant",
        "Prior1InterimInstant",
    ]

    static let usgaapMarkerTags: [String] = [
        "TotalAssetsUSGAAPSummaryOfBusinessResults",
        "EquityAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults",
        "CashAndCashEquivalentsUSGAAPSummaryOfBusinessResults",
        "RevenuesUSGAAPSummaryOfBusinessResults",
        "NetIncomeLossAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults",
        "CashFlowsFromUsedInOperatingActivitiesUSGAAPSummaryOfBusinessResults",
        "CashFlowsFromUsedInInvestingActivitiesUSGAAPSummaryOfBusinessResults",
    ]

    static let ifrsBalanceSheetMarkerTags: [String] = [
        "InterestBearingLiabilitiesCLIFRS",
        "InterestBearingLiabilitiesNCLIFRS",
        "BorrowingsCLIFRS",
        "BondsPayableNCLIFRS",
        "BorrowingsNCLIFRS",
        "BondsAndBorrowingsCLIFRS",
        "BondsAndBorrowingsNCLIFRS",
        "BondsBorrowingsAndLeaseLiabilitiesCLIFRS",
        "BondsBorrowingsAndLeaseLiabilitiesNCLIFRS",
    ]

    static let ifrsPLMarkerTags: [String] = [
        "InterestBearingLiabilitiesCLIFRS",
        "BorrowingsCLIFRS",
        "BondsPayableNCLIFRS",
        "BorrowingsNCLIFRS",
        "NetSalesIFRS",
        "RevenueIFRS",
        "GrossProfitIFRS",
        "SellingGeneralAndAdministrativeExpensesIFRS",
        "OperatingProfitLossIFRS",
        "OperatingRevenuesIFRSKeyFinancialData",
        "ProfitLossAttributableToOwnersOfParentIFRS",
        "ProfitLossAttributableToOwnersOfParentIFRSSummaryOfBusinessResults",
        "CashFlowsFromUsedInOperatingActivitiesIFRSSummaryOfBusinessResults",
        "CashFlowsFromUsedInInvestingActivitiesIFRSSummaryOfBusinessResults",
    ]
}

// XBRL セクション定義（filing コマンドで使用）
struct XBRLSectionDef {
    let title: String
    let xbrlElements: [String]
}

let xbrlSections: [String: XBRLSectionDef] = [
    "business_risks": XBRLSectionDef(
        title: "事業等のリスク",
        xbrlElements: ["BusinessRisksTextBlock"]
    ),
    "mda": XBRLSectionDef(
        title: "経営者による財政状態、経営成績及びキャッシュ・フローの状況の分析",
        xbrlElements: ["ManagementAnalysisOfFinancialPositionOperatingResultsAndCashFlowsTextBlock"]
    ),
    "capex_overview": XBRLSectionDef(
        title: "設備投資等の概要",
        xbrlElements: ["OverviewOfCapitalExpendituresEtcOwnUsedAssetsLEATextBlock"]
    ),
    "major_facilities": XBRLSectionDef(
        title: "主要な設備の状況",
        xbrlElements: ["MajorFacilitiesTextBlock"]
    ),
    "facility_plans": XBRLSectionDef(
        title: "設備の新設、除却等の計画",
        xbrlElements: ["PlannedAdditionsRetirementsEtcOfFacilitiesTextBlock"]
    ),
    "research_and_development": XBRLSectionDef(
        title: "研究開発活動",
        xbrlElements: ["ResearchAndDevelopmentActivitiesTextBlock"]
    ),
]
