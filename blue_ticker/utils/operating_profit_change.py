"""
営業利益前年差の要因分解ユーティリティ。

売上高、売上総利益、営業利益から販管費を導出し、営業利益の前年差を
売上差・粗利率差・販管費増の3要素へ分解する。
"""

from collections.abc import Mapping
from typing import Any, cast

from blue_ticker.constants.financial import MILLION_YEN, PERCENT
from blue_ticker.utils.metrics_access import metric_view
from blue_ticker.utils.metrics_types import YearEntry


_SGA_KEY = "SellingGeneralAdministrativeExpenses"
_ADJUSTED_OP_KEY = "BusinessProfit"
_ADJUSTED_OP_MARGIN_KEY = "BusinessProfitMargin"
_OP_CHANGE_KEY = "OperatingProfitChange"
_SALES_IMPACT_KEY = "SalesChangeImpact"
_GM_IMPACT_KEY = "GrossMarginChangeImpact"
_SGA_IMPACT_KEY = "SGAChangeImpact"
_RECONCILIATION_DIFF_KEY = "OperatingProfitChangeReconciliationDiff"
_FINANCIAL_OP_LABELS = frozenset(("経常利益", "事業利益"))
_FINANCIAL_SALES_LABELS = frozenset(("経常収益",))
_BUSINESS_GROSS_PROFIT_LABEL = "業務粗利益"
_DERIVED_KEYS = (
    _SGA_KEY,
    _ADJUSTED_OP_KEY,
    _ADJUSTED_OP_MARGIN_KEY,
    _OP_CHANGE_KEY,
    _SALES_IMPACT_KEY,
    _GM_IMPACT_KEY,
    _SGA_IMPACT_KEY,
    _RECONCILIATION_DIFF_KEY,
    "MetricSources",
)


def _gross_margin(gross_profit: float | None, sales: float | None) -> float | None:
    if gross_profit is None or sales is None or sales == 0:
        return None
    return gross_profit / sales


def _set_source(
    data: dict[str, Any],
    metric: str,
    *,
    method: str,
    unit: str = "million_yen",
) -> None:
    sources = data.setdefault("MetricSources", {})
    sources[metric] = {"source": "derived", "method": method, "unit": unit}


def _profit_base(data: dict[str, Any]) -> tuple[float | None, str | None]:
    gross_profit = data.get("GrossProfit")
    if gross_profit is not None:
        label = data.get("GrossProfitLabel")
        return gross_profit, _BUSINESS_GROSS_PROFIT_LABEL if label == _BUSINESS_GROSS_PROFIT_LABEL else "GrossProfit"

    op_label = data.get("OPLabel")
    sales_label = data.get("SalesLabel")
    sales = data.get("Sales")
    if (
        op_label in _FINANCIAL_OP_LABELS
        and sales_label in _FINANCIAL_SALES_LABELS
        and sales is not None
    ):
        return sales, "Sales"

    return None, None


def _profit_base_from_xbrl(
    gp: Mapping[str, Any],
    op: Mapping[str, Any],
    *,
    period: str,
) -> tuple[float | None, str | None]:
    gp_raw = gp.get(period)
    if gp_raw is not None:
        label = _BUSINESS_GROSS_PROFIT_LABEL if gp.get("method") == "business_gross_profit" else "GrossProfit"
        return gp_raw, f"{label}(XBRL)"

    op_label = op.get("label")
    sales_key = f"{period}_sales"
    sales_raw = op.get(sales_key)
    if op_label in _FINANCIAL_OP_LABELS and sales_raw is not None:
        return sales_raw, "Sales(XBRL)"

    return None, None


def _margin_source_label(data: dict[str, Any]) -> str:
    if data.get("GrossProfitLabel") == _BUSINESS_GROSS_PROFIT_LABEL:
        return "BusinessGrossProfitMargin"
    return "GrossProfitMargin"


def _margin_source_label_from_xbrl(gp: dict[str, Any]) -> str:
    if gp.get("method") == "business_gross_profit":
        return "BusinessGrossProfitMargin"
    return "GrossProfitMargin"


def _apply_sga(data: dict[str, Any]) -> None:
    if data.get(_SGA_KEY) is not None:
        return

    profit_base, base_label = _profit_base(data)
    op = data.get("OP")
    if profit_base is None or op is None or base_label is None:
        return

    data[_SGA_KEY] = profit_base - op
    _set_source(data, _SGA_KEY, method=f"{base_label} - OP")


def _apply_business_profit(data: dict[str, Any]) -> None:
    if data.get(_ADJUSTED_OP_KEY) is not None:
        return

    profit_base, base_label = _profit_base(data)
    sga = data.get(_SGA_KEY)
    if profit_base is None or sga is None or base_label is None:
        return

    data[_ADJUSTED_OP_KEY] = profit_base - sga
    _set_source(data, _ADJUSTED_OP_KEY, method=f"{base_label} - SGA")

    sales = data.get("Sales")
    if sales is not None and sales != 0 and data.get(_ADJUSTED_OP_MARGIN_KEY) is None:
        data[_ADJUSTED_OP_MARGIN_KEY] = data[_ADJUSTED_OP_KEY] / sales * PERCENT
        _set_source(data, _ADJUSTED_OP_MARGIN_KEY, method="BusinessProfit / Sales", unit="percent")


def _apply_change(current: dict[str, Any], prior: dict[str, Any]) -> None:
    if current.get(_OP_CHANGE_KEY) is not None:
        return

    current_sales = current.get("Sales")
    current_profit_base, _ = _profit_base(current)
    current_op = current.get(_ADJUSTED_OP_KEY)
    current_sga = current.get(_SGA_KEY)
    prior_sales = prior.get("Sales")
    prior_profit_base, _ = _profit_base(prior)
    prior_op = prior.get(_ADJUSTED_OP_KEY)
    prior_sga = prior.get(_SGA_KEY)

    current_margin = _gross_margin(current_profit_base, current_sales)
    prior_margin = _gross_margin(prior_profit_base, prior_sales)
    margin_label = _margin_source_label(current)

    if (
        current_sales is None
        or current_op is None
        or current_sga is None
        or current_margin is None
        or prior_sales is None
        or prior_op is None
        or prior_sga is None
        or prior_margin is None
    ):
        return

    op_change = current_op - prior_op
    sales_impact = (current_sales - prior_sales) * prior_margin
    gross_margin_impact = current_sales * (current_margin - prior_margin)
    sga_impact = -(current_sga - prior_sga)
    total_impact = sales_impact + gross_margin_impact + sga_impact

    current[_OP_CHANGE_KEY] = op_change
    current[_SALES_IMPACT_KEY] = sales_impact
    current[_GM_IMPACT_KEY] = gross_margin_impact
    current[_SGA_IMPACT_KEY] = sga_impact
    current[_RECONCILIATION_DIFF_KEY] = op_change - total_impact

    _set_source(current, _OP_CHANGE_KEY, method="current BusinessProfit - prior BusinessProfit")
    _set_source(
        current,
        _SALES_IMPACT_KEY,
        method=f"(current Sales - prior Sales) * prior {margin_label}",
    )
    _set_source(
        current,
        _GM_IMPACT_KEY,
        method=f"current Sales * (current {margin_label} - prior {margin_label})",
    )
    _set_source(current, _SGA_IMPACT_KEY, method="-(current SGA - prior SGA)")
    _set_source(
        current,
        _RECONCILIATION_DIFF_KEY,
        method="OperatingProfitChange - (SalesChangeImpact + GrossMarginChangeImpact + SGAChangeImpact)",
    )


def apply_operating_profit_change_to_years(years: list[YearEntry]) -> None:
    """年次データへ営業利益前年差分解を付与する。"""
    views_by_fy_end: dict[str, dict[str, Any]] = {}
    for year in years:
        view = metric_view(year)
        _apply_sga(view)
        _apply_business_profit(view)
        views_by_fy_end[str(year.get("fy_end") or "")] = view

    chronological = sorted(
        years,
        key=lambda year: str(year.get("fy_end") or ""),
    )
    for prior, current in zip(chronological, chronological[1:]):
        _apply_change(
            views_by_fy_end[str(current.get("fy_end") or "")],
            views_by_fy_end[str(prior.get("fy_end") or "")],
        )
    for year in years:
        view = views_by_fy_end[str(year.get("fy_end") or "")]
        calculated = cast(dict[str, Any], year["CalculatedData"])
        # MetricSources は通常 shallow copy 経由で同一オブジェクトだが、
        # 元の CalculatedData に未作成だったケースも含めて書き戻す。
        for key in _DERIVED_KEYS:
            if key in view:
                calculated[key] = view[key]


def apply_operating_profit_change_to_periods(periods: list[dict[str, Any]]) -> None:
    """H1/H2/FY 期間データへ前年同期間比の営業利益前年差分解を付与する。"""
    latest_by_half: dict[str, dict[str, Any]] = {}

    for period in sorted(periods, key=lambda item: str(item.get("fy_end") or "")):
        data = period.get("data") or {}
        _apply_sga(data)
        _apply_business_profit(data)

        half = period.get("half")
        comparison_key = half if isinstance(half, str) else "FY"
        prior = latest_by_half.get(comparison_key)
        if prior is not None:
            _apply_change(data, prior.get("data") or {})
        latest_by_half[comparison_key] = period


def _xbrl_sales(gp: Mapping[str, Any], op: Mapping[str, Any], *, period: str) -> float | None:
    sales = gp.get(f"{period}_sales")
    if sales is None:
        sales = op.get(f"{period}_sales")
    return sales if isinstance(sales, (int, float)) and not isinstance(sales, bool) else None


def _xbrl_op(op: Mapping[str, Any], *, period: str) -> float | None:
    value = op.get(period)
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _xbrl_sga(op: Mapping[str, Any], *, period: str) -> float | None:
    value = op.get(f"{period}_sga")
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _synthetic_prior_period_from_xbrl(gp: Mapping[str, Any], op: Mapping[str, Any]) -> dict[str, Any] | None:
    prior_sales_raw = _xbrl_sales(gp, op, period="prior")
    prior_base_raw, _ = _profit_base_from_xbrl(gp, op, period="prior")
    prior_op_raw = _xbrl_op(op, period="prior")
    if prior_sales_raw is None or prior_base_raw is None or prior_op_raw is None:
        return None

    prior: dict[str, Any] = {
        "Sales": prior_sales_raw / MILLION_YEN,
        "GrossProfit": prior_base_raw / MILLION_YEN,
        "OP": prior_op_raw / MILLION_YEN,
    }
    if op.get("label") in _FINANCIAL_OP_LABELS:
        prior["OPLabel"] = op.get("label")
        if gp.get("prior") is None:
            prior.pop("GrossProfit", None)
    if gp.get("method") == "business_gross_profit":
        prior["GrossProfitLabel"] = _BUSINESS_GROSS_PROFIT_LABEL
    prior_sga_raw = _xbrl_sga(op, period="prior")
    if prior_sga_raw is not None:
        prior[_SGA_KEY] = prior_sga_raw / MILLION_YEN
        _set_source(prior, _SGA_KEY, method="SGA(XBRL)")
    _apply_sga(prior)
    _apply_business_profit(prior)
    return prior


def _sub_raw(current: float | None, subtract: float | None) -> float | None:
    if current is None or subtract is None:
        return None
    return current - subtract


def _synthetic_prior_h2_from_xbrl(
    fy_gp: Mapping[str, Any],
    fy_op: Mapping[str, Any],
    h1_gp: Mapping[str, Any],
    h1_op: Mapping[str, Any],
) -> dict[str, Any] | None:
    prior_sales_raw = _sub_raw(
        _xbrl_sales(fy_gp, fy_op, period="prior"),
        _xbrl_sales(h1_gp, h1_op, period="prior"),
    )
    fy_base_raw, _ = _profit_base_from_xbrl(fy_gp, fy_op, period="prior")
    h1_base_raw, _ = _profit_base_from_xbrl(h1_gp, h1_op, period="prior")
    prior_base_raw = _sub_raw(fy_base_raw, h1_base_raw)
    prior_op_raw = _sub_raw(
        _xbrl_op(fy_op, period="prior"),
        _xbrl_op(h1_op, period="prior"),
    )
    if prior_sales_raw is None or prior_base_raw is None or prior_op_raw is None:
        return None

    prior: dict[str, Any] = {
        "Sales": prior_sales_raw / MILLION_YEN,
        "GrossProfit": prior_base_raw / MILLION_YEN,
        "OP": prior_op_raw / MILLION_YEN,
    }
    if fy_op.get("label") in _FINANCIAL_OP_LABELS:
        prior["OPLabel"] = fy_op.get("label")
        if fy_gp.get("prior") is None:
            prior.pop("GrossProfit", None)
    if fy_gp.get("method") == "business_gross_profit":
        prior["GrossProfitLabel"] = _BUSINESS_GROSS_PROFIT_LABEL
    fy_sga_raw = _xbrl_sga(fy_op, period="prior")
    h1_sga_raw = _xbrl_sga(h1_op, period="prior")
    prior_sga_raw = _sub_raw(fy_sga_raw, h1_sga_raw)
    if prior_sga_raw is not None:
        prior[_SGA_KEY] = prior_sga_raw / MILLION_YEN
        _set_source(prior, _SGA_KEY, method="FY SGA(XBRL) - H1 SGA(XBRL)")
    _apply_sga(prior)
    _apply_business_profit(prior)
    return prior


def apply_operating_profit_change_to_periods_from_xbrl(
    periods: list[dict[str, Any]],
    half_gp_by_year: Mapping[str, Mapping[str, Any]],
    half_op_by_year: Mapping[str, Mapping[str, Any]],
    fy_gp_by_year: Mapping[str, Mapping[str, Any]],
    fy_op_by_year: Mapping[str, Mapping[str, Any]],
) -> None:
    """XBRLの前期値から、各半期を表示範囲外の前年なしで前年差分解する。"""
    for period in periods:
        fy_end = str(period.get("fy_end") or "").replace("-", "")
        data = period.get("data") or {}
        _apply_sga(data)
        _apply_business_profit(data)

        half = period.get("half")
        prior: dict[str, Any] | None
        if half == "H1":
            prior = _synthetic_prior_period_from_xbrl(
                half_gp_by_year.get(fy_end, {}),
                half_op_by_year.get(fy_end, {}),
            )
        elif half == "H2":
            prior = _synthetic_prior_h2_from_xbrl(
                fy_gp_by_year.get(fy_end, {}),
                fy_op_by_year.get(fy_end, {}),
                half_gp_by_year.get(fy_end, {}),
                half_op_by_year.get(fy_end, {}),
            )
        else:
            prior = _synthetic_prior_period_from_xbrl(
                fy_gp_by_year.get(fy_end, {}),
                fy_op_by_year.get(fy_end, {}),
            )

        if prior is not None:
            _apply_change(data, prior)


def apply_operating_profit_change_from_xbrl(
    years: list[YearEntry],
    gp_by_year: dict[str, dict[str, Any]],
    op_by_year: dict[str, dict[str, Any]],
) -> None:
    """有報XBRLの前期比較値を使って営業利益前年差分解を付与する。

    各年度の有報に含まれる前期数値（Prior1YearDuration コンテキスト）を使うため、
    外部の前年リストへ依存せずに全年度の前年差を計算できる。
    gp_by_year / op_by_year は YYYYMMDD キーの XBRL 抽出結果 dict。
    """
    for year in years:
        fy_end = year.get("fy_end") or ""
        fy_end_key = fy_end.replace("-", "")

        gp = gp_by_year.get(fy_end_key, {})
        op = op_by_year.get(fy_end_key, {})

        current_op_raw = op.get("current")
        current_sales_raw = gp.get("current_sales")
        if current_sales_raw is None:
            current_sales_raw = op.get("current_sales")

        prior_op_raw = op.get("prior")
        prior_sales_raw = gp.get("prior_sales")
        if prior_sales_raw is None:
            prior_sales_raw = op.get("prior_sales")

        current_base_raw, current_base_label = _profit_base_from_xbrl(gp, op, period="current")
        prior_base_raw, _ = _profit_base_from_xbrl(gp, op, period="prior")
        current_sga_raw = _xbrl_sga(op, period="current")
        prior_sga_raw = _xbrl_sga(op, period="prior")

        cd = cast(dict[str, Any], year["CalculatedData"])

        if current_base_raw is not None and current_op_raw is not None and current_base_label is not None:
            current_base_m = current_base_raw / MILLION_YEN
            current_op_m = current_op_raw / MILLION_YEN
            if cd.get(_SGA_KEY) is None:
                if current_sga_raw is not None:
                    cd[_SGA_KEY] = current_sga_raw / MILLION_YEN
                    _set_source(cd, _SGA_KEY, method="SGA(XBRL)")
                else:
                    cd[_SGA_KEY] = current_base_m - current_op_m
                    _set_source(cd, _SGA_KEY, method=f"{current_base_label} - OP(XBRL)")
        else:
            current_base_m = current_op_m = None

        _apply_business_profit(cd)

        if (
            current_base_m is None
            or current_op_m is None
            or current_sales_raw is None
            or prior_base_raw is None
            or prior_op_raw is None
            or prior_sales_raw is None
        ):
            continue

        current_sales = current_sales_raw / MILLION_YEN
        prior_base = prior_base_raw / MILLION_YEN
        prior_op = prior_op_raw / MILLION_YEN
        prior_sales = prior_sales_raw / MILLION_YEN

        if prior_sales == 0 or current_sales == 0:
            continue

        current_sga = current_sga_raw / MILLION_YEN if current_sga_raw is not None else current_base_m - current_op_m
        prior_sga = prior_sga_raw / MILLION_YEN if prior_sga_raw is not None else prior_base - prior_op
        current_adjusted_op = current_base_m - current_sga
        prior_adjusted_op = prior_base - prior_sga
        current_margin = current_base_m / current_sales
        prior_margin = prior_base / prior_sales
        margin_label = _margin_source_label_from_xbrl(gp)

        op_change = current_adjusted_op - prior_adjusted_op
        sales_impact = (current_sales - prior_sales) * prior_margin
        gm_impact = current_sales * (current_margin - prior_margin)
        sga_impact = -(current_sga - prior_sga)
        total_impact = sales_impact + gm_impact + sga_impact

        cd[_ADJUSTED_OP_KEY] = current_adjusted_op
        cd[_ADJUSTED_OP_MARGIN_KEY] = current_adjusted_op / current_sales * PERCENT
        cd[_OP_CHANGE_KEY] = op_change
        cd[_SALES_IMPACT_KEY] = sales_impact
        cd[_GM_IMPACT_KEY] = gm_impact
        cd[_SGA_IMPACT_KEY] = sga_impact
        cd[_RECONCILIATION_DIFF_KEY] = op_change - total_impact

        _set_source(cd, _ADJUSTED_OP_KEY, method=f"{current_base_label} - SGA(XBRL)")
        _set_source(cd, _ADJUSTED_OP_MARGIN_KEY, method="BusinessProfit / Sales", unit="percent")
        _set_source(cd, _OP_CHANGE_KEY, method="current BusinessProfit - prior BusinessProfit (XBRL)")
        _set_source(
            cd,
            _SALES_IMPACT_KEY,
            method=f"(current Sales - prior Sales) * prior {margin_label} (XBRL)",
        )
        _set_source(
            cd,
            _GM_IMPACT_KEY,
            method=f"current Sales * (current {margin_label} - prior {margin_label}) (XBRL)",
        )
        _set_source(cd, _SGA_IMPACT_KEY, method="-(current SGA - prior SGA) (XBRL)")
        _set_source(
            cd,
            _RECONCILIATION_DIFF_KEY,
            method="OperatingProfitChange - (SalesChangeImpact + GrossMarginChangeImpact + SGAChangeImpact) (XBRL)",
        )
