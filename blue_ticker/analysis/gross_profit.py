"""
売上総利益 XBRL抽出モジュール

XBRLインスタンス文書から連結損益計算書の売上総利益を抽出する。

定義:
  売上総利益 = 売上高 − 売上原価

タグ体系:
  J-GAAP:   GrossProfit（直接）/ NetSales − CostOfSales（計算）
  IFRS連結:  GrossProfit（直接）/ Revenue − CostOfSales（計算）
  US-GAAP:  連結損益計算書HTML(0105010)から直接解析

抽出戦略:
  1. 直接法: GrossProfit タグを検索
  2. 計算法: 売上高タグ − 売上原価タグ で算出（フォールバック）
  3. US-GAAP: 連結損益計算書HTMLをパースして売上総利益を取得

コンテキスト:
  損益計算書はフロー項目なので Duration コンテキストを使用する。
  （貸借対照表の Instant コンテキストとは異なる点に注意）
"""

from blue_ticker.analysis.sections import IncomeStatementSection
from blue_ticker.analysis.usgaap.gross_profit import extract_usgaap_gp_from_html
from blue_ticker.analysis.xbrl_utils import extract_ifrs_textblock_table
from blue_ticker.constants.financial import MILLION_YEN
from blue_ticker.constants.xbrl import (
    BUSINESS_GROSS_PROFIT_COMPONENT_DEFINITIONS,
    GROSS_PROFIT_COMPONENT_DEFINITIONS,
    GROSS_PROFIT_DIRECT_TAGS,
    OPERATING_GROSS_PROFIT_DIRECT_TAGS,
    ORDINARY_REVENUE_TAGS,
)
from blue_ticker.utils.xbrl_result_types import GrossProfitResult, MetricComponent


def _resolve_prefer_both(
    section: IncomeStatementSection, tags: list[str]
) -> tuple[float | None, float | None]:
    """両方（当期・前期）揃うタグを優先し、なければ片側のみでも返す。"""
    partial_c: float | None = None
    partial_p: float | None = None
    for tag in tags:
        if tag not in section:
            continue
        fv = section.field_value(tag)
        if fv is None:
            continue
        c, p = fv["current"], fv["prior"]
        if c is not None and p is not None:
            return c, p
        if (c is not None or p is not None) and partial_c is None and partial_p is None:
            partial_c, partial_p = c, p
    return partial_c, partial_p


def _extract_sales_for_yoy(section: IncomeStatementSection) -> tuple[float | None, float | None]:
    """売上高の当期・前期値を返す（YoY比較用）。当期・前期が両方揃うタグを優先する。"""
    sales_tags = next(
        (comp["tags"] for comp in GROSS_PROFIT_COMPONENT_DEFINITIONS if comp["label"] == "売上高"),
        [],
    ) + ORDINARY_REVENUE_TAGS
    return _resolve_prefer_both(section, sales_tags)


def _extract_business_gross_profit(section: IncomeStatementSection) -> GrossProfitResult | None:
    """銀行等の連結業務粗利益を構成要素から算出する。"""
    comp_results: list[MetricComponent] = []
    current_total = prior_total = 0.0
    has_current = has_prior = False

    for comp_def in BUSINESS_GROSS_PROFIT_COMPONENT_DEFINITIONS:
        item = section.resolve(comp_def["tags"])
        sign = comp_def["sign"]
        if item["current"] is not None:
            current_total += sign * item["current"]
            has_current = True
        if item["prior"] is not None:
            prior_total += sign * item["prior"]
            has_prior = True

        comp_results.append({
            "label": comp_def["label"],
            "tag": item["tag"],
            "current": sign * item["current"] if item["current"] is not None else None,
            "prior": sign * item["prior"] if item["prior"] is not None else None,
        })

    if not has_current and not has_prior:
        return None

    sales_c, sales_p = _extract_sales_for_yoy(section)
    result: GrossProfitResult = {
        "current": current_total if has_current else None,
        "prior": prior_total if has_prior else None,
        "method": "business_gross_profit",
        "accounting_standard": "J-GAAP",
        "components": comp_results,
    }
    if sales_c is not None or sales_p is not None:
        result["current_sales"] = sales_c
        result["prior_sales"] = sales_p
    return result


_IFRS_PL_TEXTBLOCK_TAG = "ConsolidatedStatementOfIncomeIFRSTextBlock"
_IFRS_GP_LABEL = "売上総利益"
_IFRS_COGS_LABEL = "売上原価"


def _extract_ifrs_gp_from_textblock(section: IncomeStatementSection) -> GrossProfitResult | None:
    """IFRS連結損益計算書TextBlockから売上総利益を抽出する。"""
    if section.xbrl_dir is None:
        return None
    table = extract_ifrs_textblock_table(section.xbrl_dir, _IFRS_PL_TEXTBLOCK_TAG)
    if not table:
        return None

    gp = table.get(_IFRS_GP_LABEL)
    if gp is None:
        return None
    c_m, p_m = gp
    if c_m is None and p_m is None:
        return None

    cogs = table.get(_IFRS_COGS_LABEL)
    c_yen = c_m * MILLION_YEN if c_m is not None else None
    p_yen = p_m * MILLION_YEN if p_m is not None else None

    components: list[MetricComponent] = [
        {"label": "売上総利益", "tag": "IFRS_HTML_GrossProfit", "current": c_yen, "prior": p_yen},
    ]
    if cogs is not None:
        cc_m, cp_m = cogs
        components.insert(0, {
            "label": "売上原価",
            "tag": "IFRS_HTML_CostOfSales",
            "current": cc_m * MILLION_YEN if cc_m is not None else None,
            "prior": cp_m * MILLION_YEN if cp_m is not None else None,
        })

    result: GrossProfitResult = {
        "current": c_yen,
        "prior": p_yen,
        "method": "ifrs_textblock",
        "accounting_standard": "IFRS",
        "components": components,
    }
    sales_c, sales_p = _extract_sales_for_yoy(section)
    if sales_c is not None or sales_p is not None:
        result["current_sales"] = sales_c
        result["prior_sales"] = sales_p
    return result



def extract_gross_profit(section: IncomeStatementSection) -> GrossProfitResult:
    """
    損益計算書セクションから売上総利益を抽出する。

    Returns:
        {
            "current": float | None,      # 当期（円）
            "prior":   float | None,      # 前期（円）
            "method":  str,               # "direct" | "computed" | "business_gross_profit" | "usgaap_html" | "not_found"
            "reason":  str | None,        # not_found 時のみ失敗理由を格納、それ以外は None
            "accounting_standard": str,   # "J-GAAP" | "IFRS" | "US-GAAP"
            "components": [
                {
                    "label": str,
                    "tag":   str | None,
                    "current": float | None,
                    "prior":   float | None,
                }
            ]
        }
    """
    accounting_standard = section.accounting_standard

    # US-GAAP 企業: 連結損益計算書HTML(0105010)から直接解析
    if accounting_standard == "US-GAAP":
        if section.xbrl_dir is not None:
            usgaap_result = extract_usgaap_gp_from_html(section.xbrl_dir)
            if usgaap_result is not None:
                sales_c, sales_p = _extract_sales_for_yoy(section)
                if sales_c is not None or sales_p is not None:
                    usgaap_result["current_sales"] = sales_c
                    usgaap_result["prior_sales"] = sales_p
                return usgaap_result
        return {
            "current": None, "prior": None,
            "method": "not_found", "accounting_standard": "US-GAAP", "components": [],
            "reason": "US-GAAP 連結損益計算書 HTML (0105010) で売上総利益を取得できない",
        }

    # 直接法: GrossProfit タグを検索
    gp_item = section.resolve(GROSS_PROFIT_DIRECT_TAGS)
    if gp_item["tag"] is not None:
        sales_c, sales_p = _extract_sales_for_yoy(section)
        result: GrossProfitResult = {
            "current": gp_item["current"],
            "prior": gp_item["prior"],
            "method": "direct",
            "accounting_standard": accounting_standard,
            "components": [
                {"label": "売上総利益", "tag": gp_item["tag"], "current": gp_item["current"], "prior": gp_item["prior"]}
            ],
        }
        if sales_c is not None or sales_p is not None:
            result["current_sales"] = sales_c
            result["prior_sales"] = sales_p
        return result

    business_gross_profit = _extract_business_gross_profit(section)
    if business_gross_profit is not None:
        return business_gross_profit

    # 直接法: OperatingGrossProfit タグを検索
    ogp_item = section.resolve(OPERATING_GROSS_PROFIT_DIRECT_TAGS)
    if ogp_item["tag"] is not None:
        sales_c, sales_p = _extract_sales_for_yoy(section)
        result = {
            "current": ogp_item["current"],
            "prior": ogp_item["prior"],
            "method": "operating_gross_profit",
            "accounting_standard": accounting_standard,
            "components": [
                {"label": "営業総利益", "tag": ogp_item["tag"], "current": ogp_item["current"], "prior": ogp_item["prior"]}
            ],
        }
        if sales_c is not None or sales_p is not None:
            result["current_sales"] = sales_c
            result["prior_sales"] = sales_p
        return result

    # 計算法: 売上高タグ・売上原価タグをそれぞれ取得して差し引く
    comp_results: list[MetricComponent] = []
    for comp_def in GROSS_PROFIT_COMPONENT_DEFINITIONS:
        item = section.resolve(comp_def["tags"])
        comp_results.append({
            "label": comp_def["label"],
            "tag": item["tag"],
            "current": item["current"],
            "prior": item["prior"],
        })

    sales = next((c for c in comp_results if c["label"] == "売上高"), None)
    cogs = next((c for c in comp_results if c["label"] == "売上原価"), None)

    # IFRS Summary型: 売上原価タグが存在しない場合、TextBlockから粗利益を抽出する
    if accounting_standard == "IFRS" and (
        cogs is None or (cogs["current"] is None and cogs["prior"] is None)
    ):
        textblock_result = _extract_ifrs_gp_from_textblock(section)
        if textblock_result is not None:
            return textblock_result

    if sales is None or (sales["current"] is None and sales["prior"] is None):
        return {
            "current": None,
            "prior": None,
            "method": "not_found",
            "accounting_standard": accounting_standard,
            "components": comp_results,
            "reason": "売上高タグが見つからない",
        }

    def _subtract(a: float | None, b: float | None) -> float | None:
        if a is None:
            return None
        return a - (b or 0.0)

    cogs_current = cogs["current"] if cogs else None
    cogs_prior = cogs["prior"] if cogs else None
    gp_current = _subtract(sales["current"], cogs_current)
    gp_prior = _subtract(sales["prior"], cogs_prior)

    if gp_current is None and gp_prior is None:
        return {
            "current": None,
            "prior": None,
            "method": "not_found",
            "accounting_standard": accounting_standard,
            "components": comp_results,
            "reason": "売上高タグは存在するが当期・前期ともに値なし",
            "current_sales": sales["current"],
            "prior_sales": sales["prior"],
        }

    return {
        "current": gp_current,
        "prior": gp_prior,
        "method": "computed",
        "accounting_standard": accounting_standard,
        "components": comp_results,
        "current_sales": sales["current"],
        "prior_sales": sales["prior"],
    }
