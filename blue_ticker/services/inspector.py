"""分析キャッシュの異常値候補スキャナー。

derived 分析キャッシュ（individual_analysis_*）を走査し、決定的な
整合性チェックで「人間の目視レビューに値する異常値候補」を列挙する。
全件を人間が確認するのは不可能なため、smoke テスト的なサンプリング
ではなくルールベースの網羅チェックで候補を絞り込むのが目的。
最終判断は人間（またはレビュー用LLM）が行う前提で、確信度の低い
ものも severity を分けて候補に含める。
"""

import logging
from collections.abc import Mapping, Sequence
from typing import Any

from blue_ticker import __version__
from blue_ticker.constants.financial import (
    INSPECT_IDENTITY_REL_TOL,
    INSPECT_TAX_RATE_MAX_PCT,
    INSPECT_TAX_RATE_MIN_PCT,
    INSPECT_WATERFALL_TOL_MILLION,
    INSPECT_WATERFALL_TOL_PCT,
    INSPECT_YOY_RATIO_MAX,
)
from blue_ticker.utils.cache import CacheManager
from blue_ticker.utils.inspection_types import AnomalyCandidate, InspectionReport
from blue_ticker.utils.metrics_access import metric_view

logger = logging.getLogger(__name__)

_ANALYSIS_KEY_PREFIX = "individual_analysis_"


def _as_float(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def _candidate(
    code: str,
    name: str | None,
    fy_end: str | None,
    check: str,
    severity: str,
    message: str,
    evidence: dict[str, float | int | str | None],
) -> AnomalyCandidate:
    return {
        "code": code,
        "name": name,
        "fy_end": fy_end,
        "check": check,
        "severity": severity,
        "message": message,
        "evidence": evidence,
    }


def _check_missing_core_metrics(
    code: str, name: str | None, fy_end: str | None, view: Mapping[str, Any]
) -> list[AnomalyCandidate]:
    missing = [key for key in ("Sales", "OP", "NP") if _as_float(view.get(key)) is None]
    if not missing:
        return []
    return [_candidate(
        code, name, fy_end, "missing_core_metrics", "warning",
        f"主要指標が欠損しています: {', '.join(missing)}",
        {key: view.get(key) for key in ("Sales", "OP", "NP")},
    )]


def _check_nonpositive_sales(
    code: str, name: str | None, fy_end: str | None, view: Mapping[str, Any]
) -> list[AnomalyCandidate]:
    sales = _as_float(view.get("Sales"))
    if sales is None or sales > 0:
        return []
    return [_candidate(
        code, name, fy_end, "nonpositive_sales", "warning",
        "売上高がゼロ以下です。符号誤りまたは抽出誤りの疑いがあります。",
        {"Sales": sales},
    )]


def _check_gross_profit_exceeds_sales(
    code: str, name: str | None, fy_end: str | None, view: Mapping[str, Any]
) -> list[AnomalyCandidate]:
    sales = _as_float(view.get("Sales"))
    gross_profit = _as_float(view.get("GrossProfit"))
    if sales is None or gross_profit is None or gross_profit <= sales:
        return []
    return [_candidate(
        code, name, fy_end, "gross_profit_exceeds_sales", "warning",
        "売上総利益が売上高を超えています。タグ取り違えの疑いがあります。",
        {"Sales": sales, "GrossProfit": gross_profit},
    )]


def _check_tax_rate_range(
    code: str, name: str | None, fy_end: str | None, view: Mapping[str, Any]
) -> list[AnomalyCandidate]:
    tax_rate = _as_float(view.get("EffectiveTaxRate"))
    if tax_rate is None or INSPECT_TAX_RATE_MIN_PCT <= tax_rate <= INSPECT_TAX_RATE_MAX_PCT:
        return []
    return [_candidate(
        code, name, fy_end, "tax_rate_out_of_range", "info",
        f"実効税率が {INSPECT_TAX_RATE_MIN_PCT:.0f}〜{INSPECT_TAX_RATE_MAX_PCT:.0f}% の範囲外です。"
        "税効果等で正当な場合もあるため目視確認してください。",
        {"EffectiveTaxRate": tax_rate},
    )]


def _identity_violation(total: float, parts_sum: float) -> bool:
    scale = max(abs(total), abs(parts_sum), 1.0)
    return abs(total - parts_sum) / scale > INSPECT_IDENTITY_REL_TOL


def _check_balance_sheet_identity(
    code: str, name: str | None, fy_end: str | None, view: Mapping[str, Any]
) -> list[AnomalyCandidate]:
    candidates: list[AnomalyCandidate] = []
    total_assets = _as_float(view.get("TotalAssets"))

    current_assets = _as_float(view.get("CurrentAssets"))
    non_current_assets = _as_float(view.get("NonCurrentAssets"))
    if total_assets is not None and current_assets is not None and non_current_assets is not None:
        parts = current_assets + non_current_assets
        if _identity_violation(total_assets, parts):
            candidates.append(_candidate(
                code, name, fy_end, "balance_sheet_assets_identity", "warning",
                "総資産が流動資産＋固定資産と一致しません。",
                {
                    "TotalAssets": total_assets,
                    "CurrentAssets": current_assets,
                    "NonCurrentAssets": non_current_assets,
                    "diff": total_assets - parts,
                },
            ))

    current_liabilities = _as_float(view.get("CurrentLiabilities"))
    non_current_liabilities = _as_float(view.get("NonCurrentLiabilities"))
    net_assets = _as_float(view.get("NetAssets"))
    if (
        total_assets is not None
        and current_liabilities is not None
        and non_current_liabilities is not None
        and net_assets is not None
    ):
        parts = current_liabilities + non_current_liabilities + net_assets
        if _identity_violation(total_assets, parts):
            candidates.append(_candidate(
                code, name, fy_end, "balance_sheet_equity_identity", "warning",
                "総資産が負債合計＋純資産と一致しません。",
                {
                    "TotalAssets": total_assets,
                    "CurrentLiabilities": current_liabilities,
                    "NonCurrentLiabilities": non_current_liabilities,
                    "NetAssets": net_assets,
                    "diff": total_assets - parts,
                },
            ))
    return candidates


def _check_free_cf_identity(
    code: str, name: str | None, fy_end: str | None, view: Mapping[str, Any]
) -> list[AnomalyCandidate]:
    cfo = _as_float(view.get("CFO"))
    cfi = _as_float(view.get("CFI"))
    cfc = _as_float(view.get("CFC"))
    if cfo is None or cfi is None or cfc is None:
        return []
    if not _identity_violation(cfc, cfo + cfi):
        return []
    return [_candidate(
        code, name, fy_end, "free_cf_identity", "warning",
        "フリーCFが営業CF＋投資CFと一致しません。",
        {"CFO": cfo, "CFI": cfi, "CFC": cfc, "diff": cfc - (cfo + cfi)},
    )]


def _check_waterfall_reconciliation(
    code: str, name: str | None, fy_end: str | None, view: Mapping[str, Any]
) -> list[AnomalyCandidate]:
    candidates: list[AnomalyCandidate] = []

    for key, label in (
        ("ROICWaterfallReconciliationDiff", "ROICウォーターフォール"),
        ("ROEWaterfallReconciliationDiff", "ROEウォーターフォール"),
    ):
        diff = _as_float(view.get(key))
        if diff is not None and abs(diff) > INSPECT_WATERFALL_TOL_PCT:
            candidates.append(_candidate(
                code, name, fy_end, "waterfall_reconciliation", "warning",
                f"{label}の分解残差が許容値（{INSPECT_WATERFALL_TOL_PCT}%pt）を超えています。",
                {key: diff},
            ))

    bp_diff = _as_float(view.get("BusinessProfitChangeReconciliationDiff"))
    bp_change = _as_float(view.get("BusinessProfitChange"))
    if bp_diff is not None:
        tolerance = max(
            INSPECT_WATERFALL_TOL_MILLION,
            abs(bp_change or 0.0) * INSPECT_IDENTITY_REL_TOL,
        )
        if abs(bp_diff) > tolerance:
            candidates.append(_candidate(
                code, name, fy_end, "waterfall_reconciliation", "warning",
                "事業利益前年差分解の残差が許容値を超えています。",
                {
                    "BusinessProfitChangeReconciliationDiff": bp_diff,
                    "BusinessProfitChange": bp_change,
                },
            ))
    return candidates


_YEAR_CHECKS = (
    _check_missing_core_metrics,
    _check_nonpositive_sales,
    _check_gross_profit_exceeds_sales,
    _check_tax_rate_range,
    _check_balance_sheet_identity,
    _check_free_cf_identity,
    _check_waterfall_reconciliation,
)

# 前年比の急変を監視する指標（正値同士で比較する）
_YOY_KEYS = ("Sales", "TotalAssets")


def _check_yoy_jumps(
    code: str,
    name: str | None,
    chronological: Sequence[tuple[str | None, Mapping[str, Any]]],
) -> list[AnomalyCandidate]:
    candidates: list[AnomalyCandidate] = []
    for (_prev_fy, prev_view), (curr_fy, curr_view) in zip(chronological, chronological[1:]):
        for key in _YOY_KEYS:
            prev = _as_float(prev_view.get(key))
            curr = _as_float(curr_view.get(key))
            if prev is None or curr is None or prev <= 0 or curr <= 0:
                continue
            ratio = curr / prev
            if ratio > INSPECT_YOY_RATIO_MAX or ratio < 1 / INSPECT_YOY_RATIO_MAX:
                candidates.append(_candidate(
                    code, name, curr_fy, "extreme_yoy_jump", "warning",
                    f"{key} の前年比が {ratio:.1f} 倍です。単位誤りまたはデータ混入の疑いがあります。",
                    {f"{key}_prev": prev, f"{key}_curr": curr, "ratio": ratio},
                ))
    return candidates


def inspect_analysis_entry(code: str, cached: Mapping[str, Any]) -> tuple[int, list[AnomalyCandidate]]:
    """1銘柄分の分析キャッシュを検査し、(検査年数, 候補リスト) を返す。"""
    name_value = cached.get("name")
    name = name_value if isinstance(name_value, str) else None
    candidates: list[AnomalyCandidate] = []

    if cached.get("_cache_version") != __version__:
        candidates.append(_candidate(
            code, name, None, "stale_cache_version", "info",
            f"キャッシュバージョンが現行（{__version__}）と一致しません。再分析で解消される可能性があります。",
            {"_cache_version": cached.get("_cache_version")},  # type: ignore[dict-item]
        ))

    metrics = cached.get("metrics")
    years = metrics.get("years") if isinstance(metrics, dict) else None
    if not isinstance(years, list) or not years:
        candidates.append(_candidate(
            code, name, None, "empty_metrics", "warning",
            "分析キャッシュに年次データが含まれていません。",
            {},
        ))
        return 0, candidates

    chronological: list[tuple[str | None, Mapping[str, Any]]] = []
    for year_entry in sorted(years, key=lambda y: str(y.get("fy_end") or "")):
        fy_end = year_entry.get("fy_end")
        view = metric_view(year_entry)
        chronological.append((fy_end, view))
        for check in _YEAR_CHECKS:
            candidates.extend(check(code, name, fy_end, view))

    candidates.extend(_check_yoy_jumps(code, name, chronological))
    return len(years), candidates


def inspect_analysis_cache(
    cache_manager: CacheManager,
    codes: Sequence[str] | None = None,
) -> InspectionReport:
    """分析キャッシュ全体（または指定銘柄）を走査して異常値候補を返す。"""
    if codes:
        keys = [f"{_ANALYSIS_KEY_PREFIX}{code}" for code in codes]
    else:
        keys = [key for key in cache_manager.keys() if key.startswith(_ANALYSIS_KEY_PREFIX)]

    scanned_codes = 0
    scanned_years = 0
    candidates: list[AnomalyCandidate] = []

    for key in keys:
        code = key[len(_ANALYSIS_KEY_PREFIX):]
        cached = cache_manager.get(key)
        if not isinstance(cached, dict):
            if codes:
                candidates.append(_candidate(
                    code, None, None, "cache_not_found", "info",
                    "分析キャッシュが存在しないか期限切れです。先に summarize を実行してください。",
                    {},
                ))
            continue
        scanned_codes += 1
        year_count, entry_candidates = inspect_analysis_entry(code, cached)
        scanned_years += year_count
        candidates.extend(entry_candidates)

    return {
        "scanned_codes": scanned_codes,
        "scanned_years": scanned_years,
        "candidates": candidates,
    }
