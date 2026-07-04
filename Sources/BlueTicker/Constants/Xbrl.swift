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

    // MARK: - 1株当たり利益（基本EPS・連結当期）

    /// 基本1株当たり当期利益（連結）。連結本表タグを優先し、無ければ主要な経営指標等の推移
    /// （SummaryOfBusinessResults）の当期連結値へフォールバックする。durationFS で解決すると
    /// 連結 CurrentYearDuration が選ばれる（`_NonConsolidatedMember` は単体としてフォールバック）。
    /// JGAAP・US-GAAP は本表に離散数値EPSタグが無く Summary が唯一の数値源。
    static let basicEpsTags: [String] = [
        "BasicEarningsLossPerShareIFRS",                            // IFRS 連結本表
        "BasicAndDilutedEarningsLossPerShareIFRS",                 // IFRS 連結本表（基本=希薄化 同値）
        "BasicEarningsLossPerShareIFRSSummaryOfBusinessResults",   // IFRS Summary
        "BasicEarningsLossPerShareUSGAAPSummaryOfBusinessResults", // US-GAAP Summary
        "BasicEarningsLossPerShareSummaryOfBusinessResults",       // JGAAP・汎用 Summary
    ]

    // MARK: - 発行済普通株式数（期末残高）

    /// 発行済普通株式数（期末残高）。【株式の総数】表の普通株式（OrdinaryShareMember）を優先し、
    /// 無ければ主要な経営指標等の推移の期末発行済株式総数（CurrentYearInstant）へフォールバックする。
    /// 単一株式クラスの企業では両者は一致する。
    static let issuedSharesFYEndTag = "NumberOfIssuedSharesAsOfFiscalYearEndIssuedSharesTotalNumberOfSharesEtc"
    static let issuedSharesSummaryTag = "TotalNumberOfIssuedSharesSummaryOfBusinessResults"
    static let ordinaryShareMemberSuffix = "_OrdinaryShareMember"
    static let currentYearInstantContext = "CurrentYearInstant"
    static let filingDateInstantContext = "FilingDateInstant"

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

    // 売上総利益の計算法（売上 − 売上原価）の売上側タグ。
    // netSalesTags を単一の真実源とし、そこから経常収益タグ（銀行等の ordinaryRevenueTags）を
    // 除外して導出する。独立手書きリストを持たないことで「片側だけタグが腐り not_found に落ちる」
    // 事故を防ぎ（issue #24）、かつ売上原価を持たない非銀行金融（保険等）が
    // 「GP＝経常収益（原価0扱い）」という無意味な値を誤算出するのを防ぐ。
    static let grossProfitSalesTags: [String] = netSalesTags.filter { !ordinaryRevenueTags.contains($0) }

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

    /// 連結附属明細表「借入金等明細表」TextBlock タグ。
    /// 連結BSに有利子負債の数値タグが無い企業（リース債務が明細表のみに記載される等）のフォールバック源。
    static let borrowingsScheduleTextblockTag = "AnnexedConsolidatedDetailedScheduleOfBorrowingsTextBlock"

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

    // MARK: - 配当

    static let dividendSSJGAAPTags: [String] = [
        "DividendsFromSurplus",
    ]
    static let dividendSSIFRSTags: [String] = [
        "DividendsToOwnersOfParentSSIFRS",
        "DividendsSSIFRS",
    ]
    static let dividendPaidCFJGAAPTags: [String] = [
        "CashDividendsPaidFinCF",
    ]
    static let dividendPaidCFIFRSTags: [String] = [
        "DividendsPaidToOwnersOfParentFinCFIFRS",
        "DividendsPaidFinCFIFRS",
    ]

    // MARK: - 売掛金（BS, Instant）

    static let accountsReceivableJGAAPTags: [String] = [
        "NotesAndAccountsReceivableTrade",
        "AccountsReceivableTrade",
        // 収益認識基準導入後の標準科目「受取手形、売掛金及び契約資産」（例: さくらインターネット 3778）。
        // 契約資産分を含むが、運転資本・CCC の用途では営業債権として許容する。
        "NotesAndAccountsReceivableTradeAndContractAssets",
        "AccountsReceivableTradeAndContractAssets",
    ]
    static let accountsReceivableIFRSTags: [String] = [
        "TradeAndOtherReceivablesCAIFRS",
        "TradeAndOtherReceivables2CAIFRS",
        "TradeAndOtherReceivables3CAIFRS",
        "TradeReceivablesCAIFRS",
        "TradeReceivables2CAIFRS",
        // 売上債権＋契約資産を合算した企業拡張タグ（例: 日立 6501）。
        // 契約資産分を含むが、運転資本・CCC の用途では営業債権として許容する。
        "TradeReceivablesAndContractAssetsCAIFRSIFRS",
    ]

    // MARK: - 棚卸資産（BS, Instant）

    static let inventoryJGAAPTags: [String] = [
        "Inventories",
    ]
    static let inventoryIFRSTags: [String] = [
        "InventoriesCAIFRS",
    ]
    // J-GAAP 企業別内訳タグ（Inventories 合算タグがない場合の積み上げフォールバック）
    static let inventoryJGAAPComponents: [[String]] = [
        ["MerchandiseAndFinishedGoods", "Merchandise", "FinishedGoods"],
        ["WorkInProcess"],
        ["RawMaterialsAndSupplies", "RawMaterials", "Supplies"],
    ]

    // MARK: - 買掛金（BS, Instant）

    static let accountsPayableJGAAPTags: [String] = [
        "NotesAndAccountsPayableTrade",
        "AccountsPayableTrade",
    ]
    static let accountsPayableIFRSTags: [String] = [
        "TradeAndOtherPayablesCLIFRS",
        "TradeAndOtherPayables2CLIFRS",
        "TradeAndOtherPayables3CLIFRS",
        "TradePayablesCLIFRS",
        "TradePayables2CLIFRS",
        "TradePayables3CLIFRS",
    ]

    // MARK: - セグメント・地域別情報（segment_extractor 相当）

    // 事業別セグメント
    static let businessSegmentTextBlockTags: Set<String> = [
        "SegmentInformationTextBlock",
        "SegmentInformationIFRSTextBlock",
        "SegmentInformationUSGAAPTextBlock",
        "SegmentInformationByBusinessSegmentTextBlock",
    ]
    static let businessSegmentDimensionKeywords: [String] = [
        "OperatingSegments",
        "BusinessSegment",
        "ReportableSegment",
    ]

    // 地域別
    static let geographyTextBlockTags: Set<String> = [
        "InformationAboutGeographicalAreasIFRSTextBlock",                  // IFRS
        "InformationAboutGeographicalAreasTextBlock",                       // J-GAAP
        "InformationAboutGeographicalAreasUSGAAPTextBlock",                 // US-GAAP
        "RelatedInformationTextBlock",                                      // J-GAAP 関連情報（混在）
        "RevenuesFromExternalCustomersInformationForEachRegionTextBlock",   // J-GAAP 地域ごとの外部顧客への売上収益
        "PropertyPlantAndEquipmentInformationForEachRegionTextBlock",       // J-GAAP 地域ごとの有形固定資産
    ]
    static let geographyMixedTextBlockTags: Set<String> = [
        "RelatedInformationTextBlock",                            // J-GAAP 関連情報（セグメント・地域が混在）
        "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock",  // US-GAAP 連結財務諸表注記（地域別を内包）
    ]
    static let geographyHeadingKeywords: [String] = [
        "地域ごとの情報",
        "地域別",
        "所在地別",
    ]
    static let geographyDimensionKeywords: [String] = [
        "GeographicArea",
        "Geography",
        "Country",
        "Region",
        "NoncurrentAssetsByLocation",
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
    "management_policy": XBRLSectionDef(
        title: "経営方針、経営環境及び対処すべき課題等",
        xbrlElements: ["BusinessPolicyBusinessEnvironmentIssuesToAddressEtcTextBlock"]
    ),
]
