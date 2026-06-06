"""
XBRL財務諸表セクション抽象化レイヤー

  XbrlTagElements → Section → 各分析モジュール

Section が Duration/Instant の判定・FieldSet 構築・会計基準の管理を内包する。
分析モジュールは Section.resolve() 等を呼ぶだけでよく、XBRL 構造を意識しない。

セクション一覧:
  IncomeStatementSection  - 損益計算書（Duration）
  CashFlowSection         - CF計算書（Duration）
  BalanceSheetSection     - 貸借対照表（Instant）
  EquityStatementSection  - 株主資本等変動計算書（Duration）
  NotesSection            - 連結財務諸表注記（Instant/Duration 混在）
  SummarySection          - 主要な経営指標等の推移（Duration）
  EmployeeSection         - 従業員の状況（Instant）
"""

from collections.abc import Mapping
from pathlib import Path

from blue_ticker.analysis.field_parser import (
    FieldSet,
    FieldValue,
    ResolvedItem,
    build_nc_duration_field_set,
    derive_subtraction,
    field_set_from_pre_parsed,
    field_set_from_pre_parsed_duration,
    parse_duration_fields,
    parse_instant_fields,
    resolve_aggregate,
    resolve_item,
    resolve_item_prefer_current,
)
from blue_ticker.analysis.usgaap.html_fields import (
    parse_usgaap_html_bs_fields,
    parse_usgaap_html_equity_cf_fields,
    parse_usgaap_html_pl_fields,
)
from blue_ticker.constants.xbrl import (
    ALL_STANDARD_BS_ITEMS,
    BANK_BORROWED_MONEY_TAGS,
    BANK_CASH_DUE_FROM_BANKS_TAGS,
    BANK_DEPOSITS_TAGS,
    BANK_LOANS_TAGS,
    BANK_NEGOTIABLE_CD_TAGS,
    BUSINESS_GROSS_PROFIT_COMPONENT_DEFINITIONS,
    CAPEX_CF_IFRS_TAGS,
    CAPEX_CF_JGAAP_TAGS,
    CAPEX_OVERVIEW_TAGS,
    CF_DEPRECIATION_IFRS_TAGS,
    CF_DEPRECIATION_JGAAP_TAGS,
    CF_INVESTING_TAGS,
    CF_OPERATING_TAGS,
    COMPONENT_DEFINITIONS,
    GROSS_PROFIT_COMPONENT_DEFINITIONS,
    GROSS_PROFIT_DIRECT_TAGS,
    IBD_CURRENT_COMPONENTS,
    IBD_IFRS_CL_TAGS,
    IBD_IFRS_NCL_TAGS,
    IBD_NON_CURRENT_COMPONENTS,
    IFRS_DEPRECIATION_MARKER_TAGS,
    IFRS_INTEREST_EXPENSE_MARKER_TAGS,
    IFRS_PL_MARKER_TAGS,
    IFRS_TAX_MARKER_TAGS,
    INCOME_TAX_IFRS_TAGS,
    INCOME_TAX_JGAAP_TAGS,
    INTEREST_EXPENSE_IFRS_TAGS,
    INTEREST_EXPENSE_JGAAP_TAGS,
    NET_PROFIT_TAGS,
    NET_SALES_TAGS,
    OPERATING_GROSS_PROFIT_DIRECT_TAGS,
    OPERATING_PROFIT_DIRECT_TAGS,
    OPERATING_REVENUE_TAGS,
    ORDINARY_INCOME_TAGS,
    ORDINARY_REVENUE_TAGS,
    PPE_BUILDINGS_COST_TAGS,
    PPE_BUILDINGS_DEP_TAGS,
    PPE_BUILDINGS_TAGS,
    PPE_CONSTRUCTION_COST_TAGS,
    PPE_CONSTRUCTION_DEP_TAGS,
    PPE_CONSTRUCTION_TAGS,
    PPE_LAND_COST_TAGS,
    PPE_LAND_DEP_TAGS,
    PPE_LAND_TAGS,
    PPE_LEASED_VEHICLES_COST_TAGS,
    PPE_LEASED_VEHICLES_DEP_TAGS,
    PPE_MACHINERY_COST_TAGS,
    PPE_MACHINERY_DEP_TAGS,
    PPE_MACHINERY_TAGS,
    PPE_TOOLS_TAGS,
    PPE_TOTAL_COST_TAGS,
    PPE_TOTAL_DEP_TAGS,
    PPE_TOTAL_TAGS,
    PRETAX_INCOME_IFRS_TAGS,
    PRETAX_INCOME_JGAAP_TAGS,
    RD_EXPENSE_COMMON_TAGS,
    RD_EXPENSE_IFRS_TAGS,
    RD_EXPENSE_JGAAP_TAGS,
    SGA_DIRECT_TAGS,
    SHARE_BUYBACK_IFRS_TAGS,
    SHARE_BUYBACK_JGAAP_TAGS,
    SHARE_BUYBACK_SS_JGAAP_TAGS,
    USGAAP_MARKER_TAGS,
    USGAAP_XBRL_NCA_COMPONENTS,
)
from blue_ticker.utils.xbrl_result_types import XbrlTagElements


def detect_accounting_standard(tags: Mapping[str, object]) -> str:
    """会計基準を判定する（J-GAAP / IFRS / US-GAAP）。XbrlTagElements・FieldSet いずれも受け付ける。"""
    has_usgaap = any("USGAAP" in tag for tag in tags)
    has_ifrs = any("IFRS" in tag for tag in tags)
    if has_usgaap and not has_ifrs:
        return "US-GAAP"
    if has_ifrs:
        return "IFRS"
    return "J-GAAP"


class Section:
    """財務諸表セクションの基底クラス。FieldSet を内包し resolve メソッドを提供する。"""

    _TAGS: frozenset[str] = frozenset()

    def __init__(
        self,
        field_set: FieldSet,
        accounting_standard: str,
        xbrl_dir: Path | None = None,
    ) -> None:
        self._field_set = field_set
        self.accounting_standard = accounting_standard
        self.xbrl_dir = xbrl_dir

    def resolve(self, candidate_tags: list[str]) -> ResolvedItem:
        return resolve_item(self._field_set, candidate_tags)

    def resolve_prefer_current(self, candidate_tags: list[str]) -> ResolvedItem:
        return resolve_item_prefer_current(self._field_set, candidate_tags)

    def resolve_aggregate(self, component_tag_lists: list[list[str]]) -> ResolvedItem:
        return resolve_aggregate(self._field_set, component_tag_lists)

    def derive_subtraction(self, minuend_tags: list[str], subtrahend_tags: list[str]) -> ResolvedItem:
        return derive_subtraction(self._field_set, minuend_tags, subtrahend_tags)

    def __contains__(self, tag: str) -> bool:
        return tag in self._field_set

    def field_value(self, tag: str) -> FieldValue | None:
        return self._field_set.get(tag)


# ── 損益計算書 ──────────────────────────────────────────────────────────────

_IS_TAGS: frozenset[str] = frozenset(
    NET_SALES_TAGS
    + OPERATING_PROFIT_DIRECT_TAGS
    + NET_PROFIT_TAGS
    + GROSS_PROFIT_DIRECT_TAGS
    + OPERATING_GROSS_PROFIT_DIRECT_TAGS
    + [tag for comp in GROSS_PROFIT_COMPONENT_DEFINITIONS for tag in comp["tags"]]
    + [tag for comp in BUSINESS_GROSS_PROFIT_COMPONENT_DEFINITIONS for tag in comp["tags"]]
    + ORDINARY_REVENUE_TAGS
    + OPERATING_REVENUE_TAGS
    + ORDINARY_INCOME_TAGS
    + SGA_DIRECT_TAGS
    + INTEREST_EXPENSE_JGAAP_TAGS
    + INTEREST_EXPENSE_IFRS_TAGS
    + IFRS_INTEREST_EXPENSE_MARKER_TAGS
    + PRETAX_INCOME_JGAAP_TAGS
    + PRETAX_INCOME_IFRS_TAGS
    + INCOME_TAX_JGAAP_TAGS
    + INCOME_TAX_IFRS_TAGS
    + IFRS_TAX_MARKER_TAGS
    + ["NetRevenueIFRS", "BusinessProfitIFRSSummaryOfBusinessResults"]
    + USGAAP_MARKER_TAGS
    + IFRS_PL_MARKER_TAGS
    + RD_EXPENSE_COMMON_TAGS
    + RD_EXPENSE_JGAAP_TAGS
    + RD_EXPENSE_IFRS_TAGS
)


class IncomeStatementSection(Section):
    """損益計算書セクション（Duration コンテキスト）。

    対象: 売上高・粗利・営業利益・純利益・支払利息・税引前利益・法人税・EPS
    """

    _TAGS = _IS_TAGS

    @classmethod
    def from_xbrl(cls, xbrl_dir: Path, accounting_standard: str | None = None) -> "IncomeStatementSection":
        field_set = parse_duration_fields(xbrl_dir, allowed_tags=cls._TAGS)
        std = accounting_standard or detect_accounting_standard(field_set)
        if std == "US-GAAP":
            field_set.update(parse_usgaap_html_pl_fields(xbrl_dir))
        return cls(field_set, std, xbrl_dir)

    @classmethod
    def from_pre_parsed(
        cls,
        tag_elements: XbrlTagElements,
        accounting_standard: str,
        xbrl_dir: Path | None = None,
    ) -> "IncomeStatementSection":
        field_set = field_set_from_pre_parsed_duration(tag_elements, financial_tags=_ALL_FINANCIAL_TAGS)
        if accounting_standard == "US-GAAP" and xbrl_dir is not None:
            field_set.update(parse_usgaap_html_pl_fields(xbrl_dir))
        return cls(field_set, accounting_standard, xbrl_dir)


# ── CF計算書 ────────────────────────────────────────────────────────────────

_CF_TAGS: frozenset[str] = frozenset(
    CF_OPERATING_TAGS
    + CF_INVESTING_TAGS
    + CF_DEPRECIATION_JGAAP_TAGS
    + CF_DEPRECIATION_IFRS_TAGS
    + IFRS_DEPRECIATION_MARKER_TAGS
    + USGAAP_MARKER_TAGS
    + IFRS_PL_MARKER_TAGS
    + CAPEX_OVERVIEW_TAGS
    + CAPEX_CF_JGAAP_TAGS
    + CAPEX_CF_IFRS_TAGS
    + SHARE_BUYBACK_SS_JGAAP_TAGS
    + SHARE_BUYBACK_JGAAP_TAGS
    + SHARE_BUYBACK_IFRS_TAGS
)


class CashFlowSection(Section):
    """CF計算書セクション（Duration コンテキスト）。

    対象: 営業CF・投資CF・減価償却費・自己株式取得
    """

    _TAGS = _CF_TAGS

    def __init__(
        self,
        field_set: FieldSet,
        accounting_standard: str,
        xbrl_dir: Path | None = None,
        nc_field_set: FieldSet | None = None,
    ) -> None:
        super().__init__(field_set, accounting_standard, xbrl_dir)
        self._nc_field_set: FieldSet = nc_field_set or {}

    def resolve_nonconsolidated(self, candidate_tags: list[str]) -> ResolvedItem:
        """NonConsolidated コンテキストの値を解決する（連結企業でも有効）。"""
        return resolve_item(self._nc_field_set, candidate_tags)

    @classmethod
    def from_xbrl(cls, xbrl_dir: Path, accounting_standard: str | None = None) -> "CashFlowSection":
        from blue_ticker.analysis.xbrl_utils import collect_numeric_elements, find_xbrl_files
        tag_elements: XbrlTagElements = {}
        for f in find_xbrl_files(xbrl_dir):
            for tag, ctx_map in collect_numeric_elements(f, allowed_tags=cls._TAGS).items():
                if tag not in tag_elements:
                    tag_elements[tag] = {}
                tag_elements[tag].update(ctx_map)
        field_set = field_set_from_pre_parsed_duration(tag_elements, financial_tags=_ALL_FINANCIAL_TAGS)
        std = accounting_standard or detect_accounting_standard(field_set)
        nc_field_set = build_nc_duration_field_set(tag_elements)
        if std == "US-GAAP":
            field_set.update(parse_usgaap_html_equity_cf_fields(xbrl_dir))
        return cls(field_set, std, xbrl_dir, nc_field_set)

    @classmethod
    def from_pre_parsed(
        cls,
        tag_elements: XbrlTagElements,
        accounting_standard: str,
        xbrl_dir: Path | None = None,
    ) -> "CashFlowSection":
        field_set = field_set_from_pre_parsed_duration(tag_elements, financial_tags=_ALL_FINANCIAL_TAGS)
        nc_field_set = build_nc_duration_field_set(tag_elements)
        if accounting_standard == "US-GAAP" and xbrl_dir is not None:
            field_set.update(parse_usgaap_html_equity_cf_fields(xbrl_dir))
        return cls(field_set, accounting_standard, xbrl_dir, nc_field_set)


# ── 貸借対照表 ──────────────────────────────────────────────────────────────

def _bs_all_tags() -> frozenset[str]:
    tags: list[str] = []
    for item in ALL_STANDARD_BS_ITEMS:
        tags.extend(item["tags"])
        if "derive" in item:
            tags.extend(item["derive"]["minuend_tags"])
            tags.extend(item["derive"]["subtrahend_tags"])
    tags += ["InterestBearingDebt", "InterestBearingLiabilities"]
    tags += IBD_IFRS_CL_TAGS
    tags += IBD_IFRS_NCL_TAGS
    for comp in COMPONENT_DEFINITIONS:
        tags.extend(comp["tags"])
    tags += USGAAP_MARKER_TAGS
    for group in USGAAP_XBRL_NCA_COMPONENTS:
        tags.extend(group)
    tags += PPE_TOTAL_TAGS
    tags += PPE_TOTAL_COST_TAGS
    tags += PPE_TOTAL_DEP_TAGS
    tags += PPE_BUILDINGS_TAGS
    tags += PPE_BUILDINGS_COST_TAGS
    tags += PPE_BUILDINGS_DEP_TAGS
    tags += PPE_LAND_TAGS
    tags += PPE_LAND_COST_TAGS
    tags += PPE_LAND_DEP_TAGS
    tags += PPE_MACHINERY_TAGS
    tags += PPE_MACHINERY_COST_TAGS
    tags += PPE_MACHINERY_DEP_TAGS
    tags += PPE_TOOLS_TAGS
    tags += PPE_CONSTRUCTION_TAGS
    tags += PPE_CONSTRUCTION_COST_TAGS
    tags += PPE_CONSTRUCTION_DEP_TAGS
    tags += PPE_LEASED_VEHICLES_COST_TAGS
    tags += PPE_LEASED_VEHICLES_DEP_TAGS
    tags += BANK_DEPOSITS_TAGS
    tags += BANK_LOANS_TAGS
    tags += BANK_CASH_DUE_FROM_BANKS_TAGS
    tags += BANK_NEGOTIABLE_CD_TAGS
    tags += BANK_BORROWED_MONEY_TAGS
    return frozenset(tags)


_BS_TAGS: frozenset[str] = _bs_all_tags()


class BalanceSheetSection(Section):
    """貸借対照表セクション（Instant コンテキスト）。

    対象: 資産・負債・純資産・有利子負債・現金等・親会社持分
    US-GAAP 企業は HTML パースで仮想タグを補完する。
    """

    _TAGS = _BS_TAGS

    @classmethod
    def from_xbrl(cls, xbrl_dir: Path, accounting_standard: str | None = None) -> "BalanceSheetSection":
        field_set = parse_instant_fields(xbrl_dir, allowed_tags=cls._TAGS)
        std = accounting_standard or detect_accounting_standard(field_set)
        if std == "US-GAAP":
            field_set.update(parse_usgaap_html_bs_fields(xbrl_dir))
        return cls(field_set, std, xbrl_dir)

    @classmethod
    def from_pre_parsed(
        cls,
        tag_elements: XbrlTagElements,
        accounting_standard: str,
        xbrl_dir: Path | None = None,
    ) -> "BalanceSheetSection":
        field_set = field_set_from_pre_parsed(tag_elements, financial_tags=_ALL_FINANCIAL_TAGS)
        if accounting_standard == "US-GAAP" and xbrl_dir is not None:
            field_set.update(parse_usgaap_html_bs_fields(xbrl_dir))
        return cls(field_set, accounting_standard, xbrl_dir)


# ── 株主資本等変動計算書 ────────────────────────────────────────────────────

_EQUITY_TAGS: frozenset[str] = frozenset([
    "TotalAmountOfDividendsDividendsOfSurplus",
    "DividendsFromSurplus",
])


class EquityStatementSection(Section):
    """株主資本等変動計算書セクション（Duration コンテキスト）。

    対象: 配当総額（DivTotalAnn）
    """

    _TAGS = _EQUITY_TAGS

    @classmethod
    def from_xbrl(
        cls, xbrl_dir: Path, accounting_standard: str | None = None
    ) -> "EquityStatementSection":
        field_set = parse_duration_fields(xbrl_dir, allowed_tags=cls._TAGS)
        std = accounting_standard or detect_accounting_standard(field_set)
        return cls(field_set, std)

    @classmethod
    def from_pre_parsed(
        cls, tag_elements: XbrlTagElements, accounting_standard: str
    ) -> "EquityStatementSection":
        field_set = field_set_from_pre_parsed_duration(tag_elements, financial_tags=_ALL_FINANCIAL_TAGS)
        return cls(field_set, accounting_standard)


# ── 連結財務諸表注記 ────────────────────────────────────────────────────────

_NOTES_TAGS: frozenset[str] = frozenset([
    # 発行済株式数
    "NumberOfIssuedSharesAsOfFiscalYearEndIssuedSharesTotalNumberOfSharesEtc",
    "NumberOfIssuedSharesAsOfFilingDateIssuedSharesTotalNumberOfSharesEtc",
    "TotalNumberOfIssuedSharesSummaryOfBusinessResults",
    # 自己株式数
    "TotalNumberOfSharesHeldTreasurySharesEtc",
    "NumberOfSharesHeldInOwnNameTreasurySharesEtc",
    # 平均発行済株式数
    "AverageNumberOfSharesDuringPeriodBasicEarningsLossPerShareInformation",
    "AverageNumberOfSharesDuringTheFiscalYearBasicEarningsLossPerShareInformation",
    "AverageNumberOfShares",
    "WeightedAverageNumberOfSharesOutstandingBasic",
    "WeightedAverageNumberOfOrdinarySharesOutstandingBasicIFRS",
])


class NotesSection(Section):
    """連結財務諸表注記セクション（Instant/Duration 混在）。

    対象（現状）: 発行済株式数・自己株式数・平均発行済株式数
    将来: セグメント別売上
    """

    _TAGS = _NOTES_TAGS

    @classmethod
    def from_xbrl(cls, xbrl_dir: Path, accounting_standard: str | None = None) -> "NotesSection":
        field_set = parse_instant_fields(xbrl_dir, allowed_tags=cls._TAGS)
        std = accounting_standard or detect_accounting_standard(field_set)
        return cls(field_set, std)

    @classmethod
    def from_pre_parsed(
        cls, tag_elements: XbrlTagElements, accounting_standard: str
    ) -> "NotesSection":
        field_set = field_set_from_pre_parsed(tag_elements, financial_tags=_ALL_FINANCIAL_TAGS)
        return cls(field_set, accounting_standard)


# ── 主要な経営指標等の推移 ──────────────────────────────────────────────────

_SUMMARY_TAGS: frozenset[str] = frozenset([
    "DividendPaidPerShareSummaryOfBusinessResults",
    "InterimDividendPaidPerShareSummaryOfBusinessResults",
    "PayoutRatioSummaryOfBusinessResults",
    "BasicEarningsLossPerShareSummaryOfBusinessResults",
    "BasicEarningsLossPerShareIFRSSummaryOfBusinessResults",
    "BasicEarningsLossPerShareUSGAAPSummaryOfBusinessResults",
    "NetAssetsPerShareSummaryOfBusinessResults",
    "EquityAttributableToOwnersOfParentPerShareIFRSSummaryOfBusinessResults",
    "EquityAttributableToOwnersOfParentPerShareUSGAAPSummaryOfBusinessResults",
    "EquityToAssetRatioIFRSSummaryOfBusinessResults",
    "CashAndCashEquivalentsSummaryOfBusinessResults",
    "CashAndCashEquivalentsIFRSSummaryOfBusinessResults",
    "CashAndCashEquivalentsUSGAAPSummaryOfBusinessResults",
    "EquityAttributableToOwnersOfParentIFRSSummaryOfBusinessResults",
    "EquityAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults",
])


class SummarySection(Section):
    """主要な経営指標等の推移セクション（Duration コンテキスト）。

    対象: 年間配当・中間配当・配当性向
    """

    _TAGS = _SUMMARY_TAGS

    @classmethod
    def from_xbrl(cls, xbrl_dir: Path, accounting_standard: str | None = None) -> "SummarySection":
        field_set = parse_duration_fields(xbrl_dir, allowed_tags=cls._TAGS)
        std = accounting_standard or detect_accounting_standard(field_set)
        return cls(field_set, std)

    @classmethod
    def from_pre_parsed(
        cls, tag_elements: XbrlTagElements, accounting_standard: str
    ) -> "SummarySection":
        field_set = field_set_from_pre_parsed_duration(tag_elements, financial_tags=_ALL_FINANCIAL_TAGS)
        return cls(field_set, accounting_standard)


# ── 従業員の状況 ────────────────────────────────────────────────────────────

_EMPLOYEE_TAGS_SET: frozenset[str] = frozenset([
    "NumberOfEmployees",
    "NumberOfGroupEmployees",
])

# 財務タグ全体（連結判定の精度向上のため from_pre_parsed に渡す）
# DEI タグ等の非財務タグを除外し、IS タグのシグナルを全 Section で共有するために使う。
_ALL_FINANCIAL_TAGS: frozenset[str] = (
    _IS_TAGS | _CF_TAGS | _BS_TAGS | _EQUITY_TAGS | _NOTES_TAGS | _SUMMARY_TAGS | _EMPLOYEE_TAGS_SET
)


class EmployeeSection(Section):
    """従業員の状況セクション（Instant コンテキスト）。

    tag_elements を保持し、連結/個別スコープの判定に使う。
    """

    _TAGS = _EMPLOYEE_TAGS_SET

    def __init__(
        self,
        field_set: FieldSet,
        accounting_standard: str,
        tag_elements: XbrlTagElements,
    ) -> None:
        super().__init__(field_set, accounting_standard)
        self._tag_elements = tag_elements

    @property
    def tag_elements(self) -> XbrlTagElements:
        return self._tag_elements

    @classmethod
    def from_xbrl(cls, xbrl_dir: Path, accounting_standard: str | None = None) -> "EmployeeSection":
        from blue_ticker.analysis.xbrl_utils import collect_numeric_elements, find_xbrl_files

        tag_elements: XbrlTagElements = {}
        for f in find_xbrl_files(xbrl_dir):
            for tag, ctx_map in collect_numeric_elements(f, allowed_tags=cls._TAGS).items():
                if tag not in tag_elements:
                    tag_elements[tag] = {}
                tag_elements[tag].update(ctx_map)
        field_set = field_set_from_pre_parsed(tag_elements)
        std = accounting_standard or detect_accounting_standard(tag_elements)
        return cls(field_set, std, tag_elements)

    @classmethod
    def from_pre_parsed(
        cls, tag_elements: XbrlTagElements, accounting_standard: str
    ) -> "EmployeeSection":
        field_set = field_set_from_pre_parsed(tag_elements, financial_tags=_ALL_FINANCIAL_TAGS)
        return cls(field_set, accounting_standard, tag_elements)
