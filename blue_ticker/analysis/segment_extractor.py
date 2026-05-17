"""
連結財務諸表注記からセグメント・地域別情報を抽出する。

  extract_segment_info()   → 事業別（報告セグメント別）
  extract_geography_info() → 地域別（所在地別）

優先: XBRLのTextBlock内のHTML表をそのまま構造化
フォールバック: XBRLのcontextのdimension付きfact
"""

import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, NotRequired, TypedDict

try:
    from bs4 import BeautifulSoup, Tag
    _BS4_AVAILABLE = True
except ImportError:
    _BS4_AVAILABLE = False

from blue_ticker.analysis.xbrl_utils import (
    find_xbrl_files,
    collect_all_numeric_facts,
    parse_html_int_attribute,
)


class SegmentTable(TypedDict):
    heading: str
    markdown: str
    period: NotRequired[str]  # "当期" | "前期" | "比較"


class SegmentFact(TypedDict):
    tag: str
    contextRef: str
    dimensions: dict[str, str]
    value: float
    label: NotRequired[str]
    unitRef: NotRequired[str]
    decimals: NotRequired[str]


class SegmentResult(TypedDict):
    method: str
    tables: list[SegmentTable]
    facts: list[SegmentFact]


# 事業別セグメント
_BUSINESS_TEXT_BLOCK_TAGS: frozenset[str] = frozenset([
    "SegmentInformationTextBlock",
    "SegmentInformationIFRSTextBlock",
    "SegmentInformationUSGAAPTextBlock",
    "SegmentInformationByBusinessSegmentTextBlock",
])
_BUSINESS_HEADING_KEYWORDS: list[str] = [
    "セグメント情報等",
    "セグメント情報",
]
_BUSINESS_DIMENSION_KEYWORDS: tuple[str, ...] = (
    "OperatingSegments",
    "BusinessSegment",
    "ReportableSegment",
)

# 地域別
_GEOGRAPHY_TEXT_BLOCK_TAGS: frozenset[str] = frozenset([
    "InformationAboutGeographicalAreasIFRSTextBlock",              # IFRS
    "InformationAboutGeographicalAreasTextBlock",                   # J-GAAP
    "InformationAboutGeographicalAreasUSGAAPTextBlock",             # US-GAAP
    "RelatedInformationTextBlock",                                  # J-GAAP 関連情報（混在）
    "RevenuesFromExternalCustomersInformationForEachRegionTextBlock",   # J-GAAP 地域ごとの外部顧客への売上収益
    "PropertyPlantAndEquipmentInformationForEachRegionTextBlock",       # J-GAAP 地域ごとの有形固定資産
])
_GEOGRAPHY_MIXED_TAGS: frozenset[str] = frozenset([
    "RelatedInformationTextBlock",                          # J-GAAP 関連情報（セグメント・地域が混在）
    "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock",  # US-GAAP 連結財務諸表注記（地域別を内包）
])
_GEOGRAPHY_HEADING_KEYWORDS: list[str] = [
    "地域ごとの情報",
    "地域別",
    "所在地別",
]
_GEOGRAPHY_DIMENSION_KEYWORDS: tuple[str, ...] = (
    "GeographicArea",
    "Geography",
    "Country",
    "Region",
    "NoncurrentAssetsByLocation",
)

_XBRLDI_NS = "http://xbrl.org/2006/xbrldi"

_CURRENT_PERIOD_KEYWORDS: tuple[str, ...] = ("当連結会計年度", "当期")
_PRIOR_PERIOD_KEYWORDS: tuple[str, ...] = ("前連結会計年度", "前期")


def _expand_table(table_tag: Any) -> list[list[str]]:
    grid: dict[tuple[int, int], str] = {}
    row_idx = 0
    for tr in table_tag.find_all("tr"):
        col_idx = 0
        for cell in tr.find_all(["td", "th"]):
            while (row_idx, col_idx) in grid:
                col_idx += 1
            text = cell.get_text(strip=True)
            rowspan = parse_html_int_attribute(cell, "rowspan", 1)
            colspan = parse_html_int_attribute(cell, "colspan", 1)
            for r in range(rowspan):
                for c in range(colspan):
                    grid[(row_idx + r, col_idx + c)] = text
            col_idx += colspan
        row_idx += 1
    if not grid:
        return []
    max_row = max(r for r, _ in grid) + 1
    max_col = max(c for _, c in grid) + 1
    return [[grid.get((r, c), "") for c in range(max_col)] for r in range(max_row)]


def _grid_to_markdown(grid: list[list[str]]) -> str:
    if not grid:
        return ""
    col_count = max(len(row) for row in grid)
    col_widths = [
        max((len(row[c]) if c < len(row) else 0) for row in grid)
        for c in range(col_count)
    ]
    lines: list[str] = []
    for i, row in enumerate(grid):
        cells = [(row[c] if c < len(row) else "").ljust(col_widths[c]) for c in range(col_count)]
        lines.append("| " + " | ".join(cells) + " |")
        if i == 0:
            lines.append("|" + "|".join("-" * (w + 2) for w in col_widths) + "|")
    return "\n".join(lines)


def _detect_period_from_grid(grid: list[list[str]]) -> str | None:
    """グリッド先頭3行のテキストから当期/前期を判定する。"""
    for row in grid[:3]:
        joined = "".join(row)
        has_current = any(kw in joined for kw in _CURRENT_PERIOD_KEYWORDS)
        has_prior = any(kw in joined for kw in _PRIOR_PERIOD_KEYWORDS)
        if has_current and has_prior:
            return "比較"
        if has_current:
            return "当期"
        if has_prior:
            return "前期"
    return None


def _detect_period_from_preceding(table_tag: Any) -> str | None:
    """テーブル前の兄弟要素（短いもの）から当期/前期を判定する。"""
    for sibling in reversed(list(table_tag.previous_siblings)):
        if not hasattr(sibling, "get_text"):
            continue
        text = sibling.get_text(strip=True)
        if not text or len(text) > 100:
            continue
        if any(kw in text for kw in _CURRENT_PERIOD_KEYWORDS):
            return "当期"
        if any(kw in text for kw in _PRIOR_PERIOD_KEYWORDS):
            return "前期"
    return None


def _apply_period_ordering(tables: list[SegmentTable]) -> None:
    """当期/前期が未ラベルのテーブルに順序ルール（前期→当期の繰り返し）を適用する。"""
    unlabeled = [t for t in tables if "period" not in t]
    for i, t in enumerate(unlabeled):
        t["period"] = "前期" if i % 2 == 0 else "当期"


def _find_next_table(element: Any) -> Any | None:
    for sibling in element.next_siblings:
        if not isinstance(sibling, Tag):
            continue
        if sibling.name == "table":
            return sibling
        found = sibling.find("table")
        if found and isinstance(found, Tag):
            return found
    return None


def _get_element_html(elem: ET.Element) -> str:
    if elem.text and "<" in elem.text:
        return elem.text
    parts: list[str] = []
    if elem.text:
        parts.append(elem.text)
    for child in elem:
        parts.append(ET.tostring(child, encoding="unicode"))
        if child.tail:
            parts.append(child.tail)
    return "".join(parts)


def _all_tables_from_html(html_content: str, default_heading: str) -> list[SegmentTable]:
    """HTML内の全 <table> を Markdown 化して返す。"""
    soup = BeautifulSoup(html_content, "html.parser")
    tables: list[SegmentTable] = []
    for table in soup.find_all("table"):
        grid = _expand_table(table)
        md = _grid_to_markdown(grid)
        if not md:
            continue
        entry: SegmentTable = {"heading": default_heading, "markdown": md}
        # A: グリッド内容と直前要素から当期/前期を検出
        period = _detect_period_from_preceding(table) or _detect_period_from_grid(grid)
        if period:
            entry["period"] = period
        tables.append(entry)
    # B: 未ラベルに順序ルール（前期→当期の繰り返し）を適用
    _apply_period_ordering(tables)
    return tables


def _keyword_tables_from_html(html_content: str, keywords: list[str]) -> list[SegmentTable]:
    """見出しキーワードに続く <table> を Markdown 化して返す。"""
    soup = BeautifulSoup(html_content, "html.parser")
    tables: list[SegmentTable] = []
    seen: set[int] = set()
    for keyword in keywords:
        for elem in soup.find_all(True):
            if not isinstance(elem, Tag):
                continue
            text = elem.get_text()
            if keyword not in text or len(text) > 300:
                continue
            table = _find_next_table(elem)
            if table is None or id(table) in seen:
                continue
            seen.add(id(table))
            grid = _expand_table(table)
            md = _grid_to_markdown(grid)
            if not md:
                continue
            entry: SegmentTable = {"heading": keyword, "markdown": md}
            period = _detect_period_from_preceding(table) or _detect_period_from_grid(grid)
            if period:
                entry["period"] = period
            tables.append(entry)
    # B: 未ラベルに順序ルール（前期→当期の繰り返し）を適用
    _apply_period_ordering(tables)
    return tables


def _extract_from_text_blocks(
    xbrl_dir: Path,
    dedicated_tags: frozenset[str],
    mixed_tags: frozenset[str],
    dedicated_heading: str,
    mixed_keywords: list[str],
) -> list[SegmentTable]:
    """TextBlock要素からHTML表を抽出する汎用ロジック。

    dedicated_tags に一致するブロックは全 table を返す。
    mixed_tags に一致するブロックは mixed_keywords で見出しを絞る。
    """
    if not _BS4_AVAILABLE:
        return []
    tables: list[SegmentTable] = []
    for xml_file in find_xbrl_files(xbrl_dir):
        try:
            root = ET.parse(xml_file).getroot()
        except ET.ParseError:
            continue
        for elem in root.iter():
            local_tag = elem.tag.split("}", 1)[1] if "}" in elem.tag else elem.tag
            html_content = _get_element_html(elem)
            if not html_content.strip() or "<table" not in html_content.lower():
                continue
            if local_tag in dedicated_tags:
                tables.extend(_all_tables_from_html(html_content, dedicated_heading))
            elif local_tag in mixed_tags:
                tables.extend(_keyword_tables_from_html(html_content, mixed_keywords))
    return tables


def _load_dimension_context_map(xbrl_dir: Path) -> dict[str, dict[str, str]]:
    context_map: dict[str, dict[str, str]] = {}
    for xml_file in find_xbrl_files(xbrl_dir):
        try:
            root = ET.parse(xml_file).getroot()
        except ET.ParseError:
            continue
        for ctx in root.iter():
            local = ctx.tag.split("}", 1)[1] if "}" in ctx.tag else ctx.tag
            if local != "context":
                continue
            ctx_id = ctx.attrib.get("id")
            if not ctx_id:
                continue
            dims: dict[str, str] = {}
            for member in ctx.iter(f"{{{_XBRLDI_NS}}}explicitMember"):
                dim = member.attrib.get("dimension", "")
                dim_local = dim.split(":")[-1] if ":" in dim else dim
                val = (member.text or "").strip()
                val_local = val.split(":")[-1] if ":" in val else val
                if dim_local and val_local:
                    dims[dim_local] = val_local
            if dims:
                context_map[ctx_id] = dims
    return context_map


def _extract_facts_by_dimension(
    xbrl_dir: Path,
    dimension_keywords: tuple[str, ...],
    context_map: dict[str, dict[str, str]],
) -> list[SegmentFact]:
    all_facts = collect_all_numeric_facts(xbrl_dir)
    results: list[SegmentFact] = []
    for tag, ctx_map in all_facts.items():
        for ctx_id, fact in ctx_map.items():
            dims = context_map.get(ctx_id)
            if not dims:
                continue
            if not any(kw in dim for dim in dims for kw in dimension_keywords):
                continue
            entry: SegmentFact = {
                "tag": tag,
                "contextRef": ctx_id,
                "dimensions": dims,
                "value": fact["value"],
            }
            if "label" in fact:
                entry["label"] = fact["label"]
            if "unitRef" in fact:
                entry["unitRef"] = fact["unitRef"]
            if "decimals" in fact:
                entry["decimals"] = fact["decimals"]
            results.append(entry)
    return results


def _build_result(xbrl_dir: Path, tables: list[SegmentTable], dimension_keywords: tuple[str, ...]) -> SegmentResult:
    if tables:
        return {"method": "html_table", "tables": tables, "facts": []}
    context_map = _load_dimension_context_map(xbrl_dir)
    facts = _extract_facts_by_dimension(xbrl_dir, dimension_keywords, context_map)
    if facts:
        return {"method": "xbrl_facts", "tables": [], "facts": facts}
    return {"method": "not_found", "tables": [], "facts": []}


def extract_segment_info(xbrl_dir: Path) -> SegmentResult:
    """連結財務諸表注記から事業別（報告セグメント別）情報を抽出する。"""
    tables = _extract_from_text_blocks(
        xbrl_dir,
        dedicated_tags=_BUSINESS_TEXT_BLOCK_TAGS,
        mixed_tags=frozenset(),
        dedicated_heading="セグメント情報",
        mixed_keywords=[],
    )
    return _build_result(xbrl_dir, tables, _BUSINESS_DIMENSION_KEYWORDS)


def extract_geography_info(xbrl_dir: Path) -> SegmentResult:
    """連結財務諸表注記から地域別（所在地別）情報を抽出する。"""
    dedicated = _GEOGRAPHY_TEXT_BLOCK_TAGS - _GEOGRAPHY_MIXED_TAGS
    tables = _extract_from_text_blocks(
        xbrl_dir,
        dedicated_tags=dedicated,
        mixed_tags=_GEOGRAPHY_MIXED_TAGS,
        dedicated_heading="地域ごとの情報",
        mixed_keywords=_GEOGRAPHY_HEADING_KEYWORDS,
    )
    return _build_result(xbrl_dir, tables, _GEOGRAPHY_DIMENSION_KEYWORDS)
