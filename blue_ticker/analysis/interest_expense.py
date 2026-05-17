"""
支払利息 XBRL抽出モジュール

XBRLインスタンス文書から連結損益計算書の支払利息（金融費用）を抽出する。

タグ体系:
  J-GAAP:  InterestExpensesNOE（営業外費用の支払利息）
  IFRS:    FinanceCostsIFRS（金融費用）
  US-GAAP: 連結損益計算書HTML(0105010)から「支払利息」行を解析

コンテキスト:
  損益計算書はフロー項目なので Duration コンテキストを使用する。
"""

import html
import re
import warnings
from pathlib import Path

try:
    from bs4 import BeautifulSoup, XMLParsedAsHTMLWarning
    _BS4_AVAILABLE = True
    _XML_PARSED_AS_HTML_WARNING: type[Warning] | None = XMLParsedAsHTMLWarning
except ImportError:
    _BS4_AVAILABLE = False
    _XML_PARSED_AS_HTML_WARNING = None

from blue_ticker.analysis.sections import IncomeStatementSection
from blue_ticker.analysis.usgaap.interest_expense import extract_usgaap_ie_from_html
from blue_ticker.constants.financial import MILLION_YEN
from blue_ticker.constants.xbrl import (
    INTEREST_EXPENSE_IFRS_TAGS,
    INTEREST_EXPENSE_JGAAP_TAGS,
)
from blue_ticker.utils.xbrl_result_types import InterestExpenseResult



def _extract_ifrs_ie_from_textblock(xbrl_dir: Path) -> InterestExpenseResult | None:
    """IFRS注記テキストブロックから支払利息を抽出する。"""
    # トヨタ自動車のIFRS注記のように、支払利息がnumericタグではなく文章中に出るケースを拾う。
    pattern = re.compile(
        r"支払利息は、.*?それぞれ\s*([0-9,]+)百万円\s*および\s*([0-9,]+)百万円",
        re.DOTALL,
    )

    candidates = sorted(xbrl_dir.rglob("*.htm")) + sorted(xbrl_dir.rglob("*.html")) + sorted(xbrl_dir.rglob("*.xbrl"))
    for file in candidates:
        content = file.read_text(encoding="utf-8", errors="ignore")
        if "支払利息" not in content or "百万円" not in content:
            continue
        text = html.unescape(content)
        if _BS4_AVAILABLE:
            with warnings.catch_warnings():
                if _XML_PARSED_AS_HTML_WARNING is not None:
                    warnings.filterwarnings("ignore", category=_XML_PARSED_AS_HTML_WARNING)
                text = BeautifulSoup(text, "html.parser").get_text(" ")
        match = pattern.search(text)
        if not match:
            continue
        prior = float(match.group(1).replace(",", "")) * MILLION_YEN
        current = float(match.group(2).replace(",", "")) * MILLION_YEN
        return {
            "current": current,
            "prior": prior,
            "method": "ifrs_textblock",
            "accounting_standard": "IFRS",
        }
    return None


def extract_interest_expense(section: IncomeStatementSection) -> InterestExpenseResult:
    """
    損益計算書セクションから支払利息（金融費用）を抽出する。

    Returns:
        {
            "current": float | None,      # 当期（円）
            "prior":   float | None,      # 前期（円）
            "method":  str,               # "direct" | "not_found"
            "reason":  str | None,        # not_found 時のみ
            "accounting_standard": str,   # "J-GAAP" | "IFRS" | "US-GAAP"
        }
    """
    accounting_standard = section.accounting_standard

    if accounting_standard == "US-GAAP":
        if section.xbrl_dir is not None:
            result = extract_usgaap_ie_from_html(section.xbrl_dir)
            if result is not None:
                return result
        return {
            "current": None, "prior": None,
            "method": "not_found", "accounting_standard": "US-GAAP",
            "reason": "US-GAAP 連結損益計算書 HTML (0105010) で支払利息を取得できない",
        }

    candidate_tags = (
        INTEREST_EXPENSE_IFRS_TAGS if accounting_standard == "IFRS"
        else INTEREST_EXPENSE_JGAAP_TAGS
    )

    item = section.resolve(candidate_tags)
    if item["tag"] is not None:
        return {
            "current": item["current"],
            "prior": item["prior"],
            "method": "direct",
            "accounting_standard": accounting_standard,
        }

    if section.xbrl_dir is not None:
        result = _extract_ifrs_ie_from_textblock(section.xbrl_dir)
        if result is not None:
            return result

    return {
        "current": None, "prior": None,
        "method": "not_found", "accounting_standard": accounting_standard,
        "reason": f"{accounting_standard} 支払利息タグが見つからない",
    }
