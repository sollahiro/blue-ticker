from typing import NotRequired, TypedDict


class _XBRLSection(TypedDict):
    title: str
    xbrl_elements: list[str]


class _ComponentDef(TypedDict):
    label: str
    tags: list[str]


class _SignedComponentDef(TypedDict):
    label: str
    tags: list[str]
    sign: int


class _AggregateIFRSDef(TypedDict):
    tag: str
    covers: list[str]
    label: NotRequired[str]


class _BalanceSheetComponentDef(TypedDict):
    field: str
    label: str
    tags: list[str]


class _BalanceSheetAggregateDef(TypedDict):
    field: str
    label: str
    tags: list[str]


class _BalanceSheetSubtractDef(TypedDict):
    field: str
    label: str
    minuend_tags: list[str]
    subtrahend_tags: list[str]


# Duration（損益計算書・CF）コンテキストパターン
# 年次: CurrentYearDuration / 新形式半期: InterimDuration / 旧形式半期・四半期: CurrentYTDDuration
DURATION_CONTEXT_PATTERNS: list[str] = [
    "CurrentYearDuration",
    "FilingDateDuration",
    "InterimDuration",
    "CurrentYTDDuration",
]

PRIOR_DURATION_CONTEXT_PATTERNS: list[str] = [
    "Prior1YearDuration",
    "PriorYearDuration",
    "Prior1InterimDuration",
    "Prior1YTDDuration",
]

# Instant（貸借対照表）コンテキストパターン
# 四半期・半期報告書にも対応
INSTANT_CONTEXT_PATTERNS: list[str] = [
    "CurrentYearInstant",
    "CurrentQuarterInstant",
    "InterimInstant",
    "FilingDateInstant",
]

PRIOR_INSTANT_CONTEXT_PATTERNS: list[str] = [
    "Prior1YearInstant",
    "PriorYearInstant",
    "Prior1QuarterInstant",
    "Prior1InterimInstant",
]

# 会計基準判定用マーカータグ。
# pre_parsed 経由でも判定用タグが落ちないよう、各モジュールの relevant tags に含める。
# モジュール固有の IFRS データタグは、判定マーカーとしても機能するため *_MARKER_TAGS に含める。
USGAAP_MARKER_TAGS: list[str] = [
    "TotalAssetsUSGAAPSummaryOfBusinessResults",
    "EquityAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults",
    "CashAndCashEquivalentsUSGAAPSummaryOfBusinessResults",
    "RevenuesUSGAAPSummaryOfBusinessResults",
    "NetIncomeLossAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults",
    "CashFlowsFromUsedInOperatingActivitiesUSGAAPSummaryOfBusinessResults",
    "CashFlowsFromUsedInInvestingActivitiesUSGAAPSummaryOfBusinessResults",
]

IFRS_BALANCE_SHEET_MARKER_TAGS: list[str] = [
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

IFRS_PL_MARKER_TAGS: list[str] = [
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

XBRL_SECTIONS: dict[str, _XBRLSection] = {
    'business_risks': {
        'title': '事業等のリスク',
        'xbrl_elements': ['BusinessRisksTextBlock']
    },
    'mda': {
        'title': '経営者による財政状態、経営成績及びキャッシュ・フローの状況の分析',
        'xbrl_elements': ['ManagementAnalysisOfFinancialPositionOperatingResultsAndCashFlowsTextBlock']
    },
    'capex_overview': {
        'title': '設備投資等の概要',
        'xbrl_elements': ['OverviewOfCapitalExpendituresEtcOwnUsedAssetsLEATextBlock']
    },
    'major_facilities': {
        'title': '主要な設備の状況',
        'xbrl_elements': ['MajorFacilitiesTextBlock']
    },
    'facility_plans': {
        'title': '設備の新設、除却等の計画',
        'xbrl_elements': ['PlannedAdditionsRetirementsEtcOfFacilitiesTextBlock']
    },
    'research_and_development': {
        'title': '研究開発活動',
        'xbrl_elements': ['ResearchAndDevelopmentActivitiesTextBlock']
    },
}

# 貸借対照表（BS）タグ定義
# analysis/balance_sheet.py で使用

BALANCE_SHEET_COMPONENT_DEFINITIONS: list[_BalanceSheetComponentDef] = [
    {
        "field": "TotalAssets",
        "label": "総資産",
        "tags": [
            "TotalAssets",                         # J-GAAP 要約情報
            "Assets",                              # J-GAAP BS
            "TotalAssetsIFRS",                     # IFRS
            "AssetsIFRS",                          # IFRS 代替
            "TotalAssetsUSGAAP",                   # US-GAAP
            "TotalAssetsUSGAAPSummaryOfBusinessResults",
            "TotalAssetsSummaryOfBusinessResults", # J-GAAP 要約情報
        ],
    },
    {
        "field": "CurrentAssets",
        "label": "流動資産",
        "tags": [
            "CurrentAssets",        # J-GAAP
            "CurrentAssetsIFRS",    # IFRS
            "CurrentAssetsUSGAAP",  # US-GAAP
        ],
    },
    {
        "field": "NonCurrentAssets",
        "label": "固定資産",
        "tags": [
            "NoncurrentAssets",        # J-GAAP
            "NonCurrentAssets",        # 代替表記
            "NonCurrentAssetsIFRS",    # IFRS
            "NonCurrentAssetsUSGAAP",  # US-GAAP
        ],
    },
    {
        "field": "CurrentLiabilities",
        "label": "流動負債",
        "tags": [
            "CurrentLiabilities",        # J-GAAP
            "TotalCurrentLiabilitiesIFRS", # IFRS
            "CurrentLiabilitiesIFRS",    # IFRS
            "CurrentLiabilitiesUSGAAP",  # US-GAAP
        ],
    },
    {
        "field": "NonCurrentLiabilities",
        "label": "固定負債",
        "tags": [
            "NoncurrentLiabilities",        # J-GAAP
            "NonCurrentLiabilities",        # 代替表記
            "NonCurrentLiabilitiesIFRS",    # IFRS
            "LongTermLiabilitiesUSGAAP",    # US-GAAP
            "NonCurrentLiabilitiesUSGAAP",  # US-GAAP 代替
        ],
    },
    {
        "field": "NetAssets",
        "label": "純資産",
        "tags": [
            "NetAssets",                                              # J-GAAP
            "EquityIFRS",                                             # IFRS
            "TotalEquityIFRS",                                        # IFRS 代替
            "EquityIncludingPortionAttributableToNonControllingInterestIFRSSummaryOfBusinessResults",
            "EquityAttributableToOwnersOfParentIFRS",                 # IFRS 親会社所有者帰属持分
            "NetAssetsUSGAAP",                                        # US-GAAP
            "TotalEquityUSGAAP",                                      # US-GAAP 代替
            "EquityIncludingPortionAttributableToNonControllingInterestUSGAAPSummaryOfBusinessResults",
            "EquityAttributableToOwnersOfParentUSGAAP",               # US-GAAP 親会社所有者帰属持分
            "EquityAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults",
        ],
    },
]

BALANCE_SHEET_AGGREGATE_DEFINITIONS: list[_BalanceSheetAggregateDef] = [
    {
        "field": "NonCurrentAssets",
        "label": "投資及び長期債権合計＋有形固定資産合計＋その他の資産合計",
        "tags": [
            "InvestmentsAndLongTermReceivablesUSGAAP",
            "PropertyPlantAndEquipmentNetUSGAAP",
            "PropertyPlantAndEquipmentUSGAAP",
            "OtherAssetsUSGAAP",
        ],
    },
]

BALANCE_SHEET_SUBTRACT_DEFINITIONS: list[_BalanceSheetSubtractDef] = [
    {
        "field": "NonCurrentLiabilities",
        "label": "負債合計−流動負債",
        "minuend_tags": [
            "LiabilitiesIFRS",
            "TotalLiabilitiesUSGAAP",
            "Liabilities",
        ],
        "subtrahend_tags": [
            "TotalCurrentLiabilitiesIFRS",
            "CurrentLiabilitiesIFRS",
            "CurrentLiabilitiesUSGAAP",
            "CurrentLiabilities",
        ],
    },
]

# 連結財政状態計算書（IFRS）項目定義
# analysis/field_parser.py で使用
#
# 各エントリは {"tags": [...], "derive": {...}} の形。
#   tags     : 優先順に試すXBRLタグ。最初に値が見つかったものを採用。
#   derive   : タグで直接取れない場合の差し引き計算定義。
#              {"minuend_tags": [...], "subtrahend_tags": [...]}

class _IFRSBSItemDef(TypedDict):
    label: str
    tags: list[str]
    derive: NotRequired[dict[str, list[str]]]


class _StandardBSItemDef(TypedDict):
    field: str
    label: str
    tags: list[str]
    derive: NotRequired[dict[str, list[str]]]


IFRS_BS_ITEM_DEFINITIONS: list[_IFRSBSItemDef] = [
    {
        "label": "資産合計",
        "tags": ["AssetsIFRS", "TotalAssetsIFRS", "TotalAssetsIFRSSummaryOfBusinessResults"],
    },
    {
        "label": "流動資産",
        "tags": ["CurrentAssetsIFRS"],
    },
    {
        "label": "非流動資産",
        "tags": ["NonCurrentAssetsIFRS"],
        "derive": {
            "minuend_tags": ["AssetsIFRS", "TotalAssetsIFRS"],
            "subtrahend_tags": ["CurrentAssetsIFRS"],
        },
    },
    {
        "label": "負債合計",
        "tags": ["LiabilitiesIFRS", "TotalLiabilitiesIFRS"],
    },
    {
        "label": "流動負債",
        "tags": ["TotalCurrentLiabilitiesIFRS", "CurrentLiabilitiesIFRS"],
    },
    {
        "label": "非流動負債",
        "tags": ["NonCurrentLiabilitiesIFRS"],
        "derive": {
            "minuend_tags": ["LiabilitiesIFRS", "TotalLiabilitiesIFRS"],
            "subtrahend_tags": ["TotalCurrentLiabilitiesIFRS", "CurrentLiabilitiesIFRS"],
        },
    },
    {
        "label": "資本合計",
        "tags": ["EquityIFRS", "TotalEquityIFRS", "TotalEquityIFRSSummaryOfBusinessResults"],
    },
    {
        "label": "親会社所有者帰属持分",
        "tags": ["EquityAttributableToOwnersOfParentIFRS"],
    },
]

# 有利子負債（IBD）タグ定義
# analysis/interest_bearing_debt.py で使用

# 有利子負債合計タグ（直接法で使うタグ）
INTEREST_BEARING_DEBT_TAGS: list[str] = [
    "InterestBearingDebt",
    "InterestBearingLiabilities",
]

# 各コンポーネントのラベルと候補タグ名（J-GAAP → IFRS の優先順）
COMPONENT_DEFINITIONS: list[_ComponentDef] = [
    {
        "label": "短期借入金",
        "tags": [
            "ShortTermLoansPayable",        # J-GAAP
            "BorrowingsCLIFRS",             # IFRS 流動負債 借入金
        ],
    },
    {
        "label": "コマーシャル・ペーパー",
        "tags": [
            "CommercialPapersLiabilities",  # J-GAAP
            "CommercialPapersCLIFRS",       # IFRS
        ],
    },
    {
        "label": "短期社債",
        "tags": [
            "ShortTermBondsPayable",        # J-GAAP
        ],
    },
    {
        "label": "1年内償還予定の社債",
        "tags": [
            "CurrentPortionOfBonds",                    # J-GAAP
            "RedeemableBondsWithinOneYear",             # J-GAAP 別名
            "CurrentPortionOfBondsCLIFRS",              # IFRS
        ],
    },
    {
        "label": "1年内返済予定の長期借入金",
        "tags": [
            "CurrentPortionOfLongTermLoansPayable",     # J-GAAP
            "CurrentPortionOfLongTermBorrowingsCLIFRS", # IFRS 粒度別
            "CurrentPortionOfLongTermDebtCLIFRS",       # IFRS 集約（社債+借入金の流動部分合計）
        ],
    },
    {
        "label": "社債",
        "tags": [
            "BondsPayable",                 # J-GAAP
            "BondsPayableNCLIFRS",          # IFRS 非流動負債
        ],
    },
    {
        "label": "長期借入金",
        "tags": [
            "LongTermLoansPayable",         # J-GAAP
            "BorrowingsNCLIFRS",            # IFRS 非流動負債 借入金（粒度別）
            "LongTermDebtNCLIFRS",          # IFRS 非流動負債 集約（社債+借入金合計）
        ],
    },
    {
        "label": "リース負債（流動）",
        "tags": [
            "LeaseObligationsCL",           # J-GAAP 流動リース負債
        ],
    },
    {
        "label": "リース負債（非流動）",
        "tags": [
            "LeaseObligationsNCL",          # J-GAAP 非流動リース負債
        ],
    },
]

# 売上総利益（GP）タグ定義
# analysis/gross_profit.py で使用

# 営業収益（売上高に相当するトップライン）タグ
OPERATING_REVENUE_TAGS: list[str] = [
    "OperatingRevenue1",                         # J-GAAP 営業収益
    "OperatingRevenue1SummaryOfBusinessResults", # J-GAAP 営業収益（要約情報）
]

# 売上総利益合計タグ（直接法）
# EDINET XBRL では IFRS連結は "IFRS" サフィックス付き、J-GAAP連結はサフィックスなし
GROSS_PROFIT_DIRECT_TAGS: list[str] = [
    "GrossProfitIFRS",                          # IFRS連結（例: 味の素, 日立）
    "GrossProfit",                              # J-GAAP連結（例: ニチレイ）
    "GrossProfitOnCompletedConstructionContractsCNS",  # 建設業: 完成工事総利益
]

OPERATING_GROSS_PROFIT_DIRECT_TAGS: list[str] = [
    "OperatingGrossProfit",  # J-GAAP 営業総利益（倉庫・運輸等）
]

# 売上総利益 計算法コンポーネント（直接タグが存在しない場合のフォールバック）
# 売上高 − 売上原価 で計算する
GROSS_PROFIT_COMPONENT_DEFINITIONS: list[_ComponentDef] = [
    {
        "label": "売上高",
        "tags": [
            "NetSalesIFRS",     # IFRS連結
            "RevenueIFRS",      # IFRS連結（日立等の売上収益）
            "NetSales",         # J-GAAP連結
            "Revenue",          # IFRS代替
            "Revenues",         # US-GAAP
            "RevenuesUSGAAPSummaryOfBusinessResults",  # US-GAAP 要約情報
            "NetSalesOfCompletedConstructionContractsCNS",  # 建設業: 完成工事高
            *OPERATING_REVENUE_TAGS,
        ],
    },
    {
        "label": "売上原価",
        "tags": [
            "CostOfSalesIFRS",  # IFRS連結
            "CostOfSales",      # J-GAAP連結
            "CostOfRevenue",    # US-GAAP
            "OperatingCost",    # J-GAAP 営業原価
            "CostOfSalesOfCompletedConstructionContractsCNS",  # 建設業: 完成工事原価
        ],
    },
]

BUSINESS_GROSS_PROFIT_COMPONENT_DEFINITIONS: list[_SignedComponentDef] = [
    {
        "label": "資金運用収益",
        "tags": ["InterestIncomeOIBNK"],
        "sign": 1,
    },
    {
        "label": "資金調達費用",
        "tags": ["InterestExpensesOEBNK"],
        "sign": -1,
    },
    {
        "label": "信託報酬",
        "tags": ["TrustFeesBNK"],
        "sign": 1,
    },
    {
        "label": "役務取引等収益",
        "tags": ["FeesAndCommissionsOIBNK"],
        "sign": 1,
    },
    {
        "label": "役務取引等費用",
        "tags": ["FeesAndCommissionsPaymentsOEBNK"],
        "sign": -1,
    },
    {
        "label": "特定取引収益",
        "tags": ["TradingIncomeOIBNK"],
        "sign": 1,
    },
    {
        "label": "特定取引費用",
        "tags": ["TradingExpensesOEBNK"],
        "sign": -1,
    },
    {
        "label": "その他業務収益",
        "tags": ["OtherOrdinaryIncomeOIBNK"],
        "sign": 1,
    },
    {
        "label": "その他業務費用",
        "tags": ["OtherOrdinaryExpensesOEBNK"],
        "sign": -1,
    },
]

# 複数の構成要素を集約したIFRSタグ。
# 粒度別タグが存在しない場合に、カバーする個別コンポーネントを置き換える。
# キャッシュフロー（CF）タグ定義
# analysis/cash_flow.py で使用

# 営業活動によるキャッシュフロー
CF_OPERATING_TAGS: list[str] = [
    "CashFlowsFromUsedInOperationsIFRS",                                # IFRS（間接法）
    "CashFlowsFromUsedInOperatingActivitiesIFRS",                       # IFRS（直接法）
    "CashFlowsFromUsedInOperatingActivitiesIFRSSummaryOfBusinessResults", # IFRS（決算短信）
    "CashFlowsFromUsedInOperatingActivitiesUSGAAPSummaryOfBusinessResults", # US-GAAP 要約情報
    "NetCashProvidedByUsedInOperatingActivities",                       # J-GAAP 連結（CF計算書）
    "NetCashProvidedByUsedInOperatingActivitiesSummaryOfBusinessResults", # J-GAAP 連結（決算短信）
]

# 投資活動によるキャッシュフロー
CF_INVESTING_TAGS: list[str] = [
    "CashFlowsUsedInInvestingActivitiesIFRS",                           # IFRS
    "CashFlowsFromUsedInInvestingActivitiesIFRS",                       # IFRS（代替）
    "CashFlowsFromUsedInInvestingActivitiesIFRSSummaryOfBusinessResults", # IFRS（決算短信）
    "CashFlowsFromUsedInInvestingActivitiesUSGAAPSummaryOfBusinessResults", # US-GAAP 要約情報
    "NetCashProvidedByUsedInInvestingActivities",                       # J-GAAP 連結（CF計算書）
    "NetCashProvidedByUsedInInvestmentActivities",                      # J-GAAP 連結（表記ゆれ）
    "NetCashProvidedByUsedInInvestingActivitiesSummaryOfBusinessResults", # J-GAAP 連結（決算短信）
]

# 設備投資（CapEx）タグ定義
# analysis/capital_expenditure.py で使用

CAPEX_OVERVIEW_TAGS: list[str] = [
    "CapitalExpendituresOverviewOfCapitalExpendituresEtc",  # 設備投資等の概要（J-GAAP / IFRS 共通）
]

CAPEX_CF_JGAAP_TAGS: list[str] = [
    "PurchaseOfPropertyPlantAndEquipmentInvCF",             # J-GAAP CF計算書 有形固定資産の取得
]

CAPEX_CF_IFRS_TAGS: list[str] = [
    "AcquisitionOfPropertyPlantAndEquipmentInvCFIFRS",      # IFRS CF計算書 有形固定資産の取得
    "PurchaseOfPropertyPlantAndEquipmentInvCFIFRS",         # IFRS CF計算書 代替
]

# 自己株式取得（Share Buyback）タグ定義
# analysis/share_buyback.py で使用

SHARE_BUYBACK_JGAAP_TAGS: list[str] = [
    "PurchaseOfTreasuryStockFinCF",                         # J-GAAP CF計算書 自己株式の取得
]

SHARE_BUYBACK_IFRS_TAGS: list[str] = [
    "PaymentsForPurchaseOfTreasurySharesFinCFIFRS",         # IFRS CF計算書 自己株式の取得（jpigp_cor）
    "PurchaseOfTreasurySharesFinCFIFRS",                    # IFRS CF計算書 代替
    "AcquisitionOfTreasurySharesFinCFIFRS",                 # IFRS CF計算書 代替
    "ReissuanceRepurchaseOfTreasuryStockFinCFIFRS",         # IFRS CF計算書 会社固有タグ（トヨタ等）
    "PurchaseOfTreasurySharesSSIFRS",                       # IFRS 株主資本等変動計算書（最終フォールバック）
]

# 研究開発費（R&D Expenses）タグ定義
# analysis/research_development.py で使用

# J-GAAP / IFRS 共通: 「研究開発活動」セクションで開示される総額
RD_EXPENSE_COMMON_TAGS: list[str] = [
    "ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities",  # J-GAAP / IFRS（研究開発活動セクション）
]

# J-GAAP 固有: 損益計算書・販管費内で開示される場合のフォールバック
RD_EXPENSE_JGAAP_TAGS: list[str] = [
    "ResearchAndDevelopmentExpensesSGA",                    # 販管費内の研究開発費
    "ResearchAndDevelopmentExpenses",                       # 独立行項目の研究開発費
]

# IFRS 固有: フォールバック
RD_EXPENSE_IFRS_TAGS: list[str] = [
    "ResearchAndDevelopmentExpenditureRecognizedAsExpenseDuringPeriodIFRS",  # IFRS P&L（ホンダ等、セグメント別開示のみの企業）
    "ResearchAndDevelopmentExpensesIFRS",                   # IFRS 研究開発費
    "ResearchAndDevelopmentCostsIFRS",                      # IFRS 代替
]

# 実効税率（Tax）タグ定義
# analysis/tax_expense.py で使用

# 税引前利益
PRETAX_INCOME_JGAAP_TAGS: list[str] = [
    "IncomeBeforeIncomeTaxes",
]
PRETAX_INCOME_IFRS_TAGS: list[str] = [
    "ProfitLossBeforeTaxIFRS",
]

# 法人税等
INCOME_TAX_JGAAP_TAGS: list[str] = [
    "IncomeTaxes",
]
INCOME_TAX_IFRS_TAGS: list[str] = [
    "IncomeTaxExpenseIFRS",
]

IFRS_TAX_MARKER_TAGS: list[str] = (
    IFRS_PL_MARKER_TAGS
    + PRETAX_INCOME_IFRS_TAGS
    + INCOME_TAX_IFRS_TAGS
)

# 営業利益（OP）タグ定義
# analysis/operating_profit.py で使用

OPERATING_PROFIT_DIRECT_TAGS: list[str] = [
    "OperatingProfitLossIFRS",   # IFRS連結
    "OperatingIncomeLoss",       # J-GAAP連結（標準）
    "OperatingIncome",           # J-GAAP（旧タグ / 個別フォールバック）
]

ORDINARY_INCOME_TAGS: list[str] = [
    "OrdinaryIncome",            # J-GAAP 金融機関向け経常利益
    "OrdinaryIncomeLoss",        # J-GAAP 経常利益（代替）
    "OrdinaryIncomeLossSummaryOfBusinessResults",  # J-GAAP 経常利益（要約情報）
]

ORDINARY_REVENUE_TAGS: list[str] = [
    "OrdinaryIncomeBNK",  # 銀行等の経常収益
    "OrdinaryIncomeSummaryOfBusinessResults",  # 銀行等の経常収益（要約情報）
]

# 営業利益 計算法: GrossProfit − SGA で算出する
# OperatingProfitLossIFRS が存在しない IFRS 企業（日立等）向けフォールバック

SGA_DIRECT_TAGS: list[str] = [
    "SellingGeneralAndAdministrativeExpensesIFRS",  # IFRS連結
    "SellingGeneralAndAdministrativeExpenses",       # J-GAAP連結
]

# 支払利息（IE）タグ定義
# analysis/interest_expense.py で使用

# J-GAAP: 営業外費用の支払利息
INTEREST_EXPENSE_JGAAP_TAGS: list[str] = [
    "InterestExpensesNOE",
]

# IFRS: 支払利息タグ優先順
# InterestExpensesIFRS → IFRS 7注記の償却原価測定負債利息 → 同資産変形 → 金融費用合計（最終フォールバック）
# FinanceCostsIFRS は金融費用合計（支払利息＋その他）のため過大になることがある
INTEREST_EXPENSE_IFRS_TAGS: list[str] = [
    "InterestExpensesIFRS",                                              # 支払利息（P&L直接タグ）
    "FinancialLiabilitiesMeasuredAtAmortizedCostInterestExpensesIFRS",  # 償却原価測定金融負債の利息（クボタ等）
    "FinancialAssetsMeasuredAtAmortizedCostInterestExpensesIFRS",       # 同上（スズキ等の表記ゆれ）
    "FinanceCostsIFRS",                                                  # 金融費用合計（最終フォールバック）
]

IFRS_INTEREST_EXPENSE_MARKER_TAGS: list[str] = (
    IFRS_PL_MARKER_TAGS
    + INTEREST_EXPENSE_IFRS_TAGS
)

AGGREGATE_IFRS_DEFINITIONS: list[_AggregateIFRSDef] = [
    {
        "tag": "CurrentPortionOfLongTermDebtCLIFRS",  # 1年内長期有利子負債（社債+借入金を集約）
        "covers": ["1年内償還予定の社債", "1年内返済予定の長期借入金"],
    },
    {
        "tag": "LongTermDebtNCLIFRS",                 # 長期有利子負債（社債+借入金を集約）
        "covers": ["社債", "長期借入金"],
    },
    {
        "tag": "BondsAndBorrowingsCLIFRS",             # 流動負債 社債及び借入金（社債+借入金を集約）
        "covers": ["1年内償還予定の社債", "1年内返済予定の長期借入金"],
    },
    {
        "tag": "BondsAndBorrowingsNCLIFRS",            # 非流動負債 社債及び借入金（社債+借入金を集約）
        "covers": ["社債", "長期借入金"],
    },
    {
        "tag": "BondsBorrowingsAndLeaseLiabilitiesCLIFRS",  # 流動負債 社債、借入金及びリース負債
        "covers": ["短期借入金", "コマーシャル・ペーパー", "短期社債", "1年内償還予定の社債", "1年内返済予定の長期借入金"],
        "label": "流動有利子負債合計（リース負債含む）",
    },
    {
        "tag": "BondsBorrowingsAndLeaseLiabilitiesNCLIFRS",  # 非流動負債 社債、借入金及びリース負債
        "covers": ["社債", "長期借入金"],
        "label": "非流動有利子負債合計（リース負債含む）",
    },
    {
        "tag": "InterestBearingLiabilitiesCLIFRS",     # 流動有利子負債合計（全流動コンポーネントを集約）
        "covers": ["短期借入金", "コマーシャル・ペーパー", "短期社債", "1年内償還予定の社債", "1年内返済予定の長期借入金"],
        "label": "流動有利子負債合計（集約）",
    },
    {
        "tag": "InterestBearingLiabilitiesNCLIFRS",    # 非流動有利子負債合計（全非流動コンポーネントを集約）
        "covers": ["社債", "長期借入金"],
    },
]

# 損益計算書（IS）タグ定義
# analysis/income_statement.py で使用

# 売上高（Sales）タグ
NET_SALES_TAGS: list[str] = [
    "NetSalesIFRS",                             # IFRS連結
    "RevenueIFRS",                              # IFRS連結（日立等の売上収益）
    "RevenueIFRSSummaryOfBusinessResults",      # IFRS 要約情報（味の素等）
    "Revenue",                                  # IFRS代替
    "OperatingRevenuesIFRSKeyFinancialData",    # IFRS 要約情報（スズキ等）
    "OperatingRevenuesIFRSSummaryOfBusinessResults", # IFRS 要約情報
    "Revenues",                                 # US-GAAP
    "RevenuesUSGAAPSummaryOfBusinessResults",   # US-GAAP 要約情報
    "NetSales",                                 # J-GAAP連結
    "NetSalesSummaryOfBusinessResults",         # J-GAAP 要約情報（決算短信）
    "NetSalesOfCompletedConstructionContractsCNS",                           # 建設業: 完成工事高
    "NetSalesOfCompletedConstructionContractsSummaryOfBusinessResults",      # 建設業: 完成工事高（決算短信）
    *OPERATING_REVENUE_TAGS,
]

# 当期純利益（Net Profit）タグ（親会社帰属 → PL全体の優先順）
NET_PROFIT_TAGS: list[str] = [
    "ProfitLossAttributableToOwnersOfParentIFRS",          # IFRS連結 親会社帰属
    "ProfitLossAttributableToOwnersOfParentIFRSSummaryOfBusinessResults", # IFRS 要約情報
    "NetIncomeLossAttributableToOwnersOfParentUSGAAP",      # US-GAAP 親会社帰属
    "NetIncomeLossAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults", # US-GAAP 要約情報
    "NetIncomeLoss",                                        # US-GAAP 代替
    "ProfitLossAttributableToOwnersOfParent",               # J-GAAP連結 親会社帰属
    "ProfitLoss",                                           # J-GAAP連結 全体
    "NetIncomeLossSummaryOfBusinessResults",                # J-GAAP 要約情報
]

# 減価償却費（DA）タグ定義
# analysis/depreciation.py で使用

CF_DEPRECIATION_JGAAP_TAGS: list[str] = [
    "DepreciationAndAmortizationOpeCF",      # J-GAAP CF計算書（間接法）調整項目
]

CF_DEPRECIATION_IFRS_TAGS: list[str] = [
    "DepreciationAndAmortizationOpeCFIFRS",                   # IFRS CF計算書（一般的）
    "DepreciationAndAmortizationOfIntangibleAssetsOpeCFIFRS", # IFRS CF計算書（日立等）
]

IFRS_DEPRECIATION_MARKER_TAGS: list[str] = (
    IFRS_PL_MARKER_TAGS
    + CF_DEPRECIATION_IFRS_TAGS
)

# ──────────────────────────────────────────────────────────────────────────────
# field_parser ベース BS・IBD 項目定義
# analysis/balance_sheet.py / interest_bearing_debt.py で使用
# ──────────────────────────────────────────────────────────────────────────────

# J-GAAP / IFRS / US-GAAP 共通 BS 項目定義
# 各 tags リストは優先順（最初に値が取れたタグを採用）
ALL_STANDARD_BS_ITEMS: list[_StandardBSItemDef] = [
    {
        "field": "TotalAssets",
        "label": "資産合計",
        "tags": [
            "TotalAssets", "Assets",
            "TotalAssetsIFRS", "AssetsIFRS",
            "TotalAssetsIFRSSummaryOfBusinessResults",
            "TotalAssetsUSGAAP",
            "TotalAssetsSummaryOfBusinessResults",
            "TotalAssetsUSGAAPSummaryOfBusinessResults",
        ],
    },
    {
        "field": "CurrentAssets",
        "label": "流動資産",
        "tags": [
            "CurrentAssets",
            "CurrentAssetsIFRS",
            "CurrentAssetsUSGAAP",
            "USGAAP_HTML_CurrentAssets",
        ],
    },
    {
        "field": "NonCurrentAssets",
        "label": "非流動資産",
        "tags": [
            "NoncurrentAssets", "NonCurrentAssets",
            "NonCurrentAssetsIFRS",
            "NonCurrentAssetsUSGAAP",
        ],
        "derive": {
            "minuend_tags": [
                "TotalAssets", "Assets", "TotalAssetsIFRS", "AssetsIFRS",
                "TotalAssetsIFRSSummaryOfBusinessResults", "TotalAssetsUSGAAP",
                "TotalAssetsUSGAAPSummaryOfBusinessResults",
            ],
            "subtrahend_tags": [
                "CurrentAssets", "CurrentAssetsIFRS", "CurrentAssetsUSGAAP",
                "USGAAP_HTML_CurrentAssets",
            ],
        },
    },
    {
        "field": "CurrentLiabilities",
        "label": "流動負債",
        "tags": [
            "CurrentLiabilities",
            "TotalCurrentLiabilitiesIFRS", "CurrentLiabilitiesIFRS",
            "CurrentLiabilitiesUSGAAP",
            "USGAAP_HTML_CurrentLiabilities",
        ],
    },
    {
        "field": "NonCurrentLiabilities",
        "label": "非流動負債",
        "tags": [
            "NoncurrentLiabilities", "NonCurrentLiabilities",
            "NonCurrentLiabilitiesIFRS",
            "LongTermLiabilitiesUSGAAP", "NonCurrentLiabilitiesUSGAAP",
            "USGAAP_HTML_NonCurrentLiabilities",
        ],
        "derive": {
            "minuend_tags": [
                "Liabilities", "LiabilitiesIFRS", "TotalLiabilitiesUSGAAP",
                "USGAAP_HTML_TotalLiabilities",
            ],
            "subtrahend_tags": [
                "CurrentLiabilities",
                "TotalCurrentLiabilitiesIFRS", "CurrentLiabilitiesIFRS",
                "CurrentLiabilitiesUSGAAP",
                "USGAAP_HTML_CurrentLiabilities",
            ],
        },
    },
    {
        "field": "NetAssets",
        "label": "純資産/資本合計",
        "tags": [
            # IFRSタグを先に置き、IFRS要約情報タグ（SummaryOfBusinessResults）も
            # J-GAAP の NetAssets より優先する。IFRS企業で詳細連結BSタグが存在しない
            # 場合に要約情報から取得できるようにするための順序。
            "EquityIFRS", "TotalEquityIFRS",
            "TotalEquityIFRSSummaryOfBusinessResults",
            "EquityIncludingPortionAttributableToNonControllingInterestIFRSSummaryOfBusinessResults",
            "NetAssets",
            "NetAssetsUSGAAP", "TotalEquityUSGAAP",
            "EquityIncludingPortionAttributableToNonControllingInterestUSGAAPSummaryOfBusinessResults",
            "USGAAP_HTML_NetAssets",
            "NetAssetsSummaryOfBusinessResults",
            "EquityAttributableToOwnersOfParentIFRS",
            "EquityAttributableToOwnersOfParentUSGAAP",
            "EquityAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults",
        ],
    },
]

# US-GAAP 非流動資産コンポーネント（HTML 仮想タグ積み上げ）
USGAAP_HTML_NCA_COMPONENTS: list[list[str]] = [
    ["USGAAP_HTML_PPENet"],
    ["USGAAP_HTML_InvestmentsLTReceivables"],
    ["USGAAP_HTML_OtherNCA"],
]

# US-GAAP 非流動資産コンポーネント（XBRL タグ積み上げ — HTML が存在しない場合のフォールバック）
USGAAP_XBRL_NCA_COMPONENTS: list[list[str]] = [
    ["InvestmentsAndLongTermReceivablesUSGAAP"],
    ["PropertyPlantAndEquipmentNetUSGAAP"],
    ["OtherAssetsUSGAAP"],
]

# 有利子負債（IBD）コンポーネント定義
# 各要素は「1コンポーネントの候補タグリスト（優先順）」
IBD_CURRENT_COMPONENTS: list[list[str]] = [
    ["ShortTermLoansPayable", "BorrowingsCLIFRS"],
    ["CommercialPapersLiabilities", "CommercialPapersCLIFRS"],
    ["ShortTermBondsPayable"],
    ["CurrentPortionOfBonds", "RedeemableBondsWithinOneYear", "CurrentPortionOfBondsCLIFRS"],
    ["CurrentPortionOfLongTermLoansPayable", "CurrentPortionOfLongTermBorrowingsCLIFRS", "CurrentPortionOfLongTermDebtCLIFRS"],
    ["LeaseObligationsCL"],
]
IBD_NON_CURRENT_COMPONENTS: list[list[str]] = [
    ["BondsPayable", "BondsPayableNCLIFRS"],
    ["LongTermLoansPayable", "BorrowingsNCLIFRS", "LongTermDebtNCLIFRS"],
    ["LeaseObligationsNCL"],
]

# IFRS 集約タグ（流動・非流動それぞれ1タグで全コンポーネントを集約）
IBD_IFRS_CL_TAGS: list[str] = [
    "InterestBearingLiabilitiesCLIFRS",
    "BondsAndBorrowingsCLIFRS",
    "BondsBorrowingsAndLeaseLiabilitiesCLIFRS",
]
IBD_IFRS_NCL_TAGS: list[str] = [
    "InterestBearingLiabilitiesNCLIFRS",
    "BondsAndBorrowingsNCLIFRS",
    "BondsBorrowingsAndLeaseLiabilitiesNCLIFRS",
]

# 有形固定資産（PPE）タグ定義
# analysis/tangible_fixed_assets.py で使用
# _bs_all_tags() 用の全タグ収集リスト（会計基準混在）
PPE_TOTAL_TAGS: list[str] = [
    "PropertyPlantAndEquipmentIFRS",
    "PropertyPlantAndEquipment",
    "PropertyPlantAndEquipmentNetUSGAAP",
    "PropertyPlantAndEquipmentUSGAAP",
]
PPE_BUILDINGS_TAGS: list[str] = ["BuildingsAndStructuresIFRS", "BuildingsAndStructuresNet", "BuildingsNet", "StructuresNet"]
PPE_LAND_TAGS: list[str] = ["LandIFRS", "Land"]
PPE_MACHINERY_TAGS: list[str] = ["MachineryAndVehiclesIFRS", "MachineryAndEquipmentAndOthersIFRS", "MachineryEquipmentAndVehiclesNet", "MachineryAndEquipmentNet"]
PPE_TOOLS_TAGS: list[str] = ["ToolsFurnitureAndFixturesIFRS", "ToolsFurnitureAndFixturesNet"]
PPE_CONSTRUCTION_TAGS: list[str] = ["ConstructionInProgressIFRS", "ConstructionInProgress"]

# IFRS 専用直接タグ（帳簿価額）
PPE_TOTAL_IFRS_DIRECT: list[str] = ["PropertyPlantAndEquipmentIFRS"]
PPE_BUILDINGS_IFRS_DIRECT: list[str] = ["BuildingsAndStructuresIFRS"]
PPE_LAND_IFRS_DIRECT: list[str] = ["LandIFRS"]
PPE_MACHINERY_IFRS_DIRECT: list[str] = [
    "MachineryAndVehiclesIFRS",           # 一般（クボタ等は使わない）
    "MachineryAndEquipmentAndOthersIFRS", # クボタ等「機械装置及びその他」
]
PPE_TOOLS_IFRS_DIRECT: list[str] = ["ToolsFurnitureAndFixturesIFRS"]
PPE_CONSTRUCTION_IFRS_DIRECT: list[str] = ["ConstructionInProgressIFRS"]

# J-GAAP 専用直接タグ（帳簿価額）
PPE_TOTAL_JGAAP_DIRECT: list[str] = ["PropertyPlantAndEquipment"]
PPE_BUILDINGS_JGAAP_DIRECT: list[str] = ["BuildingsAndStructuresNet"]
# 建物のみ・構築物のみを個別報告する場合の合算用タグ
PPE_BUILDINGS_ONLY_JGAAP_TAGS: list[str] = ["BuildingsNet"]
PPE_STRUCTURES_JGAAP_TAGS: list[str] = ["StructuresNet"]
PPE_LAND_JGAAP_DIRECT: list[str] = ["Land"]
PPE_MACHINERY_JGAAP_DIRECT: list[str] = ["MachineryEquipmentAndVehiclesNet", "MachineryAndEquipmentNet"]
PPE_TOOLS_JGAAP_DIRECT: list[str] = ["ToolsFurnitureAndFixturesNet"]
PPE_CONSTRUCTION_JGAAP_DIRECT: list[str] = ["ConstructionInProgress"]

# US-GAAP 専用合計タグ（内訳は未サポート）
# USGAAP_HTML_PPENet は parse_usgaap_html_bs_fields が HTML 連結貸借対照表から生成する仮想タグ
PPE_TAGS_USGAAP_TOTAL: list[str] = [
    "USGAAP_HTML_PPENet",
    "PropertyPlantAndEquipmentNetUSGAAP",
    "PropertyPlantAndEquipmentUSGAAP",
]

# 取得原価 - 累計減価償却・減損 による帳簿価額差引計算用（IFRS 直接タグが存在しない場合のフォールバック）
PPE_TOTAL_COST_TAGS: list[str] = ["PropertyPlantAndEquipmentAcquisitionCostIFRS"]
PPE_TOTAL_DEP_TAGS: list[str] = ["PropertyPlantAndEquipmentAccumulatedDepreciationAndImpairmentLossesIFRS"]
PPE_BUILDINGS_COST_TAGS: list[str] = ["BuildingsAcquisitionCostIFRS"]
PPE_BUILDINGS_DEP_TAGS: list[str] = ["BuildingsAccumulatedDepreciationAndImpairmentLossesIFRS"]
PPE_LAND_COST_TAGS: list[str] = ["LandAcquisitionCostIFRS"]
PPE_LAND_DEP_TAGS: list[str] = ["LandAccumulatedImpairmentLossesIFRS"]
PPE_MACHINERY_COST_TAGS: list[str] = [
    "MachineryAndEquipmentAcquisitionCostIFRS",
    "MachineryAndEquipmentAndOthersAcquisitionCostIFRS",  # クボタ等「機械装置及びその他」
]
PPE_MACHINERY_DEP_TAGS: list[str] = [
    "MachineryAndEquipmentAccumulatedDepreciationAndImpairmentLossesIFRS",
    "MachineryAndEquipmentAndOthersAccumulatedDepreciationAndImpairmentLossesIFRS",  # クボタ等
]
PPE_CONSTRUCTION_COST_TAGS: list[str] = ["ConstructionInProgressAcquisitionCostIFRS"]
PPE_CONSTRUCTION_DEP_TAGS: list[str] = ["ConstructionInProgressAccumulatedImpairmentLossesIFRS"]
# 賃貸用車両及び器具（IFRS tools フォールバック。ToolsFurnitureAndFixturesIFRS が存在しない場合に使用）
PPE_LEASED_VEHICLES_COST_TAGS: list[str] = ["VehiclesAndEquipmentOnOperatingLeasesAcquisitionCostIFRS"]
PPE_LEASED_VEHICLES_DEP_TAGS: list[str] = ["VehiclesAndEquipmentOnOperatingLeasesAccumulatedDepreciationAndImpairmentIFRS"]

# 銀行業 貸借対照表固有タグ（_BNK suffix）
# analysis/bank_financials.py で使用

BANK_DEPOSITS_TAGS: list[str] = [
    "DepositsLiabilitiesBNK",  # J-GAAP 預金（負債）
]

BANK_LOANS_TAGS: list[str] = [
    "LoansAndBillsDiscountedAssetsBNK",  # J-GAAP 貸出金（資産）
]

BANK_CASH_DUE_FROM_BANKS_TAGS: list[str] = [
    "CashAndDueFromBanksAssetsBNK",  # J-GAAP 現金預け金（銀行業）
    "CashAndDepositsAssetsINS",       # J-GAAP 現金預け金（保険・フィナンシャルグループ）
]

BANK_NEGOTIABLE_CD_TAGS: list[str] = [
    "NegotiableCertificatesOfDepositLiabilitiesBNK",  # J-GAAP 譲渡性預金（負債）
]
