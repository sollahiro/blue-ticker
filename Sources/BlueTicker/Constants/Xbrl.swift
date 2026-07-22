// XBRL コンテキストパターン・タグ定数
// Python の blue_ticker/constants/xbrl.py 相当

enum Xbrl {
    /// インスタンス文書が十分大きいとみなす最小バイト数（zero_debt 判定）。
    static let zeroDebtMinInstanceBytes: Int = 100_000

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

    // MARK: - 税金タグ

    static let pretaxIncomeJGAAPTags: [String] = ["IncomeBeforeIncomeTaxes"]
    static let pretaxIncomeIFRSTags: [String] = ["ProfitLossBeforeTaxIFRS"]
    static let incomeTaxJGAAPTags: [String] = ["IncomeTaxes"]
    static let incomeTaxIFRSTags: [String] = ["IncomeTaxExpenseIFRS"]

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
        // 収益認識基準移行期の企業拡張タグ（例: ぷらっとホーム 6836、FY22〜FY25の間のみ使用）。
        "AccountsReceivableTradeReceivablesFromContractsWithCustomersCA",
        "AccountsReceivableTradeAndContractAssetsCA",
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
        "NotesSegmentInformationConsolidatedFinancialStatementsIFRSTextBlock",  // 第一三共・塩野義（jpigp_corタクソノミ）
    ]
    static let businessSegmentDimensionKeywords: [String] = [
        "OperatingSegments",
        "BusinessSegment",
        "ReportableSegment",
    ]
    static let businessSegmentMixedTextBlockTags: Set<String> = [
        "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock",  // US-GAAP 連結財務諸表注記（事業別セグメントを内包）
    ]
    static let businessSegmentHeadingKeywords: [String] = [
        "セグメント情報",
        "事業の種類別",
        "報告セグメント",
    ]
    // 事業別セグメントの見出し候補文字列に含まれていたら除外する（「地域別セグメント情報」等、
    // 地域別注記の見出しが「セグメント情報」を部分文字列として含むため誤って拾わないようにする）。
    static let businessSegmentHeadingExclusionKeywords: [String] = [
        "地域",
    ]

    // mixedTags 経由の見出し一致で次の <table> を無条件採用すると、巨大な注記内の無関係な表
    // （収益認識の時期別内訳・ストックオプションの評価前提・投資有価証券の公正価値等）を誤って
    // 拾うことがある。いずれも会計基準の定型文言のため、これらを含む表は候補から除外する。
    static let noteTableExclusionKeywords: [String] = [
        "一時点で認識する収益",              // 収益認識の時期別内訳（企業会計基準第29号）
        "一定期間にわたり認識する収益",
        "予想残存期間",                    // ストックオプションの公正価値評価前提
        "総未実現利益",                    // 投資有価証券の公正価値内訳（ASC 320/321 相当）
        "償却累計額",                     // 無形固定資産・有形固定資産の取得原価/償却累計額/帳簿価額の内訳
    ]
    // 見出し直後の表が noteTableExclusionKeywords に該当した場合、次の表を何個先まで
    // 試すか（無関係な後続表まで際限なく拾わないための上限）。
    static let noteTableLookaheadLimit = 5

    // 「第n期及び第n+1期における...は以下のとおりであります」のように、前期・当期を
    // 1つの見出しでまとめて紹介し、表ごとに個別の <div> でラップされた表が短いラベル
    // （「第125期」等）だけを挟んで連続するケースがある（実データ: キヤノン地域別注記）。
    // 直後の表の見出し行が一致する場合に限り「同じ開示の続き」とみなして追加で拾う。
    // 何段階（何要素）先まで許容するか。
    static let noteTableChainMaxGapElements = 5
    // 挟まる要素のテキストがこの文字数を超えたら、無関係な話題への移行とみなし打ち切る
    // （detectPeriodFromPreceding の短キャプション判定と同じ考え方の閾値を共有）。
    static let noteShortCaptionMaxLength = 100

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

    // 収益認識関係（顧客との契約から生じる収益を分解した情報）。報告セグメントが地域別の会社
    // （オークマ型）で、本当の事業別（製品別）データがここにしかないケースの追加ソース。
    static let revenueRecognitionTextBlockTags: Set<String> = [
        "NotesRevenueRecognitionConsolidatedFinancialStatementsTextBlock",
    ]

    // MARK: - 事業別・地域別内訳の正規化（Stage 6, docs/breakdown-normalization-concept.md）

    /// セグメント別の外部顧客売上タグ（優先順）。会計基準が混在するため単一タグ決め打ちにしない
    /// （netSalesTags と同様、resolveItemPreferCurrent 相当の走査で先頭から一致するものを採用）。
    /// 銀行等はここに一致するタグを持たない（NetRevenue / ConsolidatedGrossProfit 等）ため、
    /// Stage 6 v1 の対象外は本リストとの不一致という形で自然に成立する。
    static let segmentExternalRevenueTags: [String] = [
        "SalesToExternalCustomersIFRS",
        "RevenueFromExternalCustomersIFRS",
        "RevenueFromExternalCustomers2IFRS",  // 伊藤忠など
        "OperatingRevenueFromExternalCustomersIFRS",  // トヨタなど
        "RevenuesFromExternalCustomers",
        "TransactionsWithExternalCustomersIFRS",  // NTTなど（実データ検証済み、issue調査 2026-07-21）
        "RevenueIFRS",  // ファーストリテイリングなど（実データ検証済み、issue調査 2026-07-21）
    ]

    /// 本リストに一致するタグが無い場合の候補発見（`BreakdownNormalizer` のカバレッジ/金額整合性
    /// ヒューリスティック）で、明らかに売上ではない概念を除外するための部分文字列ブラックリスト。
    /// 個別タグ名を都度追加するホワイトリストの Whac-A-Mole を避けつつ、銀行の NetRevenue 系や
    /// 資産・利益・従業員数等の再入場を防ぐ（Grok 4.5 レビュー指摘、docs/breakdown-normalization-concept.md）。
    static let segmentNonRevenueTagKeywords: [String] = [
        "Profit", "Loss", "Asset", "Employee", "Equity", "Depreciation",
        "Impairment", "Expenditure", "Liabilit", "Capital", "Dividend",
        "NetRevenue", "OrdinaryRevenue", "OrdinaryIncome",  // 銀行等金融機関の指標概念（Grok 4.5 レビュー指摘）
    ]

    /// セグメント別の利益タグ（優先順）。IFRS でも会社により表記が割れる
    /// （味の素は BusinessProfitLossIFRS、クボタ・スズキは OperatingProfitLossIFRS、
    /// 日立は SegmentProfitLossIFRS＝セグメント損益、
    /// ソフトバンクGは ProfitLossBeforeTaxIFRS＝税引前利益）。
    /// 任意フィールドのため、一致するタグが無くても snapshot 自体は成立する（rows[].profit が nil になるだけ）。
    static let segmentProfitTags: [String] = [
        "BusinessProfitLossIFRS",
        "SegmentProfitLossIFRS",
        "OperatingProfitLossIFRS",
        "OperatingIncome",
        "ProfitLossBeforeTaxIFRS",
    ]

    /// 銀行等、外部売上高に相当する概念を持たない金融機関の粗利益タグ（優先順）。
    /// `BreakdownNormalizer.normalizeInternalSubtotalBasis` が売上系タグ不一致時の
    /// フォールバックとして使う（実データ検証: 三菱UFJ、issue調査 2026-07-21）。
    static let segmentBankGrossProfitTags: [String] = [
        "NetRevenue",  // 三菱UFJ
        "ConsolidatedGrossProfit",  // 三井住友
        "GrossProfitsExcludingTheAmountsOfCreditCostsOfTrustAccountsIncludingNetGainsLossesRelatedToETFsAndOthersSegmentInformation",  // みずほ
        "GrossOperatingProfit",  // りそな
    ]

    /// segmentBankGrossProfitTags と対になる営業純益タグ（優先順）。任意フィールド。
    static let segmentBankNetOperatingProfitTags: [String] = [
        "OperatingProfit",  // 三菱UFJ
        "ConsolidatedNetBusinessProfit",  // 三井住友
        "NetBusinessProfitsExcludingTheAmountsOfCreditCostsOfTrustAccountsBeforeReversalOfProvisionForGeneralAllowanceForLoanLossesIncludingNetGainsLossesRelatedToETFsAndOthersSegmentInformation",  // みずほ
        "ActualNetOperatingProfit",  // りそな（実質業務純益）
    ]

    /// 保険会社（IFRS17）の保険収益タグ（優先順）。銀行と同じ理由で外部売上高の概念を持たない
    /// ため `normalizeInternalSubtotalBasis` のフォールバックとして使う（実データ検証:
    /// 東京海上ホールディングス、issue調査 2026-07-21）。
    static let segmentInsuranceRevenueTags: [String] = [
        "InsuranceRevenueIFRS",  // 東京海上
    ]

    /// segmentInsuranceRevenueTags と対になる保険サービス損益タグ（優先順）。任意フィールド。
    /// 税引前利益（ProfitLossBeforeTaxIFRS）ではなくこちらを採用: 保険引受由来の業績を示す
    /// IFRS17の中核指標で、投資損益等の変動を含まないため事業間比較に適する
    /// （東京海上の実データでは ProfitLossBeforeTaxIFRS だと生保セグメントが会計上の理由で
    /// 大幅赤字になり比較の意味が薄れる）。
    static let segmentInsuranceServiceResultTags: [String] = [
        "InsuranceServiceResultIFRS",  // 東京海上
    ]

    /// EDINET/ASBJ タクソノミ標準の小計・調整・全社共通費 member（企業拡張ラベルではなく標準語彙）。
    /// これらは比較の分母・シェア計算から除外する（行自体は保持する）。
    static let segmentSubtotalMemberNames: Set<String> = [
        "ReportableSegmentsMember",
        "TotalOfReportableSegmentsAndOthersMember",
        "CorporateSharedMember",
        "UnallocatedAmountsAndEliminationMember",
        "TotalMember",  // 三菱UFJ（粗利益/営業純益の総額）
        "TotalOfCustomerBusinessUnitMember",  // 三菱UFJ（市場・その他を除く顧客部門合計）
    ]

    /// 小計・調整とは別に「除去・消去」を表す member（reconciling として区別する）。
    static let segmentReconcilingMemberNames: Set<String> = [
        "ReconcilingItemsMember",
        "HeadOfficeAccountsEtcReportableSegmentMember",  // 三井住友（本社勘定等）
    ]

    /// 報告セグメントに含まれない「その他」事業（実際に売上を持つ事業区分。小計・調整の合算ではない）。
    /// `BreakdownNormalizer` では rowKind を `segment` として扱う（実データ検証: この member を
    /// 加算しないと `sum(segment) ≠ denominator` になる企業が多数あった）。一方で事業/地域いずれの
    /// 軸にも属すると断定できない「その他」バケツのため、`BreakdownExtractor.isGeographyAxis` の
    /// 軸判定候補からは `segmentSubtotalMemberNames` と同様に除外し続ける（軸判定への影響を避ける）。
    static let segmentOtherBusinessMemberNames: Set<String> = [
        "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
    ]

    /// member ラベルがこのキーワードに一致すれば地域軸とみなす（軸判定ルール、学び10 参照）。
    /// XBRL member 名（英語識別子）向け。html_table の日本語行ラベル判定には
    /// `segmentGeographyLabelKeywordsJa` を使う（別レイヤーのキーワード表）。
    static let segmentGeographyMemberKeywords: [String] = [
        "Japan",
        "Americas",
        "America",
        "Europe",
        "Asia",
        "China",
        "NorthAmerica",
        "Emea",
        "Domestic",
        "Overseas",
        "Pacific",
    ]

    /// `segmentGeographyMemberKeywords` から「国内」「海外」相当の汎用修飾語（`Domestic`/`Overseas`）
    /// を除いた、特定の国・地域名のみのサブセット（学び11、実データ検証: 1802/1812/1808/2413）。
    /// 建設業等では「国内建築」「海外建築」のように Domestic/Overseas が事業区分名の接頭辞になる
    /// ケースや、「海外事業」のように事業区分の1つとして海外を単独カテゴリ化するケースが多数あり、
    /// これらは事業軸のクロス集計・カテゴリ分けであって地域軸との真の混在ではない。
    /// `BreakdownNormalizer.classifyAxis` の部分一致（混在）判定では、この特定地域名サブセットに
    /// 一致する行が1件も無ければ needs_review を立てない（Domestic/Overseas のみの一致は
    /// axis 判定のシグナルとして弱すぎるため）。
    static let segmentSpecificGeographyMemberKeywords: [String] = segmentGeographyMemberKeywords
        .filter { $0 != "Domestic" && $0 != "Overseas" }

    /// html_table 由来の行ラベル（日本語表記）が地域名らしいかの判定キーワード。
    /// `segmentGeographyMemberKeywords`（英語 member 名用）とは別レイヤー。
    /// LLM 正規化（`GeographyBreakdownLLMNormalizer`）が誤った表を選んでいないかの
    /// 決定的ガードに使う（分母整合性だけでは検知できない事故対策。学び参照）。
    /// 「その他」は意図的に含めない — 事業別表にも「その他及び全社」等の形でほぼ必ず出現し、
    /// 固有の地域名が最低1つ一致することを要求するガードの意味を失わせるため
    /// （実データ: キヤノンの事業別表に「その他及び全社」列があり、これを許すと誤検知が起きる）。
    static let segmentGeographyLabelKeywordsJa: [String] = [
        "日本", "米国", "米州", "アメリカ", "北米", "南米",
        "欧州", "ヨーロッパ", "アジア", "中国", "オセアニア",
        "パシフィック", "中近東", "中東", "海外", "国内",
    ]

    /// `segmentGeographyLabelKeywordsJa` から「国内」「海外」相当の汎用修飾語を除いた、
    /// 特定の国・地域名のみのサブセット（`segmentSpecificGeographyMemberKeywords`の日本語版）。
    /// 実データ検証（キッコーマン、issue調査 2026-07-21）: 「国内食料品製造・販売」
    /// 「海外食料品製造・販売」のような事業区分×国内海外クロス集計の行ラベルは、全行が
    /// 「国内」「海外」を含むため `segmentGeographyLabelKeywordsJa` の全一致判定に誤ってヒットし、
    /// 事業別の表を地域別と誤認して needs_review になっていた。特定地域名の一致が無い場合は
    /// 誤検知としてガードを立てない。
    static let segmentSpecificGeographyLabelKeywordsJa: [String] =
        segmentGeographyLabelKeywordsJa.filter { $0 != "海外" && $0 != "国内" }
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
