"""
減価償却費 XBRL抽出モジュール

XBRLインスタンス文書から連結キャッシュ・フロー計算書の減価償却費を抽出する。

タグ体系:
  J-GAAP: DepreciationAndAmortizationOpeCF
  IFRS:   DepreciationAndAmortizationOpeCFIFRS

コンテキスト:
  CF計算書はフロー項目なので Duration コンテキストを使用する。
"""

from blue_ticker.analysis.sections import CashFlowSection
from blue_ticker.analysis.usgaap.depreciation import extract_usgaap_da_from_html
from blue_ticker.constants.xbrl import (
    CF_DEPRECIATION_IFRS_TAGS,
    CF_DEPRECIATION_JGAAP_TAGS,
)
from blue_ticker.utils.xbrl_result_types import DepreciationResult


def extract_depreciation(section: CashFlowSection) -> DepreciationResult:
    """
    CF計算書セクションから減価償却費を抽出する。

    Returns:
        {
            "current": float | None,
            "prior":   float | None,
            "method":  str,
            "accounting_standard": str,
        }
    """
    accounting_standard = section.accounting_standard

    if accounting_standard == "US-GAAP":
        if section.xbrl_dir is not None:
            result = extract_usgaap_da_from_html(section.xbrl_dir)
            if result is not None:
                return result
        return {
            "current": None,
            "prior": None,
            "method": "not_found",
            "accounting_standard": "US-GAAP",
            "reason": "US-GAAP 連結CF計算書 HTML (0105010) で減価償却費を取得できない",
        }

    candidate_tags = (
        CF_DEPRECIATION_IFRS_TAGS
        if accounting_standard == "IFRS"
        else CF_DEPRECIATION_JGAAP_TAGS
    )

    item = section.resolve(candidate_tags)
    if item["tag"] is not None:
        return {
            "current": item["current"],
            "prior": item["prior"],
            "method": "direct",
            "accounting_standard": accounting_standard,
        }

    return {
        "current": None,
        "prior": None,
        "method": "not_found",
        "accounting_standard": accounting_standard,
        "reason": f"{accounting_standard} 減価償却費タグが見つからない",
    }
