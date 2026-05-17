"""
XBRL フィールドパーサー

Stage 1: XBRL XML → FieldSet（タグ名 → 連結当期/前期値）
Stage 2: FieldSet + 項目定義 → 構造化された財務項目値

XBRLの生XMLパース（collect_numeric_elements）とコンテキスト解釈を分離し、
上位レイヤーが「どのタグを選ぶか」だけに集中できるようにする。
"""

from pathlib import Path
from typing import TypedDict

try:
    from bs4 import BeautifulSoup
    _BS4_AVAILABLE = True
except ImportError:
    _BS4_AVAILABLE = False

from blue_ticker.analysis.context_helpers import (
    _is_consolidated_duration,
    _is_consolidated_instant,
    _is_consolidated_prior_duration,
    _is_consolidated_prior_instant,
    _is_nonconsolidated_duration,
    _is_nonconsolidated_instant,
    _is_nonconsolidated_prior_duration,
    _is_nonconsolidated_prior_instant,
    _is_pure_nonconsolidated_context,
    has_nonconsolidated_contexts,
)
from blue_ticker.analysis.xbrl_utils import collect_numeric_elements, find_xbrl_files, parse_html_number
from blue_ticker.constants.financial import MILLION_YEN
from blue_ticker.constants.xbrl import (
    DURATION_CONTEXT_PATTERNS,
    INSTANT_CONTEXT_PATTERNS,
    PRIOR_DURATION_CONTEXT_PATTERNS,
    PRIOR_INSTANT_CONTEXT_PATTERNS,
)
from blue_ticker.utils.xbrl_result_types import XbrlTagElements


class FieldValue(TypedDict):
    current: float | None
    prior: float | None


FieldSet = dict[str, FieldValue]


class ResolvedItem(TypedDict):
    tag: str | None
    current: float | None
    prior: float | None


def field_set_from_pre_parsed(
    tag_elements: XbrlTagElements,
    *,
    financial_tags: frozenset[str] | None = None,
) -> FieldSet:
    """XbrlTagElements（生パース済みデータ）から FieldSet を生成する。

    parse_instant_fields のファイルI/Oをスキップしたい場合のヘルパー。
    コンテキスト正規化・nonconsolidated フォールバックは parse_instant_fields と同一。

    financial_tags を渡すと、連結判定（has_nonconsolidated_contexts）をそのタグセットに
    絞って行う。DEI タグ等の非財務タグが判定を歪めるのを防ぐために使う。
    """
    field_set = _normalize_instant(tag_elements)
    check = {t: v for t, v in tag_elements.items() if t in financial_tags} if financial_tags else tag_elements
    if not has_nonconsolidated_contexts(check):
        nc_set = _normalize_instant_nonconsolidated(tag_elements)
        for tag, fv in nc_set.items():
            if tag not in field_set:
                field_set[tag] = fv
    return field_set


def parse_instant_fields(
    xbrl_dir: Path,
    *,
    allowed_tags: frozenset[str] | None = None,
) -> FieldSet:
    """XBRL ディレクトリから Instant（期末残高）コンテキストの全タグを読み込み、
    連結当期/前期値に正規化して返す。

    連結グループを持たない個別財務諸表のみの企業（_NonConsolidatedMember コンテキスト）は、
    個別コンテキストにフォールバックして値を返す。
    allowed_tags を渡すと収集対象を絞れる（None = 全タグ）。
    """
    tag_elements: XbrlTagElements = {}
    for f in find_xbrl_files(xbrl_dir):
        for tag, ctx_map in collect_numeric_elements(f, allowed_tags=allowed_tags).items():
            if tag not in tag_elements:
                tag_elements[tag] = {}
            tag_elements[tag].update(ctx_map)

    field_set = _normalize_instant(tag_elements)

    # 連結グループを持たない企業: 個別コンテキストにフォールバック
    if not has_nonconsolidated_contexts(tag_elements):
        nc_set = _normalize_instant_nonconsolidated(tag_elements)
        for tag, fv in nc_set.items():
            if tag not in field_set:
                field_set[tag] = fv

    return field_set


def field_set_from_pre_parsed_duration(
    tag_elements: XbrlTagElements,
    *,
    financial_tags: frozenset[str] | None = None,
) -> FieldSet:
    """XbrlTagElements（生パース済みデータ）から Duration FieldSet を生成する。

    parse_duration_fields のファイルI/Oをスキップしたい場合のヘルパー。
    コンテキスト正規化・nonconsolidated フォールバックは parse_duration_fields と同一。

    financial_tags を渡すと、連結判定（has_nonconsolidated_contexts）をそのタグセットに
    絞って行う。DEI タグ等の非財務タグが判定を歪めるのを防ぐために使う。
    """
    field_set = _normalize_duration(tag_elements)
    check = {t: v for t, v in tag_elements.items() if t in financial_tags} if financial_tags else tag_elements
    if not has_nonconsolidated_contexts(check):
        nc_set = _normalize_duration_nonconsolidated(tag_elements)
        for tag, fv in nc_set.items():
            if tag not in field_set:
                field_set[tag] = fv
    # Instant コンテキストのみのタグ（会計基準マーカー等）を存在記録として追加する
    for tag in tag_elements:
        if tag not in field_set:
            field_set[tag] = {"current": None, "prior": None}
    return field_set


def parse_duration_fields(
    xbrl_dir: Path,
    *,
    allowed_tags: frozenset[str] | None = None,
) -> FieldSet:
    """XBRL ディレクトリから Duration（フロー項目）コンテキストの全タグを読み込み、
    連結当期/前期値に正規化して返す。

    連結グループを持たない個別財務諸表のみの企業（_NonConsolidatedMember コンテキスト）は、
    個別コンテキストにフォールバックして値を返す。
    allowed_tags を渡すと収集対象を絞れる（None = 全タグ）。
    """
    tag_elements: XbrlTagElements = {}
    for f in find_xbrl_files(xbrl_dir):
        for tag, ctx_map in collect_numeric_elements(f, allowed_tags=allowed_tags).items():
            if tag not in tag_elements:
                tag_elements[tag] = {}
            tag_elements[tag].update(ctx_map)

    field_set = _normalize_duration(tag_elements)

    # 連結グループを持たない企業: 個別コンテキストにフォールバック
    if not has_nonconsolidated_contexts(tag_elements):
        nc_set = _normalize_duration_nonconsolidated(tag_elements)
        for tag, fv in nc_set.items():
            if tag not in field_set:
                field_set[tag] = fv

    # Instant コンテキストのみのタグ（会計基準マーカー等）を存在記録として追加する
    for tag in tag_elements:
        if tag not in field_set:
            field_set[tag] = {"current": None, "prior": None}

    return field_set


def _normalize_duration(tag_elements: XbrlTagElements) -> FieldSet:
    """XbrlTagElements → FieldSet（Duration コンテキスト用）。

    完全一致コンテキスト（CurrentYearDuration 等）を最優先し、
    前方一致パターン（_is_consolidated_duration 等）をフォールバックにする。
    """
    exact_current: frozenset[str] = frozenset(DURATION_CONTEXT_PATTERNS)
    exact_prior: frozenset[str] = frozenset(PRIOR_DURATION_CONTEXT_PATTERNS)

    field_set: FieldSet = {}
    for tag, ctx_map in tag_elements.items():
        current: float | None = None
        prior: float | None = None

        for ctx, val in ctx_map.items():
            if ctx in exact_current:
                current = val
            elif ctx in exact_prior:
                prior = val

        if current is None or prior is None:
            for ctx, val in ctx_map.items():
                if current is None and _is_consolidated_duration(ctx):
                    current = val
                if prior is None and _is_consolidated_prior_duration(ctx):
                    prior = val

        if current is not None or prior is not None:
            field_set[tag] = {"current": current, "prior": prior}

    return field_set


def _normalize_duration_nonconsolidated(tag_elements: XbrlTagElements) -> FieldSet:
    """個別財務諸表のみの企業向け: _NonConsolidated コンテキストを当期/前期に正規化する（Duration版）。"""
    exact_current: frozenset[str] = frozenset(DURATION_CONTEXT_PATTERNS)
    exact_prior: frozenset[str] = frozenset(PRIOR_DURATION_CONTEXT_PATTERNS)

    field_set: FieldSet = {}
    for tag, ctx_map in tag_elements.items():
        current: float | None = None
        prior: float | None = None

        for ctx, val in ctx_map.items():
            if _is_nonconsolidated_duration(ctx):
                if _is_pure_nonconsolidated_context(ctx, list(exact_current)):
                    current = val
                elif current is None:
                    current = val
            elif _is_nonconsolidated_prior_duration(ctx):
                if _is_pure_nonconsolidated_context(ctx, list(exact_prior)):
                    prior = val
                elif prior is None:
                    prior = val

        if current is not None or prior is not None:
            field_set[tag] = {"current": current, "prior": prior}

    return field_set


def _normalize_instant(tag_elements: XbrlTagElements) -> FieldSet:
    """XbrlTagElements → FieldSet（Instant コンテキスト用）。

    完全一致コンテキスト（CurrentYearInstant 等）を最優先し、
    前方一致パターン（_is_consolidated_instant 等）をフォールバックにする。
    """
    exact_current: frozenset[str] = frozenset(INSTANT_CONTEXT_PATTERNS)
    exact_prior: frozenset[str] = frozenset(PRIOR_INSTANT_CONTEXT_PATTERNS)

    field_set: FieldSet = {}
    for tag, ctx_map in tag_elements.items():
        current: float | None = None
        prior: float | None = None

        for ctx, val in ctx_map.items():
            if ctx in exact_current:
                current = val
            elif ctx in exact_prior:
                prior = val

        if current is None or prior is None:
            for ctx, val in ctx_map.items():
                if current is None and _is_consolidated_instant(ctx):
                    current = val
                if prior is None and _is_consolidated_prior_instant(ctx):
                    prior = val

        if current is not None or prior is not None:
            field_set[tag] = {"current": current, "prior": prior}

    return field_set


def _normalize_instant_nonconsolidated(tag_elements: XbrlTagElements) -> FieldSet:
    """個別財務諸表のみの企業向け: _NonConsolidated コンテキストを当期/前期に正規化する。"""
    exact_current: frozenset[str] = frozenset(INSTANT_CONTEXT_PATTERNS)
    exact_prior: frozenset[str] = frozenset(PRIOR_INSTANT_CONTEXT_PATTERNS)

    field_set: FieldSet = {}
    for tag, ctx_map in tag_elements.items():
        current: float | None = None
        prior: float | None = None

        for ctx, val in ctx_map.items():
            if _is_nonconsolidated_instant(ctx):
                if _is_pure_nonconsolidated_context(ctx, list(exact_current)):
                    current = val
                elif current is None:
                    current = val
            elif _is_nonconsolidated_prior_instant(ctx):
                if _is_pure_nonconsolidated_context(ctx, list(exact_prior)):
                    prior = val
                elif prior is None:
                    prior = val

        if current is not None or prior is not None:
            field_set[tag] = {"current": current, "prior": prior}

    return field_set


def resolve_item(field_set: FieldSet, candidate_tags: list[str]) -> ResolvedItem:
    """候補タグを優先順に試し、値が見つかった最初のタグの結果を返す。"""
    for tag in candidate_tags:
        if tag in field_set:
            fv = field_set[tag]
            if fv["current"] is not None or fv["prior"] is not None:
                return {"tag": tag, "current": fv["current"], "prior": fv["prior"]}
    return {"tag": None, "current": None, "prior": None}


def resolve_item_prefer_current(field_set: FieldSet, candidate_tags: list[str]) -> ResolvedItem:
    """候補タグを優先順に試す。当期値があるタグを優先し、なければ前期値のみのタグを返す。

    損益計算書の売上高・営業利益など、当期値が主要用途で前期値はYoY補助のケースに使う。
    """
    fallback: ResolvedItem | None = None
    for tag in candidate_tags:
        if tag in field_set:
            fv = field_set[tag]
            if fv["current"] is not None:
                return {"tag": tag, "current": fv["current"], "prior": fv["prior"]}
            if fallback is None and fv["prior"] is not None:
                fallback = {"tag": tag, "current": None, "prior": fv["prior"]}
    return fallback if fallback is not None else {"tag": None, "current": None, "prior": None}


def resolve_aggregate(
    field_set: FieldSet,
    component_tag_lists: list[list[str]],
) -> ResolvedItem:
    """複数コンポーネントを積み上げて合算する。

    component_tag_lists の各要素は「1コンポーネントの候補タグリスト」。
    各コンポーネントは resolve_item で値を1つ選び、全コンポーネントを合算する。
    少なくとも1コンポーネントの値が取れれば集計値を返す。
    """
    current_total: float = 0.0
    prior_total: float = 0.0
    current_found = False
    prior_found = False
    tags_used: list[str] = []

    for candidate_tags in component_tag_lists:
        item = resolve_item(field_set, candidate_tags)
        if item["tag"]:
            tags_used.append(item["tag"])
        if item["current"] is not None:
            current_total += item["current"]
            current_found = True
        if item["prior"] is not None:
            prior_total += item["prior"]
            prior_found = True

    return {
        "tag": "+".join(tags_used) if tags_used else None,
        "current": current_total if current_found else None,
        "prior": prior_total if prior_found else None,
    }


def derive_subtraction(
    field_set: FieldSet,
    minuend_tags: list[str],
    subtrahend_tags: list[str],
) -> ResolvedItem:
    """minuend − subtrahend で値を導出する。直接タグが存在しない項目用。"""
    minuend = resolve_item(field_set, minuend_tags)
    subtrahend = resolve_item(field_set, subtrahend_tags)

    current = (
        minuend["current"] - subtrahend["current"]
        if minuend["current"] is not None and subtrahend["current"] is not None
        else None
    )
    prior = (
        minuend["prior"] - subtrahend["prior"]
        if minuend["prior"] is not None and subtrahend["prior"] is not None
        else None
    )
    derived_tag = (
        f"{minuend['tag']}-{subtrahend['tag']}"
        if minuend["tag"] and subtrahend["tag"]
        else None
    )
    return {"tag": derived_tag, "current": current, "prior": prior}


# US-GAAP 連結財政状態計算書 HTML → FieldSet
# HTML ラベル（部分一致） → 仮想タグ名
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


def parse_usgaap_html_bs_fields(xbrl_dir: Path) -> FieldSet:
    """US-GAAP 連結財政状態計算書 HTML（0105010_*）から FieldSet を生成する。

    XBRL XML に含まれない流動資産・有形固定資産・IBD 等を仮想タグ名で返す。
    返す値の単位は円（parse_html_number の百万円値 × MILLION_YEN）。
    BS4 が未インストールの場合は空の FieldSet を返す。
    """
    if not _BS4_AVAILABLE:
        return {}

    bs_html = _find_html_by_prefix(xbrl_dir, "0105010")
    if bs_html is None:
        return {}

    soup = BeautifulSoup(bs_html.read_text(encoding="utf-8", errors="ignore"), "html.parser")
    return _extract_html_labels(soup, _USGAAP_BS_HTML_LABEL_MAP)


# US-GAAP 連結損益計算書 HTML → FieldSet
# HTML ラベル（部分一致） → 仮想タグ名
# 税引前利益は "税金等調整前当期純利益"（US-GAAP式）と "税引前当期純利益"（J-GAAP式）の両方を登録し、
# 先にヒットした方が採用される（_extract_html_labels は remaining から削除済みラベルをスキップ）。
_USGAAP_PL_HTML_LABEL_MAP: dict[str, str] = {
    "販売費及び一般管理費":     "USGAAP_HTML_SGA",
    "営業利益":                "USGAAP_HTML_OperatingIncome",
    "税金等調整前当期純利益":   "USGAAP_HTML_PreTaxIncome",
    "税引前当期純利益":         "USGAAP_HTML_PreTaxIncome",
    "税金等調整前当期純損失":   "USGAAP_HTML_PreTaxIncome",
    "法人税等":                "USGAAP_HTML_IncomeTax",
}


def parse_usgaap_html_pl_fields(xbrl_dir: Path) -> FieldSet:
    """US-GAAP 連結損益計算書 HTML から FieldSet を生成する。

    0105020（連結損益計算書）を優先し、"営業利益" がなければ 0105010 にフォールバックする
    （会社によって IS と BS が同一ファイルに収録される場合があるため）。
    返す値の単位は円。BS4 が未インストールの場合は空の FieldSet を返す。
    """
    if not _BS4_AVAILABLE:
        return {}

    pl_html: Path | None = None
    for prefix in ("0105020", "0105010"):
        candidate = _find_html_by_prefix(xbrl_dir, prefix)
        if candidate is None:
            continue
        if "営業利益" in candidate.read_text(encoding="utf-8", errors="ignore"):
            pl_html = candidate
            break

    if pl_html is None:
        return {}

    soup = BeautifulSoup(pl_html.read_text(encoding="utf-8", errors="ignore"), "html.parser")
    return _extract_html_labels(soup, _USGAAP_PL_HTML_LABEL_MAP)


def _find_html_by_prefix(xbrl_dir: Path, prefix: str) -> Path | None:
    # xbrl_dir が PublicDoc 相当のディレクトリの場合と、
    # そのルート（S100XXXX_xbrl）が渡される場合の両方に対応する
    candidates = [xbrl_dir, xbrl_dir / "XBRL" / "PublicDoc"]
    for search_dir in candidates:
        if not search_dir.is_dir():
            continue
        for ext in ("*.htm", "*.html"):
            files = [f for f in search_dir.glob(ext) if f.name.startswith(prefix)]
            if files:
                return files[0]
    return None


def _extract_html_labels(soup: "BeautifulSoup", label_map: dict[str, str]) -> FieldSet:
    """soup の全 <tr> を走査し label_map に一致する行の当期/前期値を返す。

    列構造パターン:
      A: [ラベル, (注記,) 前期値, 当期値]           ← 富士フイルム等
      B: [ラベル, (注記,) 前期値, 前期比%, 当期値, 当期比%]  ← キヤノン等（構成比列あり）

    財務金額（百万円単位）は通常 >= 200 であり、構成比（0–100）と区別できる。
    「最後の財務値 = 当期、末尾から2番目の財務値 = 前期」で統一して取得する。
    """
    field_set: FieldSet = {}
    remaining = set(label_map.keys())

    for row in soup.find_all("tr"):
        if not remaining:
            break
        cells = row.find_all(["td", "th"])
        if not cells:
            continue
        texts = [c.get_text(" ", strip=True).replace("\xa0", " ") for c in cells]

        # 第1パス: 先頭セルの完全一致（"負債合計" ⊂ "流動負債合計" などの誤マッチを防ぐ）
        matched: str | None = None
        if texts:
            for label in list(remaining):
                if texts[0] == label:
                    matched = label
                    break
        # 第2パス: セクション番号付きラベル（"１　社債及び短期借入金" 等）向け部分一致
        if matched is None:
            for label in list(remaining):
                if any(label in text for text in texts):
                    matched = label
                    break
        if matched is None:
            continue

        numbers = [parse_html_number(t) for t in texts]
        all_nums = [n for n in numbers if n is not None]
        if not all_nums:
            continue
        # 財務値と構成比が混在する行: 絶対値 >= 200 の数値のみ財務値とみなす
        financial = [n for n in all_nums if abs(n) >= 200]
        found = financial if financial else all_nums
        current = found[-1] * MILLION_YEN
        prior = found[-2] * MILLION_YEN if len(found) >= 2 else None
        field_set[label_map[matched]] = {"current": current, "prior": prior}
        remaining.discard(matched)

    return field_set
