"""
営業利益・経常利益 XBRL抽出モジュール

抽出優先順:
  1. 営業利益（IFRS: OperatingProfitLossIFRS / J-GAAP: OperatingIncomeLoss → OperatingIncome）
     連結優先、連結タグがなければ個別にフォールバック
  2. 経常利益（J-GAAP: OrdinaryIncome）— 金融機関向けフォールバック
  3. US-GAAP: IncomeStatementSection に注入済みの仮想タグ（USGAAP_HTML_OperatingIncome）を使用
"""

from blue_ticker.analysis.sections import IncomeStatementSection
from blue_ticker.constants.xbrl import (
    GROSS_PROFIT_DIRECT_TAGS,
    OPERATING_PROFIT_DIRECT_TAGS,
    ORDINARY_INCOME_TAGS,
    ORDINARY_REVENUE_TAGS,
    SGA_DIRECT_TAGS,
)
from blue_ticker.utils.xbrl_result_types import OperatingProfitResult


def extract_operating_profit(section: IncomeStatementSection) -> OperatingProfitResult:
    """
    損益計算書セクションから営業利益（または経常利益）を抽出する。

    金融機関など営業利益が存在しない場合は経常利益にフォールバックする。

    Returns:
        {
            "current": float | None,
            "prior":   float | None,
            "method":  "direct" | "ordinary_income" | "usgaap_html" | "not_found",
            "label":   "営業利益" | "経常利益",
            "accounting_standard": str,
            "reason":  str | None,   # not_found 時のみ
        }
    """
    accounting_standard = section.accounting_standard

    if accounting_standard == "US-GAAP":
        op_item = section.resolve(["USGAAP_HTML_OperatingIncome"])
        if op_item["current"] is not None or op_item["prior"] is not None:
            result: OperatingProfitResult = {
                "current": op_item["current"], "prior": op_item["prior"],
                "method": "usgaap_html", "label": "営業利益",
                "accounting_standard": "US-GAAP",
            }
            sga_item = section.resolve(["USGAAP_HTML_SGA"])
            if sga_item["current"] is not None:
                result["current_sga"] = sga_item["current"]
                result["prior_sga"] = sga_item["prior"]
            return result
        return {
            "current": None, "prior": None,
            "method": "not_found", "label": "営業利益",
            "accounting_standard": "US-GAAP",
            "reason": "US-GAAP 連結損益計算書 HTML で営業利益を取得できない",
        }

    # 直接法: OPERATING_PROFIT_DIRECT_TAGS
    op_item = section.resolve(OPERATING_PROFIT_DIRECT_TAGS)
    if op_item["tag"] is not None:
        sga_item = section.resolve(SGA_DIRECT_TAGS)
        result: OperatingProfitResult = {
            "current": op_item["current"], "prior": op_item["prior"],
            "method": "direct", "label": "営業利益",
            "accounting_standard": accounting_standard,
        }
        if sga_item["tag"] is not None:
            result["current_sga"] = sga_item["current"]
            result["prior_sga"] = sga_item["prior"]
        return result

    # 計算法: GrossProfit - SGA（OperatingProfitLossIFRS が存在しない IFRS 企業向け）
    computed = section.derive_subtraction(GROSS_PROFIT_DIRECT_TAGS, SGA_DIRECT_TAGS)
    if computed["current"] is not None or computed["prior"] is not None:
        sga_item = section.resolve(SGA_DIRECT_TAGS)
        result = {
            "current": computed["current"], "prior": computed["prior"],
            "method": "computed", "label": "営業利益",
            "accounting_standard": accounting_standard,
        }
        if sga_item["tag"] is not None:
            result["current_sga"] = sga_item["current"]
            result["prior_sga"] = sga_item["prior"]
        return result

    # 経常利益フォールバック（J-GAAP 金融機関向け）
    # IFRS企業では連結コンテキストに経常利益タグが残存しても使わない。
    # _apply_net_revenue が BusinessProfitIFRSSummaryOfBusinessResults を使うため。
    if accounting_standard == "IFRS":
        return {
            "current": None, "prior": None,
            "method": "not_found", "label": "営業利益",
            "accounting_standard": accounting_standard,
            "reason": "IFRS企業では経常利益フォールバックを適用しない",
        }
    oi_item = section.resolve(ORDINARY_INCOME_TAGS)
    if oi_item["tag"] is not None:
        ordinary_result: OperatingProfitResult = {
            "current": oi_item["current"], "prior": oi_item["prior"],
            "method": "ordinary_income", "label": "経常利益",
            "accounting_standard": accounting_standard,
        }
        sales_item = section.resolve(ORDINARY_REVENUE_TAGS)
        if sales_item["tag"] is not None:
            ordinary_result["current_sales"] = sales_item["current"]
            ordinary_result["prior_sales"] = sales_item["prior"]
        return ordinary_result

    return {
        "current": None, "prior": None,
        "method": "not_found", "label": "営業利益",
        "accounting_standard": accounting_standard,
        "reason": "営業利益・経常利益タグが見つからない",
    }
