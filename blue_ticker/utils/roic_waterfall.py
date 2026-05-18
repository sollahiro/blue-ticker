"""
ROICウォーターフォール分解ユーティリティ。

ROIC前年差を NOPATマージン差影響と投下資本回転率差影響の2要因に分解する。
式: ROIC = (NOPAT/売上高) × (売上高/投下資本) = NOPATマージン × 投下資本回転率
ROIC前年差 = (m_curr - m_prev) * t_prev + m_curr * (t_curr - t_prev)  (×100 で %pt)
Sales が打ち消されるため、和は常に roic_curr - roic_prev に一致する。
"""
from typing import Any, cast

from blue_ticker.constants.financial import MILLION_YEN, NOPAT_FALLBACK_TAX_RATE, PERCENT
from blue_ticker.utils.metrics_access import raw_metric_millions
from blue_ticker.utils.metrics_types import YearEntry


_NOPAT_MARGIN_KEY    = "NOPATMargin"
_IC_TURNOVER_KEY     = "InvestedCapitalTurnover"
_ROIC_DELTA_KEY      = "ROICDelta"
_MARGIN_EFFECT_KEY   = "ROICMarginEffect"
_TURNOVER_EFFECT_KEY = "ROICTurnoverEffect"
_RECONCILIATION_KEY  = "ROICWaterfallReconciliationDiff"
_FINANCIAL_OP_LABELS = frozenset(("経常利益", "事業利益"))


def _is_financial_institution(cd: dict[str, Any]) -> bool:
    return cd.get("OPLabel") in _FINANCIAL_OP_LABELS


def _apply_margin_and_turnover(year: YearEntry) -> None:
    """NOPATMargin と InvestedCapitalTurnover を計算して CalculatedData に格納する。"""
    cd = cast(dict[str, Any], year["CalculatedData"])
    if _is_financial_institution(cd):
        return

    nopat = cd.get("NOPAT")
    net_assets = cd.get("NetAssets")
    ibd = cd.get("InterestBearingDebt")
    sales = raw_metric_millions(year["RawData"], "Sales")

    if nopat is None or net_assets is None or ibd is None or sales is None or sales == 0:
        return
    ic = net_assets + ibd
    if ic == 0:
        return

    cd[_NOPAT_MARGIN_KEY] = nopat / sales * PERCENT
    cd[_IC_TURNOVER_KEY] = sales / ic


def _apply_change(cd: dict[str, Any], m_prev: float, t_prev: float, roic_prev: float) -> None:
    """ROIC前年差を2要因に分解して cd に格納する（既設定の場合はスキップ）。"""
    if cd.get(_ROIC_DELTA_KEY) is not None:
        return

    roic_curr = cd.get("ROIC")
    m_curr_pct = cd.get(_NOPAT_MARGIN_KEY)
    t_curr = cd.get(_IC_TURNOVER_KEY)

    if roic_curr is None or m_curr_pct is None or t_curr is None:
        return

    m_curr = m_curr_pct / PERCENT
    roic_delta = roic_curr - roic_prev
    margin_effect = (m_curr - m_prev) * t_prev * PERCENT
    turnover_effect = m_curr * (t_curr - t_prev) * PERCENT

    cd[_ROIC_DELTA_KEY] = roic_delta
    cd[_MARGIN_EFFECT_KEY] = margin_effect
    cd[_TURNOVER_EFFECT_KEY] = turnover_effect
    cd[_RECONCILIATION_KEY] = roic_delta - (margin_effect + turnover_effect)


def apply_roic_waterfall_from_xbrl(
    years: list[YearEntry],
    gp_by_year: dict[str, dict[str, Any]],
    op_by_year: dict[str, dict[str, Any]],
    ibd_by_year: dict[str, dict[str, Any]],
    bs_by_year: dict[str, dict[str, Any]],
) -> None:
    """XBRL埋め込みの前期数値を使って全年度にROICウォーターフォール分解を付与する。

    各年度の有報に含まれる前期数値（Prior1Year コンテキスト）を使うため、
    外部の前年リストへ依存せずに最古年度の前年差も計算できる。
    gp_by_year / op_by_year / ibd_by_year / bs_by_year は YYYYMMDD キーの XBRL 抽出結果 dict。
    """
    for year in years:
        cd = cast(dict[str, Any], year["CalculatedData"])
        if _is_financial_institution(cd):
            continue

        _apply_margin_and_turnover(year)

        fy_end = year.get("fy_end") or ""
        fy_end_key = fy_end.replace("-", "")

        gp = gp_by_year.get(fy_end_key, {})
        op = op_by_year.get(fy_end_key, {})
        ibd_result = ibd_by_year.get(fy_end_key, {})
        bs_result = bs_by_year.get(fy_end_key, {})

        prior_op_raw = op.get("prior")
        prior_sales_raw = gp.get("prior_sales")
        if prior_sales_raw is None:
            prior_sales_raw = op.get("prior_sales")
        prior_ibd_raw = ibd_result.get("prior")
        prior_net_assets_raw = bs_result.get("prior_net_assets")

        if any(v is None for v in [prior_op_raw, prior_sales_raw, prior_ibd_raw, prior_net_assets_raw]):
            continue

        prior_sales = prior_sales_raw / MILLION_YEN  # type: ignore[operator]
        prior_op = prior_op_raw / MILLION_YEN  # type: ignore[operator]
        prior_ibd = prior_ibd_raw / MILLION_YEN  # type: ignore[operator]
        prior_net_assets = prior_net_assets_raw / MILLION_YEN  # type: ignore[operator]

        if prior_sales == 0:
            continue
        prior_ic = prior_net_assets + prior_ibd
        if prior_ic == 0:
            continue

        prior_nopat = prior_op * (1 - NOPAT_FALLBACK_TAX_RATE)
        m_prev = prior_nopat / prior_sales
        t_prev = prior_sales / prior_ic
        roic_prev = prior_nopat / prior_ic * PERCENT

        _apply_change(cd, m_prev, t_prev, roic_prev)


def apply_roic_waterfall_to_years(years: list[YearEntry]) -> None:
    """年次データへ ROICウォーターフォール分解を付与する。

    連続する年次ペアを走査する。既に ROICDelta が設定済みの年はスキップする
    （apply_roic_waterfall_from_xbrl との二重計算防止）。
    """
    for year in years:
        _apply_margin_and_turnover(year)

    chronological = sorted(years, key=lambda y: str(y.get("fy_end") or ""))
    for prior_year, current_year in zip(chronological, chronological[1:]):
        prior_cd = cast(dict[str, Any], prior_year["CalculatedData"])
        current_cd = cast(dict[str, Any], current_year["CalculatedData"])

        if _is_financial_institution(current_cd):
            continue

        m_prev_pct = prior_cd.get(_NOPAT_MARGIN_KEY)
        t_prev = prior_cd.get(_IC_TURNOVER_KEY)
        roic_prev = prior_cd.get("ROIC")

        if m_prev_pct is None or t_prev is None or roic_prev is None:
            continue

        _apply_change(current_cd, m_prev_pct / PERCENT, t_prev, roic_prev)


def _apply_margin_and_turnover_period(data: dict[str, Any]) -> None:
    """半期期間データの NOPATMargin と InvestedCapitalTurnover を計算する。"""
    if _is_financial_institution(data):
        return

    nopat = data.get("NOPAT")
    sales = data.get("Sales")
    ic = data.get("InvestedCapital")

    if nopat is None or sales is None or ic is None or sales == 0 or ic == 0:
        return

    data[_NOPAT_MARGIN_KEY] = nopat / sales * PERCENT
    data[_IC_TURNOVER_KEY] = sales / ic


def _apply_change_period(current: dict[str, Any], prior: dict[str, Any]) -> None:
    """半期期間データの ROIC前年差を2要因に分解して current に格納する。"""
    if current.get(_ROIC_DELTA_KEY) is not None:
        return

    roic_curr = current.get("ROIC")
    roic_prev = prior.get("ROIC")
    m_curr_pct = current.get(_NOPAT_MARGIN_KEY)
    m_prev_pct = prior.get(_NOPAT_MARGIN_KEY)
    t_curr = current.get(_IC_TURNOVER_KEY)
    t_prev = prior.get(_IC_TURNOVER_KEY)

    if any(v is None for v in [roic_curr, roic_prev, m_curr_pct, m_prev_pct, t_curr, t_prev]):
        return

    m_curr = m_curr_pct / PERCENT  # type: ignore[operator]
    m_prev = m_prev_pct / PERCENT  # type: ignore[operator]
    roic_delta = roic_curr - roic_prev  # type: ignore[operator]
    margin_effect = (m_curr - m_prev) * t_prev * PERCENT  # type: ignore[operator]
    turnover_effect = m_curr * (t_curr - t_prev) * PERCENT  # type: ignore[operator]

    current[_ROIC_DELTA_KEY] = roic_delta
    current[_MARGIN_EFFECT_KEY] = margin_effect
    current[_TURNOVER_EFFECT_KEY] = turnover_effect
    current[_RECONCILIATION_KEY] = roic_delta - (margin_effect + turnover_effect)


def apply_roic_waterfall_to_periods(periods: list[dict[str, Any]]) -> None:
    """H1/H2 期間データへ前年同期間比の ROICウォーターフォール分解を付与する。"""
    latest_by_half: dict[str, dict[str, Any]] = {}

    for period in sorted(periods, key=lambda p: str(p.get("fy_end") or "")):
        data = period.get("data") or {}
        _apply_margin_and_turnover_period(data)

        half = period.get("half")
        comparison_key = half if isinstance(half, str) else "FY"
        prior = latest_by_half.get(comparison_key)
        if prior is not None:
            _apply_change_period(data, prior.get("data") or {})
        latest_by_half[comparison_key] = period
