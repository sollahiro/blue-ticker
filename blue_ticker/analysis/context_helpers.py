"""
コンテキスト判定ユーティリティ

XBRL の contextRef 属性から連結/個別・当期/前期を判定する関数群。
Duration（損益計算書・CF）と Instant（貸借対照表）の両方を提供する。
"""

from blue_ticker.constants.xbrl import (
    DURATION_CONTEXT_PATTERNS,
    PRIOR_DURATION_CONTEXT_PATTERNS,
    INSTANT_CONTEXT_PATTERNS,
    PRIOR_INSTANT_CONTEXT_PATTERNS,
)
from blue_ticker.utils.xbrl_result_types import XbrlTagElements


def _is_consolidated_duration(ctx: str) -> bool:
    """連結の当期損益コンテキストかどうか。セグメント軸メンバー（Member末尾）は除外する。"""
    return (
        any(p in ctx for p in DURATION_CONTEXT_PATTERNS)
        and "_NonConsolidated" not in ctx
        and not ctx.endswith("Member")
    )


def _is_consolidated_prior_duration(ctx: str) -> bool:
    """連結の前期損益コンテキストかどうか。セグメント軸メンバー（Member末尾）は除外する。"""
    return (
        any(p in ctx for p in PRIOR_DURATION_CONTEXT_PATTERNS)
        and "_NonConsolidated" not in ctx
        and not ctx.endswith("Member")
    )


def _is_nonconsolidated_duration(ctx: str) -> bool:
    """個別の当期損益コンテキストかどうか。"""
    return any(p in ctx for p in DURATION_CONTEXT_PATTERNS) and "_NonConsolidated" in ctx


def _is_nonconsolidated_prior_duration(ctx: str) -> bool:
    """個別の前期損益コンテキストかどうか。"""
    return any(p in ctx for p in PRIOR_DURATION_CONTEXT_PATTERNS) and "_NonConsolidated" in ctx


def _is_pure_context(ctx: str, patterns: list[str]) -> bool:
    """セグメント修飾のない完全一致コンテキストかどうか。"""
    return any(ctx == p for p in patterns)


def _is_pure_nonconsolidated_context(ctx: str, patterns: list[str]) -> bool:
    """個別財務諸表のセグメント修飾なしコンテキストかどうか。"""
    return any(
        ctx == f"{p}_NonConsolidatedMember" or ctx == f"{p}_NonConsolidated"
        for p in patterns
    )


def _is_consolidated_instant(ctx: str) -> bool:
    """連結の期末残高コンテキストかどうか。セグメント軸メンバー（Member末尾）は除外する。"""
    return (
        any(p in ctx for p in INSTANT_CONTEXT_PATTERNS)
        and "_NonConsolidated" not in ctx
        and not ctx.endswith("Member")
    )


def _is_consolidated_prior_instant(ctx: str) -> bool:
    """連結の前期末残高コンテキストかどうか。セグメント軸メンバー（Member末尾）は除外する。"""
    return (
        any(p in ctx for p in PRIOR_INSTANT_CONTEXT_PATTERNS)
        and "_NonConsolidated" not in ctx
        and not ctx.endswith("Member")
    )


def _is_nonconsolidated_instant(ctx: str) -> bool:
    """個別の期末残高コンテキストかどうか。"""
    return any(p in ctx for p in INSTANT_CONTEXT_PATTERNS) and "_NonConsolidated" in ctx


def _is_nonconsolidated_prior_instant(ctx: str) -> bool:
    """個別の前期末残高コンテキストかどうか。"""
    return any(p in ctx for p in PRIOR_INSTANT_CONTEXT_PATTERNS) and "_NonConsolidated" in ctx


def has_nonconsolidated_contexts(tag_elements: XbrlTagElements) -> bool:
    """連結財務諸表あり（＋個別財務諸表も添付）の書類かどうかを返す。

    True の場合、この書類は連結グループを持つため、単体フォールバックを抑止すべき。
    False の場合、単体のみ企業であり、単体フォールバックを使ってよい。

    判定条件（いずれか一方を満たせば True）:
    1. 同一タグに純粋な連結コンテキストと _NonConsolidated コンテキストの両方がある
       （J-GAAP 連結企業の典型。個別のみ企業は同一タグに連結が付かない）
    2. IFRS/US-GAAP タグが存在し、かつ任意タグに _NonConsolidated がある
       （IFRS 連結タグと J-GAAP 個別タグが別タグで共存するケース、例: トヨタ）

    Duration を連結シグナルとして使う際の注意:
    個別のみ企業でも IS タグに NonConsolidated サフィックスなしの Duration を
    使う慣行があるため、クロスタグ（別タグ）での Duration 連結判定は誤検知を起こす。
    同一タグ条件にすることで個別のみ企業の誤判定を防ぐ。
    """
    _all_pure_consolidated: frozenset[str] = (
        frozenset(DURATION_CONTEXT_PATTERNS) | frozenset(INSTANT_CONTEXT_PATTERNS)
    )
    # 条件1: 同一タグに連結+NonConsolidated
    for ctx_map in tag_elements.values():
        has_cons = any(c in _all_pure_consolidated for c in ctx_map)
        has_nc = any("_NonConsolidated" in c for c in ctx_map)
        if has_cons and has_nc:
            return True
    # 条件2: IFRS/US-GAAP タグが存在し、かつ任意タグに NonConsolidated がある
    has_ifrs_usgaap = any("IFRS" in tag or "USGAAP" in tag for tag in tag_elements)
    if has_ifrs_usgaap:
        return any(
            "_NonConsolidated" in c
            for ctx_map in tag_elements.values()
            for c in ctx_map
        )
    return False
