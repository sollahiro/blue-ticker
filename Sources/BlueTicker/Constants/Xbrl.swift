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

    // MARK: - 売上高タグ

    static let operatingRevenueTags: [String] = [
        "OperatingRevenue1",
        "OperatingRevenue1SummaryOfBusinessResults",
    ]

    static let ordinaryRevenueTags: [String] = [
        "OrdinaryIncomeBNK",
        "OrdinaryIncomeSummaryOfBusinessResults",
    ]

    static let netSalesTags: [String] = [
        "NetSalesIFRS",
        "RevenueIFRS",
        "RevenueIFRSSummaryOfBusinessResults",
        "RevenueJMISSummaryOfBusinessResults",
        "Revenue",
        "OperatingRevenuesIFRSKeyFinancialData",
        "OperatingRevenuesIFRSSummaryOfBusinessResults",
        "Revenues",
        "RevenuesUSGAAPSummaryOfBusinessResults",
        "NetSales",
        "NetSalesSummaryOfBusinessResults",
        "NetSalesOfCompletedConstructionContractsCNS",
        "NetSalesOfCompletedConstructionContractsSummaryOfBusinessResults",
        "OperatingRevenue1",
        "OperatingRevenue1SummaryOfBusinessResults",
        "OrdinaryIncomeBNK",
        "OrdinaryIncomeSummaryOfBusinessResults",
    ]

    // MARK: - 当期純利益タグ

    static let netProfitTags: [String] = [
        "ProfitLossAttributableToOwnersOfParentIFRS",
        "ProfitLossAttributableToOwnersOfParentIFRSSummaryOfBusinessResults",
        "ProfitLossAttributableToOwnersOfParentJMISSummaryOfBusinessResults",
        "NetIncomeLossAttributableToOwnersOfParentUSGAAP",
        "NetIncomeLossAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults",
        "NetIncomeLoss",
        "ProfitLossAttributableToOwnersOfParent",
        "ProfitLoss",
        "NetIncomeLossSummaryOfBusinessResults",
    ]

    // MARK: - 営業利益タグ

    static let ordinaryIncomeTags: [String] = [
        "OrdinaryIncome",
        "OrdinaryIncomeLoss",
        "OrdinaryIncomeLossSummaryOfBusinessResults",
    ]

    static let operatingProfitDirectTags: [String] = [
        "OperatingProfitLossIFRS",
        "OperatingIncomeLoss",
        "OperatingIncome",
        "USGAAP_HTML_OperatingIncome",   // US-GAAP HTML仮想タグ（USGAAPHtml.parsePLFields が生成）
    ]

    static let sgaDirectTags: [String] = [
        "SellingGeneralAndAdministrativeExpensesIFRS",
        "SellingGeneralAndAdministrativeExpenses",
    ]

    static let sgaSellingIFRSTags: [String] = ["SellingExpensesIFRS"]
    static let sgaGaIFRSTags: [String] = ["GeneralAndAdministrativeExpensesIFRS"]

    // MARK: - 売上総利益タグ

    static let grossProfitDirectTags: [String] = [
        "GrossProfitIFRS",
        "GrossProfit",
        "GrossProfitOnCompletedConstructionContractsCNS",
    ]

    static let operatingGrossProfitDirectTags: [String] = [
        "OperatingGrossProfit",
    ]

    static let grossProfitSalesTags: [String] = [
        "NetSalesIFRS",
        "RevenueIFRS",
        "NetSales",
        "Revenue",
        "Revenues",
        "RevenuesUSGAAPSummaryOfBusinessResults",
        "NetSalesOfCompletedConstructionContractsCNS",
        "OperatingRevenue1",
        "OperatingRevenue1SummaryOfBusinessResults",
    ]

    static let grossProfitCostsTags: [String] = [
        "CostOfSalesIFRS",
        "CostOfSales",
        "CostOfRevenue",
        "OperatingCost",
        "CostOfSalesOfCompletedConstructionContractsCNS",
    ]

    struct BusinessGrossProfitComponent {
        let label: String
        let tags: [String]
        let sign: Int
    }

    static let businessGrossProfitComponents: [BusinessGrossProfitComponent] = [
        .init(label: "資金運用収益",     tags: ["InterestIncomeOIBNK"],              sign: 1),
        .init(label: "資金調達費用",     tags: ["InterestExpensesOEBNK"],             sign: -1),
        .init(label: "信託報酬",         tags: ["TrustFeesBNK"],                      sign: 1),
        .init(label: "役務取引等収益",   tags: ["FeesAndCommissionsOIBNK"],           sign: 1),
        .init(label: "役務取引等費用",   tags: ["FeesAndCommissionsPaymentsOEBNK"],   sign: -1),
        .init(label: "特定取引収益",     tags: ["TradingIncomeOIBNK"],                sign: 1),
        .init(label: "特定取引費用",     tags: ["TradingExpensesOEBNK"],              sign: -1),
        .init(label: "その他業務収益",   tags: ["OtherOrdinaryIncomeOIBNK"],          sign: 1),
        .init(label: "その他業務費用",   tags: ["OtherOrdinaryExpensesOEBNK"],        sign: -1),
    ]

    struct BankIBDComponent {
        let label: String
        let tags: [String]
    }

    // 銀行業 有利子負債コンポーネント（Python: BANK_IBD_COMPONENT_DEFINITIONS）
    // DepositsLiabilitiesBNK の存在が銀行業判定マーカーを兼ねる
    static let bankIBDComponents: [BankIBDComponent] = [
        .init(label: "預金",                   tags: ["DepositsLiabilitiesBNK"]),
        .init(label: "譲渡性預金",             tags: ["NegotiableCertificatesOfDepositLiabilitiesBNK"]),
        .init(label: "コマーシャル・ペーパー", tags: ["CommercialPapersLiabilities"]),
        .init(label: "借用金",                 tags: ["BorrowedMoneyLiabilitiesBNK"]),
        .init(label: "短期社債",               tags: ["ShortTermBondsPayable"]),
        .init(label: "社債",                   tags: ["BondsPayable"]),
    ]

    // MARK: - キャッシュフロータグ

    static let cfOperatingTags: [String] = [
        "CashFlowsFromUsedInOperationsIFRS",
        "CashFlowsFromUsedInOperatingActivitiesIFRS",
        "CashFlowsFromUsedInOperatingActivitiesIFRSSummaryOfBusinessResults",
        "CashFlowsFromUsedInOperatingActivitiesJMISSummaryOfBusinessResults",
        "CashFlowsFromUsedInOperatingActivitiesUSGAAPSummaryOfBusinessResults",
        "NetCashProvidedByUsedInOperatingActivities",
        "NetCashProvidedByUsedInOperatingActivitiesSummaryOfBusinessResults",
    ]

    static let cfInvestingTags: [String] = [
        "CashFlowsUsedInInvestingActivitiesIFRS",
        "CashFlowsFromUsedInInvestingActivitiesIFRS",
        "CashFlowsFromUsedInInvestingActivitiesIFRSSummaryOfBusinessResults",
        "CashFlowsFromUsedInInvestingActivitiesJMISSummaryOfBusinessResults",
        "CashFlowsFromUsedInInvestingActivitiesUSGAAPSummaryOfBusinessResults",
        "NetCashProvidedByUsedInInvestingActivities",
        "NetCashProvidedByUsedInInvestmentActivities",
        "NetCashProvidedByUsedInInvestingActivitiesSummaryOfBusinessResults",
    ]

    // MARK: - 貸借対照表タグ

    struct StandardBSItem {
        let field: String
        let label: String
        let tags: [String]
        let deriveMinus: (minuend: [String], subtrahend: [String])?
        init(field: String, label: String, tags: [String],
             deriveMinus: (minuend: [String], subtrahend: [String])? = nil) {
            self.field = field; self.label = label; self.tags = tags; self.deriveMinus = deriveMinus
        }
    }

    static let allStandardBSItems: [StandardBSItem] = [
        .init(field: "TotalAssets", label: "資産合計", tags: [
            "TotalAssets", "Assets",
            "TotalAssetsIFRS", "AssetsIFRS",
            "TotalAssetsIFRSSummaryOfBusinessResults",
            "TotalAssetsJMISSummaryOfBusinessResults",
            "TotalAssetsUSGAAP",
            "TotalAssetsSummaryOfBusinessResults",
            "TotalAssetsUSGAAPSummaryOfBusinessResults",
        ]),
        .init(field: "CurrentAssets", label: "流動資産", tags: [
            "CurrentAssets",
            "CurrentAssetsIFRS",
            "CurrentAssetsUSGAAP",
            "USGAAP_HTML_CurrentAssets",
        ]),
        .init(field: "NonCurrentAssets", label: "非流動資産", tags: [
            "NoncurrentAssets", "NonCurrentAssets",
            "NonCurrentAssetsIFRS",
            "NonCurrentAssetsUSGAAP",
        ], deriveMinus: (
            minuend: ["TotalAssets", "Assets", "TotalAssetsIFRS", "AssetsIFRS",
                      "TotalAssetsIFRSSummaryOfBusinessResults", "TotalAssetsUSGAAP",
                      "TotalAssetsUSGAAPSummaryOfBusinessResults"],
            subtrahend: ["CurrentAssets", "CurrentAssetsIFRS", "CurrentAssetsUSGAAP",
                         "USGAAP_HTML_CurrentAssets"]
        )),
        .init(field: "CurrentLiabilities", label: "流動負債", tags: [
            "CurrentLiabilities",
            "TotalCurrentLiabilitiesIFRS", "CurrentLiabilitiesIFRS",
            "CurrentLiabilitiesUSGAAP",
            "USGAAP_HTML_CurrentLiabilities",
        ]),
        .init(field: "NonCurrentLiabilities", label: "非流動負債", tags: [
            "NoncurrentLiabilities", "NonCurrentLiabilities",
            "NonCurrentLiabilitiesIFRS",
            "LongTermLiabilitiesUSGAAP", "NonCurrentLiabilitiesUSGAAP",
            "USGAAP_HTML_NonCurrentLiabilities",
        ], deriveMinus: (
            minuend: ["Liabilities", "LiabilitiesIFRS", "TotalLiabilitiesUSGAAP",
                      "USGAAP_HTML_TotalLiabilities"],
            subtrahend: ["CurrentLiabilities",
                         "TotalCurrentLiabilitiesIFRS", "CurrentLiabilitiesIFRS",
                         "CurrentLiabilitiesUSGAAP",
                         "USGAAP_HTML_CurrentLiabilities"]
        )),
        .init(field: "NetAssets", label: "純資産/資本合計", tags: [
            "EquityIFRS", "TotalEquityIFRS",
            "TotalEquityIFRSSummaryOfBusinessResults",
            "EquityIncludingPortionAttributableToNonControllingInterestIFRSSummaryOfBusinessResults",
            "NetAssets",
            "NetAssetsUSGAAP", "TotalEquityUSGAAP",
            "EquityIncludingPortionAttributableToNonControllingInterestUSGAAPSummaryOfBusinessResults",
            "USGAAP_HTML_NetAssets",
            "NetAssetsSummaryOfBusinessResults",
            "EquityAttributableToOwnersOfParentIFRS",
            "EquityAttributableToOwnersOfParentIFRSSummaryOfBusinessResults",
            "EquityAttributableToOwnersOfParentJMISSummaryOfBusinessResults",
            "EquityAttributableToOwnersOfParentUSGAAP",
            "EquityAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults",
        ]),
    ]

    // US-GAAP 非流動資産コンポーネント（HTML 仮想タグ積み上げ）
    static let usgaapHtmlNCAComponents: [[String]] = [
        ["USGAAP_HTML_PPENet"],
        ["USGAAP_HTML_InvestmentsLTReceivables"],
        ["USGAAP_HTML_OtherNCA"],
    ]

    // US-GAAP 非流動資産コンポーネント（XBRL タグ積み上げ — HTML が存在しない場合のフォールバック）
    static let usgaapXbrlNCAComponents: [[String]] = [
        ["InvestmentsAndLongTermReceivablesUSGAAP"],
        ["PropertyPlantAndEquipmentNetUSGAAP"],
        ["OtherAssetsUSGAAP"],
    ]

    // MARK: - 有利子負債タグ

    static let ibdDirectTags: [String] = [
        "InterestBearingDebt",
        "InterestBearingLiabilities",
    ]

    static let ibdCurrentComponents: [[String]] = [
        ["ShortTermLoansPayable", "BorrowingsCLIFRS"],
        ["CommercialPapersLiabilities", "CommercialPapersCLIFRS"],
        ["ShortTermBondsPayable"],
        ["CurrentPortionOfBonds", "RedeemableBondsWithinOneYear", "BondsPayableCLIFRS", "CurrentPortionOfBondsCLIFRS"],
        ["CurrentPortionOfLongTermLoansPayable", "CurrentPortionOfLongTermBorrowingsCLIFRS", "CurrentPortionOfLongTermDebtCLIFRS"],
        ["LeaseObligationsCL", "LeaseLiabilitiesCLIFRS"],
    ]

    static let ibdNonCurrentComponents: [[String]] = [
        ["BondsPayable", "BondsPayableNCLIFRS"],
        ["LongTermLoansPayable", "BorrowingsNCLIFRS", "LongTermDebtNCLIFRS"],
        ["LeaseObligationsNCL", "LeaseLiabilitiesNCLIFRS"],
    ]

    static let ibdIFRSCLTags: [String] = [
        "InterestBearingLiabilitiesCLIFRS",
        "BondsAndBorrowingsCLIFRS",
        "BondsBorrowingsAndLeaseLiabilitiesCLIFRS",
        "ShortTermDebtCLIFRS",
    ]

    static let ibdIFRSNCLTags: [String] = [
        "InterestBearingLiabilitiesNCLIFRS",
        "BondsAndBorrowingsNCLIFRS",
        "BondsBorrowingsAndLeaseLiabilitiesNCLIFRS",
        "LongTermDebtIFRSNCLIFRS",
    ]

    // MARK: - 支払利息タグ

    static let interestExpenseJGAAPTags: [String] = ["InterestExpensesNOE"]

    static let interestExpenseIFRSTags: [String] = [
        "InterestExpensesIFRS",
        "FinancialLiabilitiesMeasuredAtAmortizedCostInterestExpensesIFRS",
        "FinancialAssetsMeasuredAtAmortizedCostInterestExpensesIFRS",
        "FinanceCostsIFRS",
    ]

    static let ifrsInterestExpenseMarkerTags: [String] =
        ifrsPLMarkerTags + interestExpenseIFRSTags

    // MARK: - 税金タグ

    static let pretaxIncomeJGAAPTags: [String] = ["IncomeBeforeIncomeTaxes"]
    static let pretaxIncomeIFRSTags: [String] = ["ProfitLossBeforeTaxIFRS"]
    static let incomeTaxJGAAPTags: [String] = ["IncomeTaxes"]
    static let incomeTaxIFRSTags: [String] = ["IncomeTaxExpenseIFRS"]

    static let ifrsTaxMarkerTags: [String] =
        ifrsPLMarkerTags + pretaxIncomeIFRSTags + incomeTaxIFRSTags

    // MARK: - 有形固定資産タグ

    static let ppeTotalIFRSDirectTags: [String] = ["PropertyPlantAndEquipmentIFRS"]
    static let ppeTotalJGAAPDirectTags: [String] = ["PropertyPlantAndEquipment"]

    // US-GAAP 専用合計タグ（USGAAP_HTML_PPENet は USGAAPHtml.parseBSFields が生成する仮想タグ）
    static let ppeTagsUSGAAPTotal: [String] = [
        "USGAAP_HTML_PPENet",
        "PropertyPlantAndEquipmentNetUSGAAP",
        "PropertyPlantAndEquipmentUSGAAP",
    ]

    static let ppeTotalCostTags: [String] = ["PropertyPlantAndEquipmentAcquisitionCostIFRS"]
    static let ppeTotalDepTags: [String] = [
        "PropertyPlantAndEquipmentAccumulatedDepreciationAndImpairmentLossesIFRS",
    ]

    // MARK: - 従業員数タグ

    static let employeeTags: [String] = [
        "NumberOfEmployees",
        "NumberOfGroupEmployees",
    ]

    // MARK: - 研究開発費タグ

    static let rdExpenseCommonTags: [String] = [
        "ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities",
    ]

    static let rdExpenseJGAAPTags: [String] = [
        "ResearchAndDevelopmentExpensesSGA",
        "ResearchAndDevelopmentExpenses",
    ]

    static let rdExpenseIFRSTags: [String] = [
        "ResearchAndDevelopmentExpenditureRecognizedAsExpenseDuringPeriodIFRS",
        "ResearchAndDevelopmentExpensesIFRS",
        "ResearchAndDevelopmentCostsIFRS",
    ]

    // MARK: - 設備投資タグ

    static let capexOverviewTags: [String] = [
        "CapitalExpendituresOverviewOfCapitalExpendituresEtc",
    ]
    static let capexCFJGAAPTags: [String] = ["PurchaseOfPropertyPlantAndEquipmentInvCF"]
    static let capexCFIFRSTags: [String] = [
        "AcquisitionOfPropertyPlantAndEquipmentInvCFIFRS",
        "PurchaseOfPropertyPlantAndEquipmentInvCFIFRS",
    ]

    // MARK: - 現金タグ

    static let cashEquivalentsTags: [String] = [
        "CashAndCashEquivalentsIFRS",
        "CashAndCashEquivalentsAtEndOfPeriod",
        "CashAndCashEquivalents",
        "CashAndCashEquivalentsSummaryOfBusinessResults",
        "CashAndCashEquivalentsUSGAAPSummaryOfBusinessResults",
        "CashAndCashEquivalentsUSGAAP",
    ]

    // MARK: - 純収益・事業利益（IFRS金融会社向けフォールバック）

    static let netRevenueIFRSTags: [String] = ["NetRevenueIFRS"]
    static let businessProfitIFRSSRTags: [String] = ["BusinessProfitIFRSSummaryOfBusinessResults"]

    // MARK: - 自己株式取得

    static let shareBuybackSSJGAAPTags: [String] = [
        "PurchaseOfTreasuryStock",
    ]
    static let shareBuybackCFJGAAPTags: [String] = [
        "PurchaseOfTreasuryStockFinCF",
    ]
    static let shareBuybackSSIFRSTags: [String] = [
        "PurchaseOfTreasurySharesSSIFRS",
        "PurchaseAndDisposalOfTreasurySharesSSIFRS",
    ]
    static let shareBuybackCFIFRSTags: [String] = [
        "PaymentsForPurchaseOfTreasurySharesFinCFIFRS",
        "PurchaseOfTreasurySharesFinCFIFRS",
        "AcquisitionOfTreasurySharesFinCFIFRS",
        "ReissuanceRepurchaseOfTreasuryStockFinCFIFRS",
    ]
}

// MARK: - XBRL セクション定義（filing コマンドで使用）

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
