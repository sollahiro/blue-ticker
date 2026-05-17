"""
US-GAAP HTML財務諸表フィールド抽出

連結財政状態計算書・損益計算書のiXBRL HTMLから仮想タグを生成し FieldSet を返す。
field_parser.FieldSet と同一構造 dict[str, {"current": float|None, "prior": float|None}]。
"""

from pathlib import Path
from typing import TYPE_CHECKING

try:
    from bs4 import BeautifulSoup
    _BS4_AVAILABLE = True
except ImportError:
    _BS4_AVAILABLE = False

if TYPE_CHECKING:
    from blue_ticker.analysis.field_parser import FieldSet

from blue_ticker.analysis.xbrl_utils import _extract_html_labels, _find_html_by_prefix

# US-GAAP 連結財政状態計算書 HTML → 仮想タグマッピング
_USGAAP_BS_HTML_LABEL_MAP: dict[str, str] = {
    "流動資産合計":                             "USGAAP_HTML_CurrentAssets",
    "有形固定資産合計":                         "USGAAP_HTML_PPENet",
    "投資及び長期債権合計":                     "USGAAP_HTML_InvestmentsLTReceivables",
    "その他の資産合計":                         "USGAAP_HTML_OtherNCA",
    "流動負債合計":                             "USGAAP_HTML_CurrentLiabilities",
    "固定負債合計":                             "USGAAP_HTML_NonCurrentLiabilities",
    "負債合計":                                 "USGAAP_HTML_TotalLiabilities",
    "純資産合計":                               "USGAAP_HTML_NetAssets",
    # 富士フイルム形式 IBD ラベル
    "社債及び短期借入金":                       "USGAAP_HTML_IBDCurrent",
    "社債及び長期借入金":                       "USGAAP_HTML_IBDNonCurrent",
    # キヤノン形式 IBD ラベル（"長期債務" は CF 文中にも現れるため章番号付きで特定する）
    "短期借入金及び１年以内に返済する長期債務合計": "USGAAP_HTML_IBDCurrent",
    "Ⅱ　長期債務":                          "USGAAP_HTML_IBDNonCurrent",
}

# US-GAAP 連結損益計算書 HTML → 仮想タグマッピング
# 税引前利益は "税金等調整前当期純利益"（US-GAAP式）と "税引前当期純利益"（J-GAAP式）の両方を登録し、
# 先にヒットした方が採用される（_extract_html_labels は remaining から削除済みラベルをスキップ）。
# 法人税は合計行 → 個別行 の順で試みる。合計行がなければ tax_expense.py 側で個別成分を合算する。
_USGAAP_PL_HTML_LABEL_MAP: dict[str, str] = {
    "販売費及び一般管理費":         "USGAAP_HTML_SGA",
    "営業利益":                    "USGAAP_HTML_OperatingIncome",
    "税金等調整前当期純利益":       "USGAAP_HTML_PreTaxIncome",
    "税引前当期純利益":             "USGAAP_HTML_PreTaxIncome",
    "税金等調整前当期純損失":       "USGAAP_HTML_PreTaxIncome",
    "法人税等合計":                "USGAAP_HTML_IncomeTax",
    "法人税等":                    "USGAAP_HTML_IncomeTax",
    "法人税、住民税及び事業税":     "USGAAP_HTML_IncomeTaxCurrent",
    "法人税等調整額":              "USGAAP_HTML_IncomeTaxDeferred",
}


def parse_usgaap_html_bs_fields(xbrl_dir: Path) -> "FieldSet":
    """US-GAAP 連結財政状態計算書 HTML（0105010_*）から FieldSet を生成する。

    XBRL XML に含まれない流動資産・有形固定資産・IBD 等を仮想タグ名で返す。
    返す値の単位は円。BS4 が未インストールの場合は空の FieldSet を返す。
    """
    if not _BS4_AVAILABLE:
        return {}  # type: ignore[return-value]

    bs_html = _find_html_by_prefix(xbrl_dir, "0105010")
    if bs_html is None:
        return {}  # type: ignore[return-value]

    soup = BeautifulSoup(bs_html.read_text(encoding="utf-8", errors="ignore"), "html.parser")
    return _extract_html_labels(soup, _USGAAP_BS_HTML_LABEL_MAP)  # type: ignore[return-value]


def parse_usgaap_html_pl_fields(xbrl_dir: Path) -> "FieldSet":
    """US-GAAP 連結損益計算書 HTML から FieldSet を生成する。

    0105020（連結損益計算書）を優先し、なければ 0105010 にフォールバックする。
    返す値の単位は円。BS4 が未インストールの場合は空の FieldSet を返す。
    """
    if not _BS4_AVAILABLE:
        return {}  # type: ignore[return-value]

    pl_html: Path | None = None
    for prefix in ("0105020", "0105010"):
        candidate = _find_html_by_prefix(xbrl_dir, prefix)
        if candidate is not None:
            pl_html = candidate
            break

    if pl_html is None:
        return {}  # type: ignore[return-value]

    soup = BeautifulSoup(pl_html.read_text(encoding="utf-8", errors="ignore"), "html.parser")
    return _extract_html_labels(soup, _USGAAP_PL_HTML_LABEL_MAP)  # type: ignore[return-value]
