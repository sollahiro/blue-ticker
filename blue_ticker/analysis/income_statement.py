"""
損益計算書 XBRL 抽出モジュール

XBRLインスタンス文書から連結損益計算書の
売上高・営業利益・当期純利益を抽出する。

EDINET-only運用時の基幹財務データ取得に使用する。

タグ体系:
  J-GAAP:   NetSales / OperatingIncomeLoss / ProfitLossAttributableToOwnersOfParent
  IFRS連結:  NetSalesIFRS / OperatingProfitLossIFRS / ProfitLossAttributableToOwnersOfParentIFRS
  US-GAAP:   Revenues / (OperatingIncomeLoss) / NetIncomeLossAttributableToOwnersOfParentUSGAAP

コンテキスト:
  損益計算書はフロー項目なので Duration コンテキストを使用する。
"""

from blue_ticker.analysis.sections import IncomeStatementSection
from blue_ticker.constants.xbrl import (
    NET_PROFIT_TAGS,
    NET_SALES_TAGS,
    OPERATING_PROFIT_DIRECT_TAGS,
    OPERATING_REVENUE_TAGS,
    ORDINARY_INCOME_TAGS,
    ORDINARY_REVENUE_TAGS,
)
from blue_ticker.utils.xbrl_result_types import IncomeStatementResult


def _sales_label_for_tag(tag: str | None) -> str:
    if tag in ORDINARY_REVENUE_TAGS:
        return "経常収益"
    if tag in OPERATING_REVENUE_TAGS:
        return "営業収益"
    if tag in ("NetSalesIFRS", "RevenueIFRS", "RevenueIFRSSummaryOfBusinessResults", "Revenue"):
        return "売上収益"
    if tag in (
        "NetSalesOfCompletedConstructionContractsCNS",
        "NetSalesOfCompletedConstructionContractsSummaryOfBusinessResults",
    ):
        return "完成工事高"
    return "売上高"


def extract_income_statement(section: IncomeStatementSection) -> IncomeStatementResult:
    """
    損益計算書セクションから売上高・営業利益・当期純利益を抽出する。

    Returns:
        売上高・営業利益・当期純利益（円単位）と会計基準。
        取得できない項目は None。
    """
    standard = section.accounting_standard

    sales_item = section.resolve_prefer_current(NET_SALES_TAGS)
    op_item = section.resolve_prefer_current(OPERATING_PROFIT_DIRECT_TAGS)
    if op_item["current"] is None and op_item["prior"] is None:
        op_item = section.resolve_prefer_current(ORDINARY_INCOME_TAGS)
    np_item = section.resolve_prefer_current(NET_PROFIT_TAGS)

    found_tags = [
        k for k in ("sales", "operating_profit", "net_profit")
        if {"sales": sales_item["current"], "operating_profit": op_item["current"], "net_profit": np_item["current"]}[k] is not None
    ]
    method = ",".join(found_tags) if found_tags else "not_found"

    result: IncomeStatementResult = {
        "sales": sales_item["current"],
        "sales_prior": sales_item["prior"],
        "operating_profit": op_item["current"],
        "operating_profit_prior": op_item["prior"],
        "net_profit": np_item["current"],
        "net_profit_prior": np_item["prior"],
        "accounting_standard": standard,
        "method": method,
    }
    if sales_item["current"] is not None:
        result["sales_label"] = _sales_label_for_tag(sales_item["tag"])
    return result
