"""
XBRL 抽出結果の TypedDict 定義
"""

from typing import NotRequired, TypedDict

XbrlTagElements = dict[str, dict[str, float]]
XbrlFactIndex = dict[str, dict[str, "XbrlFact"]]


class XbrlFact(TypedDict):
    """XBRL fact value with source metadata.

    value は数値抽出器互換の float。unitRef / decimals / role / label は
    開示上存在しない場合があるため NotRequired にする。
    """

    tag: str
    contextRef: str
    value: float
    consolidation: str
    unitRef: NotRequired[str]
    decimals: NotRequired[str]
    role: NotRequired[str]
    section: NotRequired[str]
    roles: NotRequired[list[str]]
    sections: NotRequired[list[str]]
    label: NotRequired[str]
    source_file: NotRequired[str]


class MetricComponent(TypedDict):
    label: str
    tag: str | None
    current: float | None
    prior: float | None


class GrossProfitResult(TypedDict):
    current: float | None
    prior: float | None
    method: str
    accounting_standard: str
    components: list[MetricComponent]
    docID: NotRequired[str]
    reason: NotRequired[str]
    current_sales: NotRequired[float | None]
    prior_sales: NotRequired[float | None]


class OperatingProfitResult(TypedDict):
    current: float | None
    prior: float | None
    method: str
    label: str
    accounting_standard: str
    docID: NotRequired[str]
    reason: NotRequired[str]
    current_sales: NotRequired[float | None]
    prior_sales: NotRequired[float | None]
    current_sga: NotRequired[float | None]
    prior_sga: NotRequired[float | None]


class InterestBearingDebtResult(TypedDict):
    current: float | None
    prior: float | None
    method: str
    accounting_standard: str
    components: list[MetricComponent]
    reason: NotRequired[str]


class BalanceSheetResult(TypedDict):
    total_assets: float | None
    current_assets: float | None
    non_current_assets: float | None
    current_liabilities: float | None
    non_current_liabilities: float | None
    net_assets: float | None
    accounting_standard: str
    method: str
    components: list[MetricComponent]
    reason: NotRequired[str]
    prior_net_assets: NotRequired[float | None]


class InterestExpenseResult(TypedDict):
    current: float | None
    prior: float | None
    method: str
    accounting_standard: str
    reason: NotRequired[str]


class TaxExpenseResult(TypedDict):
    pretax_income: float | None
    income_tax: float | None
    effective_tax_rate: float | None
    prior_pretax_income: float | None
    prior_income_tax: float | None
    prior_effective_tax_rate: float | None
    accounting_standard: str
    method: str
    reason: NotRequired[str]


class EmployeesResult(TypedDict):
    current: float | None
    prior: float | None
    method: str
    scope: str


class NetRevenueResult(TypedDict):
    net_revenue: float | None
    net_revenue_prior: float | None
    business_profit: float | None
    business_profit_prior: float | None
    found: bool


class CashFlowPeriod(TypedDict):
    current: float | None
    prior: float | None


class CashFlowResult(TypedDict):
    cfo: CashFlowPeriod
    cfi: CashFlowPeriod
    accounting_standard: str


class DepreciationResult(TypedDict):
    current: float | None
    prior: float | None
    accounting_standard: str
    method: str
    reason: NotRequired[str]


class OrderBookResult(TypedDict):
    order_intake: float | None
    order_backlog: float | None
    order_intake_prior: float | None
    order_backlog_prior: float | None
    method: str
    docID: NotRequired[str]
    reason: NotRequired[str]


class IncomeStatementResult(TypedDict):
    sales: float | None
    sales_prior: float | None
    sales_label: NotRequired[str]
    operating_profit: float | None
    operating_profit_prior: float | None
    net_profit: float | None
    net_profit_prior: float | None
    accounting_standard: str
    method: str
    reason: NotRequired[str]
    docID: NotRequired[str]


class TangibleFixedAssetsResult(TypedDict):
    """有形固定資産（PPE）の帳簿価額。金額は円単位。"""

    buildings: float | None           # 建物及び構築物
    land: float | None                # 土地
    machinery: float | None           # 機械装置及び運搬具
    tools: float | None               # 工具器具及び備品
    construction_in_progress: float | None  # 建設仮勘定
    others: float | None              # その他（合計 − 5項目の差分。None は合計未取得時）
    total: float | None               # 有形固定資産合計
    method: str
    accounting_standard: str
    reason: NotRequired[str]


class CapitalExpenditureResult(TypedDict):
    current: float | None
    prior: float | None
    method: str
    accounting_standard: str
    reason: NotRequired[str]


class ShareBuybackResult(TypedDict):
    current: float | None
    prior: float | None
    method: str
    accounting_standard: str
    reason: NotRequired[str]


class ResearchDevelopmentResult(TypedDict):
    current: float | None
    prior: float | None
    method: str
    accounting_standard: str
    reason: NotRequired[str]


class BankFinancialsResult(TypedDict):
    """銀行業固有 貸借対照表項目の抽出結果。金額は円単位。"""

    deposits: float | None
    deposits_prior: float | None
    loans: float | None
    loans_prior: float | None
    cash_due_from_banks: float | None
    cash_due_from_banks_prior: float | None
    negotiable_cds: float | None
    negotiable_cds_prior: float | None
    accounting_standard: str
    method: str
    reason: NotRequired[str]


class HalfYearEdinetEntry(TypedDict):
    gp: GrossProfitResult
    op: OperatingProfitResult
    cf: CashFlowResult
    ibd: InterestBearingDebtResult
