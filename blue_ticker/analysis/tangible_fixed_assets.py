"""
有形固定資産（PPE）XBRL抽出モジュール

BalanceSheetSection（FieldSet を内包）から有形固定資産合計を抽出する。
内訳（建物・土地・機械等）は会計基準間で比較不能なため抽出しない。

帳簿価額の取得方法（優先順）:
  1. 直接タグ（*IFRS / *Net サフィックス）
  2. 取得原価タグ − 累計減価償却・減損タグ（IFRS 直接タグが存在しない場合のフォールバック）
"""

from blue_ticker.analysis.sections import BalanceSheetSection
from blue_ticker.constants.xbrl import (
    PPE_TAGS_USGAAP_TOTAL,
    PPE_TOTAL_COST_TAGS,
    PPE_TOTAL_DEP_TAGS,
    PPE_TOTAL_IFRS_DIRECT,
    PPE_TOTAL_JGAAP_DIRECT,
)
from blue_ticker.utils.xbrl_result_types import TangibleFixedAssetsResult


def _net_value(
    section: BalanceSheetSection,
    cost_tags: list[str],
    dep_tags: list[str],
) -> float | None:
    """取得原価タグと累計減価償却・減損タグから帳簿価額を計算する。"""
    cost = section.resolve(cost_tags)["current"]
    if cost is None:
        return None
    dep = section.resolve(dep_tags)["current"]
    return cost + (dep if dep is not None else 0.0)


def extract_tangible_fixed_assets(section: BalanceSheetSection) -> TangibleFixedAssetsResult:
    """貸借対照表セクションから有形固定資産合計を抽出する。"""
    accounting_standard = section.accounting_standard

    if accounting_standard == "IFRS":
        total = section.resolve(PPE_TOTAL_IFRS_DIRECT)["current"]
        if total is None:
            total = _net_value(section, PPE_TOTAL_COST_TAGS, PPE_TOTAL_DEP_TAGS)
    elif accounting_standard == "J-GAAP":
        total = section.resolve(PPE_TOTAL_JGAAP_DIRECT)["current"]
    else:
        total = section.resolve(PPE_TAGS_USGAAP_TOTAL)["current"]

    if total is None:
        return {
            "total": None,
            "method": "not_found",
            "accounting_standard": accounting_standard,
            "reason": "有形固定資産タグが見つからない",
        }

    return {
        "total": total,
        "method": "field_parser",
        "accounting_standard": accounting_standard,
    }
