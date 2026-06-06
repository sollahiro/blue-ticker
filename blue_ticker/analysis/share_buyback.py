"""
自己株式取得（Share Buyback）XBRL抽出モジュール

優先順:
  J-GAAP:
    1. SS連結: PurchaseOfTreasuryStock（株主資本等変動計算書・連結コンテキスト）
    2. CF:     PurchaseOfTreasuryStockFinCF（CF計算書）
    3. SS単体: PurchaseOfTreasuryStock（NonConsolidated コンテキスト、連結SSなし企業のみ）
  IFRS:
    1. SS連結: PurchaseOfTreasurySharesSSIFRS（株主資本等変動計算書・連結）
    2. CF:     PaymentsForPurchaseOfTreasurySharesFinCFIFRS 等
    3. SS単体: PurchaseOfTreasurySharesSSIFRS（NonConsolidated コンテキスト）
  US-GAAP:
    連結株主資本等変動計算書 HTML の「自己株式取得」行（仮想タグ USGAAP_HTML_ShareBuyback）

コンテキスト:
  フロー項目なので Duration コンテキストを使用する。
"""

from blue_ticker.analysis.sections import CashFlowSection
from blue_ticker.constants.xbrl import (
    SHARE_BUYBACK_IFRS_CF_TAGS,
    SHARE_BUYBACK_IFRS_SS_TAGS,
    SHARE_BUYBACK_JGAAP_TAGS,
    SHARE_BUYBACK_SS_JGAAP_TAGS,
)
from blue_ticker.utils.xbrl_result_types import ShareBuybackResult

_USGAAP_BUYBACK_TAGS = ["USGAAP_HTML_ShareBuyback"]


def extract_share_buyback(section: CashFlowSection) -> ShareBuybackResult:
    """
    自己株式取得額を抽出する。

    金額は正値（円単位）で返す。CF計算書・SS の負値は正値へ変換する。
    US-GAAP 仮想タグはすでに正値。

    Returns:
        {
            "current": float | None,
            "prior":   float | None,
            "method":  "ss_consolidated" | "cf_financing" | "ss_nonconsolidated"
                       | "usgaap_html" | "not_found",
            "accounting_standard": str,
        }
    """
    std = section.accounting_standard

    if std == "US-GAAP":
        item = section.resolve(_USGAAP_BUYBACK_TAGS)
        if item["tag"] is not None and item["current"] is not None:
            return {
                "current": item["current"],
                "prior": item["prior"],
                "method": "usgaap_html",
                "accounting_standard": std,
            }
        # HTML抽出できない場合はSS単体フォールバック
        nc_item = section.resolve_nonconsolidated(SHARE_BUYBACK_SS_JGAAP_TAGS)
        if nc_item["tag"] is not None and nc_item["current"] is not None:
            current = -nc_item["current"] if nc_item["current"] is not None else None
            prior = -nc_item["prior"] if nc_item["prior"] is not None else None
            return {
                "current": current,
                "prior": prior,
                "method": "ss_nonconsolidated",
                "accounting_standard": std,
            }
        return _not_found(std)

    ss_tags = SHARE_BUYBACK_SS_JGAAP_TAGS if std == "J-GAAP" else SHARE_BUYBACK_IFRS_SS_TAGS
    cf_tags = SHARE_BUYBACK_JGAAP_TAGS if std == "J-GAAP" else SHARE_BUYBACK_IFRS_CF_TAGS

    # 1. SS連結
    ss_item = section.resolve(ss_tags)
    if ss_item["tag"] is not None and ss_item["current"] is not None:
        current = -ss_item["current"] if ss_item["current"] is not None else None
        prior = -ss_item["prior"] if ss_item["prior"] is not None else None
        return {
            "current": current,
            "prior": prior,
            "method": "ss_consolidated",
            "accounting_standard": std,
        }

    # 2. CF
    cf_item = section.resolve(cf_tags)
    if cf_item["tag"] is not None:
        current = -cf_item["current"] if cf_item["current"] is not None else None
        prior = -cf_item["prior"] if cf_item["prior"] is not None else None
        return {
            "current": current,
            "prior": prior,
            "method": "cf_financing",
            "accounting_standard": std,
        }

    # 3. SS単体（連結SSもCFもない企業向け）
    nc_item = section.resolve_nonconsolidated(ss_tags)
    if nc_item["tag"] is not None and nc_item["current"] is not None:
        current = -nc_item["current"] if nc_item["current"] is not None else None
        prior = -nc_item["prior"] if nc_item["prior"] is not None else None
        return {
            "current": current,
            "prior": prior,
            "method": "ss_nonconsolidated",
            "accounting_standard": std,
        }

    return _not_found(std)


def _not_found(std: str) -> ShareBuybackResult:
    return {
        "current": None,
        "prior": None,
        "method": "not_found",
        "accounting_standard": std,
        "reason": f"{std} 自己株式取得タグが見つからない",
    }
