"""
XBRL フィールドパーサー

Stage 1: XBRL XML → FieldSet（タグ名 → 連結当期/前期値）
Stage 2: FieldSet + 項目定義 → 構造化された財務項目値

XBRLの生XMLパース（collect_numeric_elements）とコンテキスト解釈を分離し、
上位レイヤーが「どのタグを選ぶか」だけに集中できるようにする。
"""

from pathlib import Path
from typing import TypedDict

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
from blue_ticker.analysis.xbrl_utils import collect_numeric_elements, find_xbrl_files
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
