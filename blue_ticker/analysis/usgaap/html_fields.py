"""
US-GAAP HTML財務諸表フィールド抽出

連結財政状態計算書・損益計算書のiXBRL HTMLから仮想タグを生成し FieldSet を返す。
field_parser.FieldSet と同一構造 dict[str, {"current": float|None, "prior": float|None}]。
"""

import re
from pathlib import Path
from typing import TYPE_CHECKING

try:
    from bs4 import BeautifulSoup
    _BS4_AVAILABLE = True
except ImportError:
    _BS4_AVAILABLE = False

if TYPE_CHECKING:
    from blue_ticker.analysis.field_parser import FieldSet

from blue_ticker.analysis.xbrl_utils import _extract_html_labels, _find_html_by_prefix, parse_html_number
from blue_ticker.constants.financial import MILLION_YEN

# US-GAAP 連結財政状態計算書 HTML → 仮想タグマッピング
_USGAAP_BS_HTML_LABEL_MAP: dict[str, str] = {
    "流動資産合計":                             "USGAAP_HTML_CurrentAssets",
    "有形固定資産合計":                         "USGAAP_HTML_PPENet",   # 富士フイルム形式
    "有形固定資産":                             "USGAAP_HTML_PPENet",   # キヤノン形式（節番号付き「Ⅳ　有形固定資産」）
    "投資及び長期債権合計":                     "USGAAP_HTML_InvestmentsLTReceivables",
    "その他の資産合計":                         "USGAAP_HTML_OtherNCA",
    "流動負債合計":                             "USGAAP_HTML_CurrentLiabilities",
    "固定負債合計":                             "USGAAP_HTML_NonCurrentLiabilities",
    "負債合計":                                 "USGAAP_HTML_TotalLiabilities",
    "純資産合計":                               "USGAAP_HTML_NetAssets",
    # PPE 内訳（取得原価ベース。土地・建設仮勘定は非償却のため取得原価 = 帳簿価額）
    "土地":                                     "USGAAP_HTML_Land",
    "建設仮勘定":                               "USGAAP_HTML_ConstructionInProgress",
    # PPE 建物・機械（取得原価。富士フイルム形式・キヤノン形式で節番号付きも substring でヒット）
    "建物及び構築物":                           "USGAAP_HTML_BuildingsGross",
    "機械装置及び備品":                         "USGAAP_HTML_MachineryGross",   # キヤノン形式
    "機械装置及びその他の有形固定資産":         "USGAAP_HTML_MachineryGross",   # 富士フイルム形式
    # オペレーティング・リース負債（ASC 842）。節番号・中点の有無を問わず substring でヒット
    "短期オペレーティング":                     "USGAAP_HTML_LeaseLiabilitiesCurrent",
    "長期オペレーティング":                     "USGAAP_HTML_LeaseLiabilitiesNonCurrent",
    # 富士フイルム形式 IBD ラベル
    "社債及び短期借入金":                       "USGAAP_HTML_IBDCurrent",
    "社債及び長期借入金":                       "USGAAP_HTML_IBDNonCurrent",
    # キヤノン形式 IBD ラベル（"長期債務" は CF 文中にも現れるため章番号付きで特定する）
    "短期借入金及び１年以内に返済する長期債務合計": "USGAAP_HTML_IBDCurrent",
    "Ⅱ　長期債務":                          "USGAAP_HTML_IBDNonCurrent",
}

# US-GAAP 連結損益計算書 HTML → 仮想タグマッピング（法人税を除く）
# 法人税は「Ⅴ　法人税等」節ヘッダーを基準にセクション内検索で取得する（_extract_income_tax_section）。
_USGAAP_PL_HTML_LABEL_MAP: dict[str, str] = {
    "販売費及び一般管理費":         "USGAAP_HTML_SGA",
    "営業利益":                    "USGAAP_HTML_OperatingIncome",
    "税金等調整前当期純利益":       "USGAAP_HTML_PreTaxIncome",
    "税引前当期純利益":             "USGAAP_HTML_PreTaxIncome",
    "税金等調整前当期純損失":       "USGAAP_HTML_PreTaxIncome",
    "法人税等合計":                "USGAAP_HTML_IncomeTax",
    "法人税、住民税及び事業税":     "USGAAP_HTML_IncomeTaxCurrent",
    "法人税等調整額":              "USGAAP_HTML_IncomeTaxDeferred",
}

# ローマ数字節番号プレフィックスの正規表現
_ROMAN_RE = re.compile(r'^[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹ]')


def _strip_section_prefix(text: str) -> str:
    """ローマ数字節番号（「Ⅴ　」等）のプレフィックスを除去して本文ラベルを返す。"""
    return re.sub(r'^[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹ\s　]+', '', text).strip()


def _extract_income_tax_section(soup: "BeautifulSoup") -> dict[str, float | None] | None:
    """「Ⅴ　法人税等」節から法人税等合計（百万円）を抽出する。

    節ヘッダー行に数値があればそれを使い、ない場合は節内の最初の「合計」行を使う。
    次のローマ数字節に達したら探索を終了する。
    """
    in_tax_section = False
    for row in soup.find_all("tr"):
        texts = [c.get_text(" ", strip=True) for c in row.find_all(["td", "th"])]
        if not texts:
            continue
        t0 = texts[0]

        if _strip_section_prefix(t0) == "法人税等":
            in_tax_section = True
            nums = [parse_html_number(t) for t in texts[1:]]
            financial = [n for n in nums if n is not None and abs(n) >= 200]
            if financial:
                return {
                    "current": financial[-1] * MILLION_YEN,
                    "prior": (financial[-2] * MILLION_YEN) if len(financial) >= 2 else None,
                }
            continue

        if in_tax_section:
            if _ROMAN_RE.match(t0):
                break
            if t0 == "合計":
                nums = [parse_html_number(t) for t in texts[1:]]
                financial = [n for n in nums if n is not None and abs(n) >= 200]
                if financial:
                    return {
                        "current": financial[-1] * MILLION_YEN,
                        "prior": (financial[-2] * MILLION_YEN) if len(financial) >= 2 else None,
                    }

    return None


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

    US-GAAP 有価証券報告書では以下のように情報が分散する。
    - 税引前利益: 0101010（過去5ヶ年の主要指標表）
    - 法人税等:   0105010（連結財務諸表）の「Ⅴ　法人税等」節
    - 営業利益等: 0105010（同上）

    先にヒットしたファイルの値を優先し、複数ファイルをマージする。
    返す値の単位は円。BS4 が未インストールの場合は空の FieldSet を返す。
    """
    if not _BS4_AVAILABLE:
        return {}  # type: ignore[return-value]

    merged: dict[str, dict[str, float | None]] = {}

    # 0101010（主要指標5ヶ年表）: 税引前利益・売上高・純利益を取得
    html_0101010 = _find_html_by_prefix(xbrl_dir, "0101010")
    if html_0101010 is not None:
        soup = BeautifulSoup(html_0101010.read_text(encoding="utf-8", errors="ignore"), "html.parser")
        for virtual_tag, fv in _extract_html_labels(soup, _USGAAP_PL_HTML_LABEL_MAP).items():
            if virtual_tag not in merged:
                merged[virtual_tag] = fv

    # 0105010（連結財務諸表）: 法人税等・営業利益等を取得
    html_0105010 = _find_html_by_prefix(xbrl_dir, "0105010")
    if html_0105010 is not None:
        soup = BeautifulSoup(html_0105010.read_text(encoding="utf-8", errors="ignore"), "html.parser")
        # 法人税はセクション特定で取得（ラベル部分マッチによる誤拾いを防ぐ）
        tax_fv = _extract_income_tax_section(soup)
        if tax_fv is not None and "USGAAP_HTML_IncomeTax" not in merged:
            merged["USGAAP_HTML_IncomeTax"] = tax_fv
        # その他 P&L ラベルを取得
        for virtual_tag, fv in _extract_html_labels(soup, _USGAAP_PL_HTML_LABEL_MAP).items():
            if virtual_tag not in merged:
                merged[virtual_tag] = fv

    return merged  # type: ignore[return-value]
