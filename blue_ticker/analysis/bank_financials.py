"""
銀行業固有 貸借対照表項目 XBRL 抽出モジュール

BalanceSheetSection（FieldSet を内包）からの3ステージ抽出:
  Stage 1: XBRL XML → FieldSet  (Section 構築時に実施)
  Stage 2: HTML 補完            (Section 構築時に US-GAAP 企業のみ実施)
  Stage 3: FieldSet → 銀行財務値 (extract_bank_financials: 直接法のみ)

対象項目（いずれも貸借対照表 Instant コンテキスト）:
  預金    (DepositsLiabilitiesBNK)       - 負債
  貸出金  (LoansAndBillsDiscountedAssetsBNK) - 資産
  現金預け金 (CashAndDueFromBanksAssetsBNK) - 資産

非銀行企業では _BNK タグが存在しないため、全項目 None を返す。
"""

from blue_ticker.analysis.sections import BalanceSheetSection
from blue_ticker.constants.xbrl import (
    BANK_CASH_DUE_FROM_BANKS_TAGS,
    BANK_DEPOSITS_TAGS,
    BANK_LOANS_TAGS,
    BANK_NEGOTIABLE_CD_TAGS,
)
from blue_ticker.utils.xbrl_result_types import BankFinancialsResult


def extract_bank_financials(section: BalanceSheetSection) -> BankFinancialsResult:
    """貸借対照表セクションから銀行業固有の財務項目を抽出する。"""
    accounting_standard = section.accounting_standard

    deposits = section.resolve(BANK_DEPOSITS_TAGS)
    loans = section.resolve(BANK_LOANS_TAGS)
    cash_due = section.resolve(BANK_CASH_DUE_FROM_BANKS_TAGS)
    ncds = section.resolve(BANK_NEGOTIABLE_CD_TAGS)

    found = any(
        v is not None
        for v in [deposits["current"], loans["current"], cash_due["current"]]
    )

    result: BankFinancialsResult = {
        "deposits": deposits["current"],
        "deposits_prior": deposits["prior"],
        "loans": loans["current"],
        "loans_prior": loans["prior"],
        "cash_due_from_banks": cash_due["current"],
        "cash_due_from_banks_prior": cash_due["prior"],
        "negotiable_cds": ncds["current"],
        "negotiable_cds_prior": ncds["prior"],
        "accounting_standard": accounting_standard,
        "method": "field_parser" if found else "not_found",
    }
    if not found:
        result["reason"] = "銀行業タグが見つからない（非銀行企業または未対応フォーマット）"
    return result
