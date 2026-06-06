"""
ROEウォーターフォール分解ユーティリティ。

ROE前年差をデュポン3要因（純利益率・総資産回転率・財務レバレッジ）に分解する。
式: ROE = (純利益/売上高) × (売上高/総資産) × (総資産/純資産) × 100
チェーン型分解（ROIC・事業利益前年差と統一）:
  nm_effect  = (nm_c − nm_p) × at_p  × fl_p    ← すべて前期
  at_effect  = nm_c            × Δat  × fl_p    ← nm_curr 使用
  lev_effect = nm_c × at_c           × Δfl      ← nm_curr, at_curr 使用
合計 = nm_c×at_c×fl_c − nm_p×at_p×fl_p = ΔROE（DuPont ベース）に常に一致。
ROEWaterfallReconciliationDiff は Nikkei ROE と XBRL ベース DuPont ROE の
データソース差分のみを吸収する（通常は 0）。
"""
from typing import Any, cast

from blue_ticker.constants.financial import PERCENT
from blue_ticker.utils.metrics_access import raw_metric_millions
from blue_ticker.utils.metrics_types import YearEntry


_NET_MARGIN_KEY      = "NetMargin"
_ASSET_TURNOVER_KEY  = "AssetTurnover"
_LEVERAGE_KEY        = "FinancialLeverage"
_ROE_DELTA_KEY       = "ROEDelta"
_NM_EFFECT_KEY       = "ROENetMarginEffect"
_AT_EFFECT_KEY       = "ROEAssetTurnoverEffect"
_LEV_EFFECT_KEY      = "ROELeverageEffect"
_RECONCILIATION_KEY  = "ROEWaterfallReconciliationDiff"


def _apply_dupont_components(year: YearEntry) -> None:
    """NetMargin, AssetTurnover, FinancialLeverage を計算して CalculatedData に格納する。

    TotalAssets は XBRL 由来（_apply_balance_sheet が前提）。
    NetAssets も XBRL 由来。両者が揃わない場合は計算しない。
    純資産 ≤ 0（債務超過）の場合はスキップ。
    """
    cd = cast(dict[str, Any], year["CalculatedData"])

    np_m = raw_metric_millions(year["RawData"], "NP")
    sales_m = raw_metric_millions(year["RawData"], "Sales")
    total_assets_m = cd.get("TotalAssets")
    net_assets_m = cd.get("NetAssets")

    if any(v is None for v in [np_m, sales_m, total_assets_m, net_assets_m]):
        return
    if sales_m == 0 or total_assets_m == 0 or net_assets_m <= 0:
        return

    cd[_NET_MARGIN_KEY] = np_m / sales_m * PERCENT
    cd[_ASSET_TURNOVER_KEY] = sales_m / total_assets_m
    cd[_LEVERAGE_KEY] = total_assets_m / net_assets_m


def _apply_roe_change(
    cd: dict[str, Any],
    nm_prev: float,
    at_prev: float,
    fl_prev: float,
    roe_prev: float,
) -> None:
    """ROE前年差を3要因に分解して cd に格納する（既設定の場合はスキップ）。

    nm_prev, at_prev, fl_prev は小数（非パーセント）。
    ROEDelta は表示 ROE（Nikkei ベース）の前年差に一致する。
    """
    if cd.get(_ROE_DELTA_KEY) is not None:
        return

    roe_curr = cd.get("ROE")
    nm_curr_pct = cd.get(_NET_MARGIN_KEY)
    at_curr = cd.get(_ASSET_TURNOVER_KEY)
    fl_curr = cd.get(_LEVERAGE_KEY)

    if any(v is None for v in [roe_curr, nm_curr_pct, at_curr, fl_curr]):
        return

    nm_curr = nm_curr_pct / PERCENT
    roe_delta = roe_curr - roe_prev
    nm_effect  = (nm_curr - nm_prev) * at_prev * fl_prev * PERCENT
    at_effect  = nm_curr * (at_curr - at_prev) * fl_prev * PERCENT
    lev_effect = nm_curr * at_curr * (fl_curr - fl_prev) * PERCENT

    cd[_ROE_DELTA_KEY] = roe_delta
    cd[_NM_EFFECT_KEY] = nm_effect
    cd[_AT_EFFECT_KEY] = at_effect
    cd[_LEV_EFFECT_KEY] = lev_effect
    cd[_RECONCILIATION_KEY] = roe_delta - (nm_effect + at_effect + lev_effect)


def apply_roe_waterfall_to_years(years: list[YearEntry]) -> None:
    """年次データへ ROEウォーターフォール分解を付与する。

    _apply_balance_sheet によって TotalAssets / NetAssets が設定された後に呼ぶこと。
    """
    for year in years:
        _apply_dupont_components(year)

    chronological = sorted(years, key=lambda y: str(y.get("fy_end") or ""))
    for prior_year, current_year in zip(chronological, chronological[1:]):
        prior_cd = cast(dict[str, Any], prior_year["CalculatedData"])
        current_cd = cast(dict[str, Any], current_year["CalculatedData"])

        nm_prev_pct = prior_cd.get(_NET_MARGIN_KEY)
        at_prev = prior_cd.get(_ASSET_TURNOVER_KEY)
        fl_prev = prior_cd.get(_LEVERAGE_KEY)
        roe_prev = prior_cd.get("ROE")

        if any(v is None for v in [nm_prev_pct, at_prev, fl_prev, roe_prev]):
            continue

        _apply_roe_change(current_cd, nm_prev_pct / PERCENT, at_prev, fl_prev, roe_prev)
