"""
設備投資（CapEx）XBRL抽出モジュール

XBRLインスタンス文書から設備投資額を抽出する。

優先順:
  1. 設備投資等の概要タグ（CapitalExpendituresOverviewOfCapitalExpendituresEtc）
     - 正値で記録されており、有形・無形を含む総額
  2. CF計算書 有形固定資産の取得（負値を正値へ変換）

タグ体系:
  概要: CapitalExpendituresOverviewOfCapitalExpendituresEtc（J-GAAP / IFRS 共通）
  J-GAAP CF: PurchaseOfPropertyPlantAndEquipmentInvCF（負値）
  IFRS CF:   AcquisitionOfPropertyPlantAndEquipmentInvCFIFRS（負値）

コンテキスト:
  設備投資はフロー項目なので Duration コンテキストを使用する。
"""

from blue_ticker.analysis.sections import CashFlowSection
from blue_ticker.constants.xbrl import (
    CAPEX_CF_IFRS_TAGS,
    CAPEX_CF_JGAAP_TAGS,
    CAPEX_OVERVIEW_TAGS,
)
from blue_ticker.utils.xbrl_result_types import CapitalExpenditureResult


def extract_capital_expenditure(section: CashFlowSection) -> CapitalExpenditureResult:
    """
    CF計算書セクションから設備投資額を抽出する。

    金額は正値（円単位）で返す。CF計算書の負値（キャッシュ流出）は正値へ変換する。

    Returns:
        {
            "current": float | None,
            "prior":   float | None,
            "method":  "overview" | "cf_investing" | "not_found",
            "accounting_standard": str,
        }
    """
    accounting_standard = section.accounting_standard

    overview_item = section.resolve(CAPEX_OVERVIEW_TAGS)
    if overview_item["tag"] is not None:
        return {
            "current": overview_item["current"],
            "prior": overview_item["prior"],
            "method": "overview",
            "accounting_standard": accounting_standard,
        }

    cf_tags = (
        CAPEX_CF_IFRS_TAGS
        if accounting_standard == "IFRS"
        else CAPEX_CF_JGAAP_TAGS
    )
    cf_item = section.resolve(cf_tags)
    if cf_item["tag"] is not None:
        current = -cf_item["current"] if cf_item["current"] is not None else None
        prior = -cf_item["prior"] if cf_item["prior"] is not None else None
        return {
            "current": current,
            "prior": prior,
            "method": "cf_investing",
            "accounting_standard": accounting_standard,
        }

    return {
        "current": None,
        "prior": None,
        "method": "not_found",
        "accounting_standard": accounting_standard,
        "reason": f"{accounting_standard} 設備投資タグが見つからない",
    }
