"""
実効税率 XBRL抽出モジュール

XBRLインスタンス文書から連結損益計算書の税引前利益・法人税等を抽出し、
実効税率を計算する。

タグ体系:
  J-GAAP:  IncomeBeforeIncomeTaxes / IncomeTaxes
  IFRS:    ProfitLossBeforeTaxIFRS / IncomeTaxExpenseIFRS
  US-GAAP: IncomeStatementSection に注入済みの仮想タグ（USGAAP_HTML_PreTaxIncome / USGAAP_HTML_IncomeTax）
"""

from blue_ticker.analysis.sections import IncomeStatementSection
from blue_ticker.constants.xbrl import (
    INCOME_TAX_IFRS_TAGS,
    INCOME_TAX_JGAAP_TAGS,
    PRETAX_INCOME_IFRS_TAGS,
    PRETAX_INCOME_JGAAP_TAGS,
)
from blue_ticker.utils.xbrl_result_types import TaxExpenseResult


def extract_tax_expense(section: IncomeStatementSection) -> TaxExpenseResult:
    """
    損益計算書セクションから税引前利益・法人税等を抽出し実効税率を計算する。

    Returns:
        {
            "pretax_income":    float | None,  # 当期税引前利益（円）
            "income_tax":       float | None,  # 当期法人税等（円）
            "effective_tax_rate": float | None,  # 実効税率（小数、例: 0.254）
            "prior_pretax_income":  float | None,
            "prior_income_tax":     float | None,
            "prior_effective_tax_rate": float | None,
            "accounting_standard": str,
            "method": str,   # "computed" | "not_found"
        }
    """
    accounting_standard = section.accounting_standard

    if accounting_standard == "US-GAAP":
        pretax = section.resolve(["USGAAP_HTML_PreTaxIncome"])
        tax = section.resolve(["USGAAP_HTML_IncomeTax"])

        def _tax_rate_usgaap(p: float | None, t: float | None) -> float | None:
            return t / p if p is not None and t is not None and p != 0 else None

        if pretax["current"] is not None or tax["current"] is not None:
            return {
                "pretax_income": pretax["current"],
                "income_tax": tax["current"],
                "effective_tax_rate": _tax_rate_usgaap(pretax["current"], tax["current"]),
                "prior_pretax_income": pretax["prior"],
                "prior_income_tax": tax["prior"],
                "prior_effective_tax_rate": _tax_rate_usgaap(pretax["prior"], tax["prior"]),
                "accounting_standard": "US-GAAP",
                "method": "usgaap_html",
            }
        return {
            "pretax_income": None, "income_tax": None, "effective_tax_rate": None,
            "prior_pretax_income": None, "prior_income_tax": None, "prior_effective_tax_rate": None,
            "accounting_standard": "US-GAAP", "method": "not_found",
            "reason": "US-GAAP 連結損益計算書 HTML で税引前利益を取得できない",
        }

    if accounting_standard == "IFRS":
        pretax_tags = PRETAX_INCOME_IFRS_TAGS
        tax_tags = INCOME_TAX_IFRS_TAGS
    else:
        pretax_tags = PRETAX_INCOME_JGAAP_TAGS
        tax_tags = INCOME_TAX_JGAAP_TAGS

    pretax_item = section.resolve(pretax_tags)
    tax_item = section.resolve(tax_tags)

    def _tax_rate(pretax: float | None, tax: float | None) -> float | None:
        if pretax is not None and tax is not None and pretax != 0:
            return tax / pretax
        return None

    if pretax_item["tag"] is None and tax_item["tag"] is None:
        return {
            "pretax_income": None, "income_tax": None, "effective_tax_rate": None,
            "prior_pretax_income": None, "prior_income_tax": None, "prior_effective_tax_rate": None,
            "accounting_standard": accounting_standard, "method": "not_found",
            "reason": f"{accounting_standard} 税引前利益タグが見つからない",
        }

    return {
        "pretax_income": pretax_item["current"],
        "income_tax": tax_item["current"],
        "effective_tax_rate": _tax_rate(pretax_item["current"], tax_item["current"]),
        "prior_pretax_income": pretax_item["prior"],
        "prior_income_tax": tax_item["prior"],
        "prior_effective_tax_rate": _tax_rate(pretax_item["prior"], tax_item["prior"]),
        "accounting_standard": accounting_standard,
        "method": "computed",
    }
