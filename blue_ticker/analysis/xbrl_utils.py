"""
XBRL解析共通ユーティリティ

gross_profit / cash_flow / interest_bearing_debt 各モジュールで共有する
低レベルのXML解析ヘルパー。コンテキスト判定・会計基準判定など
モジュール固有のロジックはここに置かない。
"""

import html as _html_module
import re
import warnings
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

try:
    from bs4 import BeautifulSoup as _BeautifulSoup
    from bs4 import XMLParsedAsHTMLWarning as _XMLParsedAsHTMLWarning
    _BS4_AVAILABLE = True
except ImportError:
    _BS4_AVAILABLE = False
    _XMLParsedAsHTMLWarning = None  # type: ignore[assignment,misc]

from blue_ticker.constants.financial import MILLION_YEN
from blue_ticker.utils.xbrl_result_types import XbrlFact, XbrlFactIndex, XbrlTagElements


def parse_html_int_attribute(element: Any, attr: str, default: int = 1) -> int:
    """HTML要素の整数属性を安全に読む。BeautifulSoup の型定義は list/None も返し得る。"""
    value = element.get(attr)
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            return default
    if isinstance(value, int):
        return value
    return default


def parse_html_number(text: str) -> float | None:
    """HTML表セルの数値テキストを float に変換（百万円単位のまま）。
    "22,548" → 22548.0, "22,548百万円" → 22548.0, "△8,752" → -8752.0, "－" → None
    """
    if not text:
        return None
    text = text.strip()
    text = re.sub(r'(百万円|十万円|億円|兆円|千円|百円|万円|円)$', '', text).strip()
    text = text.replace(",", "").replace("，", "")
    # △ は日本の会計慣行で負数を示す（例: △8,752 → -8752）
    if text.startswith("△"):
        text = "-" + text[1:]
    if text in ("－", "-", "―", "—", ""):
        return None
    try:
        return float(text)
    except ValueError:
        return None


def parse_xbrl_value(text: str | None) -> float | None:
    """XBRL数値テキストを float に変換。nil・空文字は None を返す。"""
    if not text or text.strip() in ("", "nil"):
        return None
    try:
        return float(text.strip())
    except (ValueError, TypeError):
        return None


_XSI_NIL = "{http://www.w3.org/2001/XMLSchema-instance}nil"
_XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"
_XLINK = "{http://www.w3.org/1999/xlink}"
_ROLE_LABEL = "http://www.xbrl.org/2003/role/label"


def _local_name(tag: str) -> str:
    return tag.split("}", 1)[1] if "}" in tag else tag


def _xlink_attr(name: str) -> str:
    return f"{_XLINK}{name}"


def _concept_local_name(concept: str) -> str:
    """linkbase の concept id / href fragment から XBRL 要素の local name を取り出す。"""
    fragment = concept.rsplit("#", 1)[-1]
    if ":" in fragment:
        return fragment.rsplit(":", 1)[-1]
    parts = fragment.split("_")
    # 末尾から探す: 会社コード (E01737-000 等) が先にヒットするのを避ける
    for part in reversed(parts):
        if part and part[0].isupper():
            return part
    return fragment


def _section_name_from_role(role: str) -> str:
    section = role.rstrip("/").rsplit("/", 1)[-1]
    return section[4:] if section.startswith("rol_") else section


def _infer_consolidation(context_ref: str, roles: list[str]) -> str:
    role_text = " ".join(_section_name_from_role(role) for role in roles)
    if "_NonConsolidated" in context_ref or "ReportingCompany" in role_text:
        return "non_consolidated"
    if "Consolidated" in role_text:
        return "consolidated"
    return "unknown"


def _linkbase_xml_files(xbrl_dir: Path, suffix: str) -> list[Path]:
    return [
        f for f in xbrl_dir.rglob(f"*{suffix}*.xml")
        if suffix in f.name
    ]


def _load_labels_by_tag(xbrl_dir: Path) -> dict[str, str]:
    """ラベルリンクベースから {local_tag: Japanese label} を作る。"""
    labels_by_tag: dict[str, str] = {}
    for xml_file in _linkbase_xml_files(xbrl_dir, "_lab"):
        try:
            root = ET.parse(xml_file).getroot()
        except ET.ParseError:
            continue

        loc_by_label: dict[str, str] = {}
        label_text_by_resource: dict[str, tuple[str, str]] = {}

        for elem in root.iter():
            local = _local_name(elem.tag)
            if local == "loc":
                locator_label = elem.attrib.get(_xlink_attr("label"))
                href = elem.attrib.get(_xlink_attr("href"))
                if locator_label and href:
                    loc_by_label[locator_label] = _concept_local_name(href)
            elif local == "label":
                lang = elem.attrib.get(_XML_LANG)
                if lang is not None and lang != "ja":
                    continue
                resource_label = elem.attrib.get(_xlink_attr("label"))
                role = elem.attrib.get(_xlink_attr("role"), "")
                text = "".join(elem.itertext()).strip()
                if resource_label and text:
                    label_text_by_resource[resource_label] = (role, text)

        for elem in root.iter():
            if _local_name(elem.tag) != "labelArc":
                continue
            from_label = elem.attrib.get(_xlink_attr("from"))
            to_label = elem.attrib.get(_xlink_attr("to"))
            if not from_label or not to_label:
                continue
            tag = loc_by_label.get(from_label)
            label_pair = label_text_by_resource.get(to_label)
            if tag is None or label_pair is None:
                continue
            role, text = label_pair
            if role == _ROLE_LABEL or tag not in labels_by_tag:
                labels_by_tag[tag] = text
    return labels_by_tag


def _load_roles_by_tag(xbrl_dir: Path) -> dict[str, list[str]]:
    """プレゼンテーションリンクベースから {local_tag: roleURI list} を作る。"""
    role_sets_by_tag: dict[str, set[str]] = {}
    for xml_file in _linkbase_xml_files(xbrl_dir, "_pre"):
        try:
            root = ET.parse(xml_file).getroot()
        except ET.ParseError:
            continue
        for link in root.iter():
            if _local_name(link.tag) != "presentationLink":
                continue
            role = link.attrib.get(_xlink_attr("role"))
            if not role:
                continue
            for elem in link.iter():
                if _local_name(elem.tag) != "loc":
                    continue
                href = elem.attrib.get(_xlink_attr("href"))
                if not href:
                    continue
                tag = _concept_local_name(href)
                role_sets_by_tag.setdefault(tag, set()).add(role)
    return {
        tag: sorted(roles)
        for tag, roles in role_sets_by_tag.items()
    }


def fact_index_to_numeric_elements(facts: XbrlFactIndex) -> XbrlTagElements:
    """メタ付き fact index を既存抽出器互換の {tag: {contextRef: value}} に変換する。"""
    return {
        tag: {
            context_ref: fact["value"]
            for context_ref, fact in ctx_map.items()
        }
        for tag, ctx_map in facts.items()
    }


def _fact_sections(fact: XbrlFact) -> set[str]:
    sections: set[str] = set()
    section = fact.get("section")
    if isinstance(section, str):
        sections.add(section)
    for value in fact.get("sections", []):
        if isinstance(value, str):
            sections.add(value)
    return sections


def filter_fact_index_by_sections(
    facts: XbrlFactIndex,
    preferred_sections: tuple[str, ...],
    fallback_sections: tuple[str, ...] = (),
) -> XbrlFactIndex:
    """statement/role section を優先して fact index を絞り込む。

    preferred_sections に一致する fact があればそれを返し、なければ
    fallback_sections を試す。どちらも空の場合は空 dict を返す。
    """

    def _filter(sections: tuple[str, ...]) -> XbrlFactIndex:
        section_set = set(sections)
        result: XbrlFactIndex = {}
        for tag, ctx_map in facts.items():
            for context_ref, fact in ctx_map.items():
                if not (_fact_sections(fact) & section_set):
                    continue
                if tag not in result:
                    result[tag] = {}
                result[tag][context_ref] = fact
        return result

    preferred = _filter(preferred_sections)
    if preferred:
        return preferred
    if fallback_sections:
        return _filter(fallback_sections)
    return {}


def collect_numeric_facts(
    xml_file: Path,
    allowed_tags: frozenset[str] | None = None,
    nil_as_zero: bool = False,
    *,
    labels_by_tag: dict[str, str] | None = None,
    roles_by_tag: dict[str, list[str]] | None = None,
) -> XbrlFactIndex:
    """XMLファイルから {local_tag: {contextRef: XbrlFact}} の辞書を返す。"""
    results: XbrlFactIndex = {}
    labels_by_tag = labels_by_tag or {}
    roles_by_tag = roles_by_tag or {}
    try:
        tree = ET.parse(xml_file)
        root = tree.getroot()
        for elem in root.iter():
            local_tag = _local_name(elem.tag)
            if allowed_tags is not None and local_tag not in allowed_tags:
                continue
            ctx = elem.attrib.get("contextRef", "")
            value = parse_xbrl_value(elem.text)
            if value is None and nil_as_zero and elem.attrib.get(_XSI_NIL, "").lower() == "true":
                value = 0.0
            if value is None or not ctx:
                continue

            roles = roles_by_tag.get(local_tag, [])
            sections = [_section_name_from_role(role) for role in roles]
            fact: XbrlFact = {
                "tag": local_tag,
                "contextRef": ctx,
                "value": value,
                "consolidation": _infer_consolidation(ctx, roles),
                "source_file": xml_file.name,
            }
            unit_ref = elem.attrib.get("unitRef")
            decimals = elem.attrib.get("decimals")
            label = labels_by_tag.get(local_tag)
            if unit_ref is not None:
                fact["unitRef"] = unit_ref
            if decimals is not None:
                fact["decimals"] = decimals
            if roles:
                fact["role"] = roles[0]
                fact["roles"] = roles
            if sections:
                fact["section"] = sections[0]
                fact["sections"] = sections
            if label is not None:
                fact["label"] = label

            if local_tag not in results:
                results[local_tag] = {}
            results[local_tag][ctx] = fact
    except ET.ParseError:
        pass
    return results


def collect_numeric_elements(
    xml_file: Path,
    allowed_tags: frozenset[str] | None = None,
    nil_as_zero: bool = False,
) -> XbrlTagElements:
    """XMLファイルから {local_tag: {contextRef: value}} の辞書を返す。

    allowed_tags を指定すると、そのセット外のタグをスキップして高速化できる。
    nil_as_zero=True のとき xsi:nil="true" の要素を 0.0 として記録する。
    """
    return fact_index_to_numeric_elements(
        collect_numeric_facts(xml_file, allowed_tags, nil_as_zero)
    )


def collect_all_numeric_facts(
    xbrl_dir: Path,
    nil_as_zero: bool = True,
) -> XbrlFactIndex:
    """XBRLディレクトリ内の全数値 fact をメタ情報付きで返す。"""
    all_facts: XbrlFactIndex = {}
    labels_by_tag = _load_labels_by_tag(xbrl_dir)
    roles_by_tag = _load_roles_by_tag(xbrl_dir)
    for f in find_xbrl_files(xbrl_dir):
        for tag, ctx_map in collect_numeric_facts(
            f,
            allowed_tags=None,
            nil_as_zero=nil_as_zero,
            labels_by_tag=labels_by_tag,
            roles_by_tag=roles_by_tag,
        ).items():
            if tag not in all_facts:
                all_facts[tag] = {}
            all_facts[tag].update(ctx_map)
    return all_facts


def collect_all_numeric_elements(
    xbrl_dir: Path,
    nil_as_zero: bool = True,
) -> XbrlTagElements:
    """XBRLディレクトリ内の全ファイルを一括パースし、全タグの数値要素を返す。

    nil_as_zero=True（デフォルト）は有利子負債の nil 明示ゼロ検出に必要なため、
    一括パースではデフォルトで有効にする。
    """
    return fact_index_to_numeric_elements(collect_all_numeric_facts(xbrl_dir, nil_as_zero))


def find_xbrl_files(xbrl_dir: Path) -> list[Path]:
    """XBRLディレクトリからインスタンス文書（.xml / .xbrl）を返す。

    ラベル・プレゼンテーション・計算・定義リンクベースは除外する。
    """
    xml_files = [
        f for f in xbrl_dir.rglob("*.xml")
        if not any(s in f.name for s in ["_lab", "_pre", "_cal", "_def"])
    ]
    xml_files += list(xbrl_dir.rglob("*.xbrl"))
    return xml_files


def _parse_ifrs_textblock_cell_value(text: str) -> float | None:
    """HTMLセルテキスト（△xxx,xxx）→ float 変換（百万円単位）。"""
    text = text.strip().replace("\xa0", "").replace("　", "").replace(" ", "")
    if not text or text in ("－", "-", "—", "―"):
        return None
    negative = text.startswith("△") or text.startswith("▲")
    digits = text.lstrip("△▲").replace(",", "")
    try:
        val = float(digits)
    except ValueError:
        return None
    return -val if negative else val


def extract_ifrs_textblock_table(
    xbrl_dir: Path,
    textblock_tag: str,
) -> dict[str, tuple[float | None, float | None]]:
    """IFRS Summary型XBRLのTextBlock HTMLテーブルをパースする。

    IFRS移行初期など連結財務諸表がTextBlockとして収録されている場合に使う。
    ラベル（行の先頭セルテキスト）→ (当期値, 前期値) を返す。値は百万円単位。

    テーブル列の右端が当期、右から2番目が前期として扱う。
    note参照列（"19, 35" 等）はfloat変換失敗で自動的にスキップされる。
    """
    if not _BS4_AVAILABLE:
        return {}

    tag_pattern = re.compile(
        r"<[^>]*:" + re.escape(textblock_tag) + r"[^>]*>(.*?)</[^>]*:" + re.escape(textblock_tag) + r">",
        re.DOTALL,
    )

    for xbrl_file in find_xbrl_files(xbrl_dir):
        raw = xbrl_file.read_text(encoding="utf-8", errors="ignore")
        m = tag_pattern.search(raw)
        if not m:
            continue

        html_content = _html_module.unescape(m.group(1))
        with warnings.catch_warnings():
            if _XMLParsedAsHTMLWarning is not None:
                warnings.filterwarnings("ignore", category=_XMLParsedAsHTMLWarning)
            soup = _BeautifulSoup(html_content, "html.parser")

        result: dict[str, tuple[float | None, float | None]] = {}
        for tr in soup.find_all("tr"):
            cells = tr.find_all("td")
            if len(cells) < 3:
                continue
            label = cells[0].get_text(strip=True)
            if not label:
                continue
            # 右端2列を当期・前期として取得。
            # 「右端から非Noneまでスキップ」方式は3列BSテーブル（FY-2, FY-1, FY）で
            # 当期・前期がともに「－」の場合にFY-2の値を誤取得するため、
            # 列数によらず必ず rightmost=当期・次=前期 として固定取得する。
            data_cells = cells[1:]
            if len(data_cells) < 2:
                continue
            current_v = _parse_ifrs_textblock_cell_value(data_cells[-1].get_text(strip=True))
            prior_v = _parse_ifrs_textblock_cell_value(data_cells[-2].get_text(strip=True))
            if current_v is not None or prior_v is not None:
                result[label] = (current_v, prior_v)
        return result

    return {}


def _find_html_by_prefix(xbrl_dir: Path, prefix: str) -> Path | None:
    """xbrl_dir 内で指定プレフィックス（0105010 等）で始まる HTML ファイルを返す。

    PublicDoc 直下と XBRL/PublicDoc の両方を探索する。
    """
    candidates = [xbrl_dir, xbrl_dir / "XBRL" / "PublicDoc"]
    for search_dir in candidates:
        if not search_dir.is_dir():
            continue
        for ext in ("*.htm", "*.html"):
            files = [f for f in search_dir.glob(ext) if f.name.startswith(prefix)]
            if files:
                return files[0]
    return None


def _extract_html_labels(
    soup: "_BeautifulSoup",
    label_map: dict[str, str],
) -> dict[str, dict[str, float | None]]:
    """soup の全 <tr> を走査し label_map に一致する行の当期/前期値を返す。

    列構造パターン:
      A: [ラベル, (注記,) 前期値, 当期値]           ← 富士フイルム等
      B: [ラベル, (注記,) 前期値, 前期比%, 当期値, 当期比%]  ← キヤノン等（構成比列あり）

    財務金額（百万円単位）は通常 >= 200 であり、構成比（0–100）と区別できる。
    「最後の財務値 = 当期、末尾から2番目の財務値 = 前期」で統一して取得する。
    """
    field_set: dict[str, dict[str, float | None]] = {}
    remaining = set(label_map.keys())

    for row in soup.find_all("tr"):
        if not remaining:
            break
        cells = row.find_all(["td", "th"])
        if not cells:
            continue
        texts = [c.get_text(" ", strip=True).replace("\xa0", " ") for c in cells]

        matched: str | None = None
        if texts:
            for label in list(remaining):
                if texts[0] == label:
                    matched = label
                    break
        if matched is None:
            for label in sorted(remaining, key=len, reverse=True):
                if any(label in text for text in texts):
                    matched = label
                    break
        if matched is None:
            continue

        numbers = [parse_html_number(t) for t in texts]
        all_nums = [n for n in numbers if n is not None]
        if not all_nums:
            continue
        financial = [n for n in all_nums if abs(n) >= 200]
        found = financial if financial else all_nums
        current = found[-1] * MILLION_YEN
        prior = found[-2] * MILLION_YEN if len(found) >= 2 else None
        field_set[label_map[matched]] = {"current": current, "prior": prior}
        remaining.discard(matched)

    return field_set
