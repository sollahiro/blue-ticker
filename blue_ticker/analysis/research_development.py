"""
研究開発費（R&D Expenses）XBRL抽出モジュール

XBRLインスタンス文書から研究開発費を抽出する。

優先順:
  1. 「研究開発活動」セクションの共通タグ（J-GAAP / IFRS 問わず）
     ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities
  2. 会計基準別フォールバック（損益計算書・販管費内タグ）

コンテキスト:
  Duration コンテキストを使用する。
"""

from blue_ticker.analysis.sections import IncomeStatementSection
from blue_ticker.constants.xbrl import (
    RD_EXPENSE_COMMON_TAGS,
    RD_EXPENSE_IFRS_TAGS,
    RD_EXPENSE_JGAAP_TAGS,
)
from blue_ticker.utils.xbrl_result_types import ResearchDevelopmentResult


def extract_research_development(section: IncomeStatementSection) -> ResearchDevelopmentResult:
    """
    損益計算書セクションから研究開発費を抽出する。

    Returns:
        {
            "current": float | None,
            "prior":   float | None,
            "method":  "direct" | "not_found",
            "accounting_standard": str,
        }
    """
    accounting_standard = section.accounting_standard

    common_item = section.resolve(RD_EXPENSE_COMMON_TAGS)
    if common_item["tag"] is not None:
        return {
            "current": common_item["current"],
            "prior": common_item["prior"],
            "method": "direct",
            "accounting_standard": accounting_standard,
        }

    fallback_tags = (
        RD_EXPENSE_IFRS_TAGS
        if accounting_standard == "IFRS"
        else RD_EXPENSE_JGAAP_TAGS
    )
    fallback_item = section.resolve(fallback_tags)
    if fallback_item["tag"] is not None:
        return {
            "current": fallback_item["current"],
            "prior": fallback_item["prior"],
            "method": "direct",
            "accounting_standard": accounting_standard,
        }

    return {
        "current": None,
        "prior": None,
        "method": "not_found",
        "accounting_standard": accounting_standard,
        "reason": f"{accounting_standard} 研究開発費タグが見つからない",
    }
