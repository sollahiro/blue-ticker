"""US-GAAP 連結損益計算書 HTML から支払利息を抽出する。"""

import re
from pathlib import Path

try:
    from bs4 import BeautifulSoup
    _BS4_AVAILABLE = True
except ImportError:
    _BS4_AVAILABLE = False

from blue_ticker.analysis.xbrl_utils import _find_html_by_prefix, parse_html_int_attribute, parse_html_number
from blue_ticker.constants.financial import MILLION_YEN
from blue_ticker.utils.xbrl_result_types import InterestExpenseResult


def extract_usgaap_ie_from_html(xbrl_dir: Path) -> InterestExpenseResult | None:
    """US-GAAP企業の連結損益計算書(0105010)HTMLから支払利息を抽出する。"""
    if not _BS4_AVAILABLE:
        return None

    # 年次(asr)は 0105010＝第５経理の状況、半期(q2r)は 0104010＝第４経理の状況
    target_file = _find_html_by_prefix(xbrl_dir, "0105010") or _find_html_by_prefix(xbrl_dir, "0104010")
    if target_file is None:
        return None

    content = target_file.read_text(encoding="utf-8", errors="ignore")
    if "支払利息" not in content:
        return None

    soup = BeautifulSoup(content, "html.parser")
    # 半期(q2r)は「前中間連結」「当中間連結」、年次(asr)は「前連結」「当連結」
    _HEADER_MARKERS = ("前連結", "当連結", "前中間", "当中間", "前期", "当期", "第")

    for table in soup.find_all("table"):
        if "支払利息" not in table.get_text():
            continue

        rows = table.find_all("tr")
        if not rows:
            continue

        prior_col_idx = current_col_idx = None
        for row in rows:
            cells = row.find_all(["td", "th"])
            texts = [c.get_text(strip=True) for c in cells]
            if not any(any(m in t for m in _HEADER_MARKERS) for t in texts):
                continue
            col_offset = 0
            for cell in cells:
                text = cell.get_text(strip=True)
                span = parse_html_int_attribute(cell, "colspan")
                last_col = col_offset + span - 1
                if "当連結" in text or "当中間" in text or ("当期" in text and "前期" not in text):
                    current_col_idx = col_offset
                elif "前連結" in text or "前中間" in text or "前期" in text:
                    prior_col_idx = col_offset
                elif re.search(r"第\d+期", text):
                    if prior_col_idx is None:
                        prior_col_idx = col_offset
                    else:
                        current_col_idx = col_offset
                col_offset += span
            if current_col_idx is not None:
                break

        for row in rows:
            cells = row.find_all(["td", "th"])
            if not cells:
                continue
            label = cells[0].get_text(strip=True)
            if "支払利息" not in label:
                continue
            if any(kw in label for kw in ["受取", "未払"]):
                continue

            numerics = [
                (i, parse_html_number(c.get_text(strip=True)))
                for i, c in enumerate(cells)
                if i > 0 and parse_html_number(c.get_text(strip=True)) is not None
            ]
            if not numerics:
                continue

            if prior_col_idx is not None and current_col_idx is not None:
                def _find_nearest(target_col, _nums=numerics):
                    best_val, best_dist, best_idx = None, float("inf"), -1
                    for i, v in _nums:
                        d = abs(i - target_col)
                        if d < best_dist or (d == best_dist and i > best_idx):
                            best_dist, best_val, best_idx = d, v, i
                    return best_val if best_dist <= 2 else None
                prior_val = _find_nearest(prior_col_idx)
                current_val = _find_nearest(current_col_idx)
            else:
                prior_val = numerics[0][1] if len(numerics) >= 2 else None
                current_val = numerics[-1][1]

            if current_val is None and prior_val is None:
                continue

            return {
                "current": abs(current_val) * MILLION_YEN if current_val is not None else None,
                "prior": abs(prior_val) * MILLION_YEN if prior_val is not None else None,
                "method": "usgaap_html",
                "accounting_standard": "US-GAAP",
            }

    return None
