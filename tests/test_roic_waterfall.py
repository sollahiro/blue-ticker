from typing import Any, cast

import pytest

from blue_ticker.constants.financial import MILLION_YEN, NOPAT_FALLBACK_TAX_RATE, PERCENT
from blue_ticker.utils.metrics_types import YearEntry
from blue_ticker.utils.roic_waterfall import (
    apply_roic_waterfall_from_xbrl,
    apply_roic_waterfall_to_periods,
    apply_roic_waterfall_to_years,
)


def _year(
    fy_end: str,
    sales_m: float,
    nopat_m: float | None,
    net_assets_m: float | None,
    ibd_m: float | None,
    roic: float | None = None,
    op_label: str = "営業利益",
) -> YearEntry:
    cd: dict[str, Any] = {}
    if nopat_m is not None:
        cd["NOPAT"] = nopat_m
    if net_assets_m is not None:
        cd["NetAssets"] = net_assets_m
    if ibd_m is not None:
        cd["InterestBearingDebt"] = ibd_m
    if roic is not None:
        cd["ROIC"] = roic
    if op_label != "営業利益":
        cd["OPLabel"] = op_label
    return cast(YearEntry, {
        "fy_end": fy_end,
        "FinancialPeriod": fy_end,
        "RawData": {"Sales": int(sales_m * MILLION_YEN)},
        "CalculatedData": cd,
    })


def _cd(year: YearEntry) -> dict[str, Any]:
    return cast(dict[str, Any], year["CalculatedData"])


def _period(half: str, fy_end: str, sales_m: float, nopat_m: float | None, ic_m: float | None, roic: float | None = None) -> dict:
    data: dict[str, Any] = {"Sales": sales_m}
    if nopat_m is not None:
        data["NOPAT"] = nopat_m
    if ic_m is not None:
        data["InvestedCapital"] = ic_m
    if roic is not None:
        data["ROIC"] = roic
    return {"half": half, "fy_end": fy_end, "data": data}


class TestApplyRoicWaterfallToYears:
    def test_decomposes_roic_change(self) -> None:
        prior = _year("2023-03-31", sales_m=1_000.0, nopat_m=80.0, net_assets_m=400.0, ibd_m=200.0)
        current = _year("2024-03-31", sales_m=1_200.0, nopat_m=108.0, net_assets_m=450.0, ibd_m=200.0)
        cd_prior = _cd(prior)
        cd_curr = _cd(current)
        cd_prior["ROIC"] = 80.0 / 600.0 * PERCENT
        cd_curr["ROIC"] = 108.0 / 650.0 * PERCENT

        apply_roic_waterfall_to_years([prior, current])

        roic_delta = cd_curr["ROICDelta"]
        margin_effect = cd_curr["ROICMarginEffect"]
        turnover_effect = cd_curr["ROICTurnoverEffect"]

        assert roic_delta == pytest.approx(cd_curr["ROIC"] - cd_prior["ROIC"])
        assert margin_effect + turnover_effect == pytest.approx(roic_delta, abs=1e-9)
        assert cd_curr["ROICWaterfallReconciliationDiff"] == pytest.approx(0.0, abs=1e-9)

    def test_nopat_margin_and_ic_turnover_computed(self) -> None:
        year = _year("2024-03-31", sales_m=1_200.0, nopat_m=108.0, net_assets_m=450.0, ibd_m=200.0)
        _cd(year)["ROIC"] = 108.0 / 650.0 * PERCENT

        apply_roic_waterfall_to_years([year])

        cd = _cd(year)
        assert cd["NOPATMargin"] == pytest.approx(108.0 / 1_200.0 * PERCENT)
        assert cd["InvestedCapitalTurnover"] == pytest.approx(1_200.0 / 650.0)

    def test_margin_times_turnover_equals_roic(self) -> None:
        year = _year("2024-03-31", sales_m=1_000.0, nopat_m=60.0, net_assets_m=300.0, ibd_m=100.0)
        _cd(year)["ROIC"] = 60.0 / 400.0 * PERCENT

        apply_roic_waterfall_to_years([year])

        cd = _cd(year)
        derived = cd["NOPATMargin"] / PERCENT * cd["InvestedCapitalTurnover"] * PERCENT
        assert derived == pytest.approx(cd["ROIC"], abs=1e-9)

    def test_skips_when_nopat_is_none(self) -> None:
        prior = _year("2023-03-31", sales_m=1_000.0, nopat_m=None, net_assets_m=400.0, ibd_m=200.0)
        current = _year("2024-03-31", sales_m=1_200.0, nopat_m=None, net_assets_m=450.0, ibd_m=200.0)
        _cd(prior)["ROIC"] = 10.0
        _cd(current)["ROIC"] = 12.0

        apply_roic_waterfall_to_years([prior, current])

        assert "ROICDelta" not in _cd(current)
        assert "NOPATMargin" not in _cd(current)

    def test_skips_when_sales_is_zero(self) -> None:
        prior = _year("2023-03-31", sales_m=0.0, nopat_m=50.0, net_assets_m=400.0, ibd_m=200.0)
        current = _year("2024-03-31", sales_m=0.0, nopat_m=60.0, net_assets_m=450.0, ibd_m=200.0)
        _cd(prior)["ROIC"] = 8.33
        _cd(current)["ROIC"] = 9.23

        apply_roic_waterfall_to_years([prior, current])

        assert "NOPATMargin" not in _cd(current)
        assert "ROICDelta" not in _cd(current)

    def test_skips_financial_institution(self) -> None:
        prior = _year("2023-03-31", sales_m=1_000.0, nopat_m=80.0, net_assets_m=500.0, ibd_m=2_000.0, op_label="経常利益")
        current = _year("2024-03-31", sales_m=1_100.0, nopat_m=90.0, net_assets_m=550.0, ibd_m=2_100.0, op_label="経常利益")
        _cd(prior)["ROIC"] = 3.2
        _cd(current)["ROIC"] = 3.5

        apply_roic_waterfall_to_years([prior, current])

        assert "ROICDelta" not in _cd(current)
        assert "NOPATMargin" not in _cd(current)

    def test_does_not_overwrite_existing_roic_delta(self) -> None:
        prior = _year("2023-03-31", sales_m=1_000.0, nopat_m=80.0, net_assets_m=400.0, ibd_m=200.0)
        current = _year("2024-03-31", sales_m=1_200.0, nopat_m=108.0, net_assets_m=450.0, ibd_m=200.0)
        _cd(prior)["ROIC"] = 80.0 / 600.0 * PERCENT
        _cd(current)["ROIC"] = 108.0 / 650.0 * PERCENT
        _cd(current)["ROICDelta"] = 99.9  # pre-set by XBRL version

        apply_roic_waterfall_to_years([prior, current])

        assert _cd(current)["ROICDelta"] == pytest.approx(99.9)

    def test_first_year_has_no_delta(self) -> None:
        year = _year("2024-03-31", sales_m=1_200.0, nopat_m=108.0, net_assets_m=450.0, ibd_m=200.0)
        _cd(year)["ROIC"] = 108.0 / 650.0 * PERCENT

        apply_roic_waterfall_to_years([year])

        assert "ROICDelta" not in _cd(year)
        assert "NOPATMargin" in _cd(year)


class TestApplyRoicWaterfallFromXbrl:
    def _make_xbrl_dicts(
        self,
        fy_end_key: str,
        prior_sales_yen: float,
        prior_op_yen: float,
        prior_ibd_yen: float,
        prior_net_assets_yen: float,
    ) -> tuple[dict, dict, dict, dict]:
        gp_by_year = {fy_end_key: {"prior_sales": prior_sales_yen}}
        op_by_year = {fy_end_key: {"prior": prior_op_yen}}
        ibd_by_year = {fy_end_key: {"prior": prior_ibd_yen}}
        bs_by_year = {fy_end_key: {"prior_net_assets": prior_net_assets_yen}}
        return gp_by_year, op_by_year, ibd_by_year, bs_by_year

    def test_populates_roic_delta_from_xbrl_prior(self) -> None:
        fy = "2024-03-31"
        fy_key = "20240331"
        prior_sales = 1_000_000_000.0  # 1,000億円
        prior_op = 100_000_000.0
        prior_ibd = 200_000_000.0
        prior_net_assets = 400_000_000.0

        year = _year(fy, sales_m=1_200.0, nopat_m=108.0, net_assets_m=450.0, ibd_m=200.0)
        prior_nopat = prior_op / MILLION_YEN * (1 - NOPAT_FALLBACK_TAX_RATE)
        prior_ic = (prior_net_assets + prior_ibd) / MILLION_YEN
        expected_roic_prev = prior_nopat / prior_ic * PERCENT
        _cd(year)["ROIC"] = 108.0 / 650.0 * PERCENT

        gp, op, ibd, bs = self._make_xbrl_dicts(fy_key, prior_sales, prior_op, prior_ibd, prior_net_assets)
        apply_roic_waterfall_from_xbrl([year], gp, op, ibd, bs)

        cd = _cd(year)
        assert "ROICDelta" in cd
        assert cd["ROICDelta"] == pytest.approx(cd["ROIC"] - expected_roic_prev, abs=1e-9)
        assert cd["ROICMarginEffect"] + cd["ROICTurnoverEffect"] == pytest.approx(cd["ROICDelta"], abs=1e-9)

    def test_skips_when_prior_net_assets_missing(self) -> None:
        fy = "2024-03-31"
        fy_key = "20240331"
        year = _year(fy, sales_m=1_200.0, nopat_m=108.0, net_assets_m=450.0, ibd_m=200.0)
        _cd(year)["ROIC"] = 16.6

        gp_by_year = {fy_key: {"prior_sales": 1_000_000_000.0}}
        op_by_year = {fy_key: {"prior": 100_000_000.0}}
        ibd_by_year = {fy_key: {"prior": 200_000_000.0}}
        bs_by_year: dict = {fy_key: {}}  # no prior_net_assets

        apply_roic_waterfall_from_xbrl([year], gp_by_year, op_by_year, ibd_by_year, bs_by_year)

        assert "ROICDelta" not in _cd(year)

    def test_skips_financial_institution(self) -> None:
        fy = "2024-03-31"
        fy_key = "20240331"
        year = _year(fy, sales_m=1_000.0, nopat_m=50.0, net_assets_m=500.0, ibd_m=2_000.0, op_label="経常利益")
        _cd(year)["ROIC"] = 2.0

        gp, op, ibd, bs = self._make_xbrl_dicts(
            fy_key, 1_000_000_000.0, 80_000_000.0, 2_000_000_000.0, 500_000_000.0,
        )
        apply_roic_waterfall_from_xbrl([year], gp, op, ibd, bs)

        assert "ROICDelta" not in _cd(year)


class TestApplyRoicWaterfallToPeriods:
    def test_same_half_comparison(self) -> None:
        h1_prev = _period("H1", "2023-03-31", sales_m=500.0, nopat_m=40.0, ic_m=600.0, roic=40.0/600.0*PERCENT)
        h1_curr = _period("H1", "2024-03-31", sales_m=600.0, nopat_m=54.0, ic_m=650.0, roic=54.0/650.0*PERCENT)
        h2_prev = _period("H2", "2023-03-31", sales_m=500.0, nopat_m=40.0, ic_m=600.0, roic=40.0/600.0*PERCENT)

        apply_roic_waterfall_to_periods([h1_prev, h1_curr, h2_prev])

        data_h1_curr = h1_curr["data"]
        data_h2_prev = h2_prev["data"]

        assert "ROICDelta" in data_h1_curr
        assert data_h1_curr["ROICMarginEffect"] + data_h1_curr["ROICTurnoverEffect"] == pytest.approx(
            data_h1_curr["ROICDelta"], abs=1e-9
        )
        assert "ROICDelta" not in data_h2_prev

    def test_skips_when_invested_capital_missing(self) -> None:
        h1_prev = _period("H1", "2023-03-31", sales_m=500.0, nopat_m=40.0, ic_m=None, roic=None)
        h1_curr = _period("H1", "2024-03-31", sales_m=600.0, nopat_m=54.0, ic_m=None, roic=None)

        apply_roic_waterfall_to_periods([h1_prev, h1_curr])

        assert "ROICDelta" not in h1_curr["data"]
        assert "NOPATMargin" not in h1_curr["data"]
