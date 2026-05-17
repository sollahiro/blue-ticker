"""
自己株式取得（Share Buyback）XBRL抽出モジュール

XBRLインスタンス文書から財務キャッシュフロー計算書の自己株式取得額を抽出する。

タグ体系:
  J-GAAP: PurchaseOfTreasuryStockFinCF（CF計算書、負値）
  IFRS:   PaymentsForPurchaseOfTreasurySharesFinCFIFRS 等（CF計算書、負値）
          会社固有タグ ReissuanceRepurchaseOfTreasuryStockFinCFIFRS（CF計算書、負値）
          最終フォールバック: PurchaseOfTreasurySharesSSIFRS（株主資本等変動計算書）

コンテキスト:
  CF計算書はフロー項目なので Duration コンテキストを使用する。
"""

from blue_ticker.analysis.sections import CashFlowSection
from blue_ticker.constants.xbrl import (
    SHARE_BUYBACK_IFRS_TAGS,
    SHARE_BUYBACK_JGAAP_TAGS,
)
from blue_ticker.utils.xbrl_result_types import ShareBuybackResult


def extract_share_buyback(section: CashFlowSection) -> ShareBuybackResult:
    """
    CF計算書セクションから自己株式取得額を抽出する。

    金額は正値（円単位）で返す。CF計算書の負値（キャッシュ流出）は正値へ変換する。

    Returns:
        {
            "current": float | None,
            "prior":   float | None,
            "method":  "cf_financing" | "not_found",
            "accounting_standard": str,
        }
    """
    accounting_standard = section.accounting_standard

    candidate_tags = (
        SHARE_BUYBACK_IFRS_TAGS
        if accounting_standard == "IFRS"
        else SHARE_BUYBACK_JGAAP_TAGS
    )
    item = section.resolve(candidate_tags)
    if item["tag"] is not None:
        current = -item["current"] if item["current"] is not None else None
        prior = -item["prior"] if item["prior"] is not None else None
        return {
            "current": current,
            "prior": prior,
            "method": "cf_financing",
            "accounting_standard": accounting_standard,
        }

    return {
        "current": None,
        "prior": None,
        "method": "not_found",
        "accounting_standard": accounting_standard,
        "reason": f"{accounting_standard} 自己株式取得タグが見つからない",
    }
