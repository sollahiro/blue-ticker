from typing import Any, cast

import pytest

from blue_ticker.constants.financial import MILLION_YEN, PERCENT
from blue_ticker.utils.metrics_types import YearEntry
from blue_ticker.utils.roe_waterfall import apply_roe_waterfall_to_years


def _year(
    fy_end: str,
    np_m: float | None,
    sales_m: float | None,
    total_assets_m: float | None,
    net_assets_m: float | None,
    roe: float | None = None,
) -> YearEntry:
    cd: dict[str, Any] = {}
    if total_assets_m is not None:
        cd["TotalAssets"] = total_assets_m
    if net_assets_m is not None:
        cd["NetAssets"] = net_assets_m
    if roe is not None:
        cd["ROE"] = roe

    raw: dict[str, Any] = {}
    if np_m is not None:
        raw["NP"] = int(np_m * MILLION_YEN)
    if sales_m is not None:
        raw["Sales"] = int(sales_m * MILLION_YEN)

    return cast(YearEntry, {
        "fy_end": fy_end,
        "FinancialPeriod": fy_end,
        "RawData": raw,
        "CalculatedData": cd,
    })


def _cd(year: YearEntry) -> dict[str, Any]:
    return cast(dict[str, Any], year["CalculatedData"])


class TestApplyDupontComponents:
    def test_computes_three_factors(self) -> None:
        year = _year("2024-03-31", np_m=60.0, sales_m=1_000.0, total_assets_m=800.0, net_assets_m=400.0)
        apply_roe_waterfall_to_years([year])

        cd = _cd(year)
        assert cd["NetMargin"] == pytest.approx(60.0 / 1_000.0 * PERCENT)
        assert cd["AssetTurnover"] == pytest.approx(1_000.0 / 800.0)
        assert cd["FinancialLeverage"] == pytest.approx(800.0 / 400.0)

    def test_dupont_identity_holds(self) -> None:
        np_m, sales_m, ta_m, na_m = 60.0, 1_000.0, 800.0, 400.0
        year = _year("2024-03-31", np_m=np_m, sales_m=sales_m, total_assets_m=ta_m, net_assets_m=na_m)
        apply_roe_waterfall_to_years([year])

        cd = _cd(year)
        derived = cd["NetMargin"] / PERCENT * cd["AssetTurnover"] * cd["FinancialLeverage"] * PERCENT
        expected = np_m / na_m * PERCENT
        assert derived == pytest.approx(expected, abs=1e-9)

    def test_skips_when_total_assets_none(self) -> None:
        year = _year("2024-03-31", np_m=60.0, sales_m=1_000.0, total_assets_m=None, net_assets_m=400.0)
        apply_roe_waterfall_to_years([year])

        assert "NetMargin" not in _cd(year)
        assert "AssetTurnover" not in _cd(year)

    def test_skips_when_sales_zero(self) -> None:
        year = _year("2024-03-31", np_m=60.0, sales_m=0.0, total_assets_m=800.0, net_assets_m=400.0)
        apply_roe_waterfall_to_years([year])

        assert "NetMargin" not in _cd(year)

    def test_skips_when_net_assets_nonpositive(self) -> None:
        year = _year("2024-03-31", np_m=60.0, sales_m=1_000.0, total_assets_m=800.0, net_assets_m=-10.0)
        apply_roe_waterfall_to_years([year])

        assert "NetMargin" not in _cd(year)
        assert "FinancialLeverage" not in _cd(year)

    def test_allows_negative_net_margin(self) -> None:
        year = _year("2024-03-31", np_m=-30.0, sales_m=1_000.0, total_assets_m=800.0, net_assets_m=400.0)
        apply_roe_waterfall_to_years([year])

        cd = _cd(year)
        assert cd["NetMargin"] == pytest.approx(-30.0 / 1_000.0 * PERCENT)


class TestApplyRoeWaterfallToYears:
    def test_decomposes_roe_change(self) -> None:
        roe_prev = 60.0 / 400.0 * PERCENT
        roe_curr = 84.0 / 420.0 * PERCENT
        prior = _year("2023-03-31", np_m=60.0, sales_m=1_000.0, total_assets_m=800.0, net_assets_m=400.0, roe=roe_prev)
        current = _year("2024-03-31", np_m=84.0, sales_m=1_200.0, total_assets_m=900.0, net_assets_m=420.0, roe=roe_curr)

        apply_roe_waterfall_to_years([prior, current])

        cd = _cd(current)
        assert "ROEDelta" in cd
        assert cd["ROEDelta"] == pytest.approx(roe_curr - roe_prev)

    def test_three_effects_sum_to_delta(self) -> None:
        """チェーン型では3要因の合計が ROEDelta に一致し reconciliation_diff = 0。"""
        roe_prev = 60.0 / 400.0 * PERCENT
        roe_curr = 84.0 / 420.0 * PERCENT
        prior = _year("2023-03-31", np_m=60.0, sales_m=1_000.0, total_assets_m=800.0, net_assets_m=400.0, roe=roe_prev)
        current = _year("2024-03-31", np_m=84.0, sales_m=1_200.0, total_assets_m=900.0, net_assets_m=420.0, roe=roe_curr)

        apply_roe_waterfall_to_years([prior, current])

        cd = _cd(current)
        total3 = cd["ROENetMarginEffect"] + cd["ROEAssetTurnoverEffect"] + cd["ROELeverageEffect"]
        assert total3 == pytest.approx(cd["ROEDelta"], abs=1e-9)
        assert cd["ROEWaterfallReconciliationDiff"] == pytest.approx(0.0, abs=1e-9)

    def test_reconciliation_diff_is_zero_when_data_sources_match(self) -> None:
        """チェーン型では全要因が同時変化しても reconciliation_diff = 0。"""
        na = 400.0
        roe_prev = 60.0 / na * PERCENT
        roe_curr = 72.0 / na * PERCENT  # 純利益のみ変化
        prior = _year("2023-03-31", np_m=60.0, sales_m=1_000.0, total_assets_m=800.0, net_assets_m=na, roe=roe_prev)
        current = _year("2024-03-31", np_m=72.0, sales_m=1_000.0, total_assets_m=800.0, net_assets_m=na, roe=roe_curr)

        apply_roe_waterfall_to_years([prior, current])

        cd = _cd(current)
        assert cd["ROEAssetTurnoverEffect"] == pytest.approx(0.0, abs=1e-9)
        assert cd["ROELeverageEffect"] == pytest.approx(0.0, abs=1e-9)
        assert cd["ROEWaterfallReconciliationDiff"] == pytest.approx(0.0, abs=1e-9)
        nm_prev = 60.0 / 1_000.0
        at_prev = 1_000.0 / 800.0
        fl_prev = 800.0 / na
        expected_nm_effect = (72.0/1_000.0 - nm_prev) * at_prev * fl_prev * PERCENT
        assert cd["ROENetMarginEffect"] == pytest.approx(expected_nm_effect, abs=1e-9)

    def test_skips_first_year(self) -> None:
        year = _year("2024-03-31", np_m=60.0, sales_m=1_000.0, total_assets_m=800.0, net_assets_m=400.0, roe=15.0)
        apply_roe_waterfall_to_years([year])

        assert "ROEDelta" not in _cd(year)
        assert "NetMargin" in _cd(year)

    def test_skips_when_prior_dupont_incomplete(self) -> None:
        prior = _year("2023-03-31", np_m=60.0, sales_m=1_000.0, total_assets_m=None, net_assets_m=400.0, roe=15.0)
        current = _year("2024-03-31", np_m=84.0, sales_m=1_200.0, total_assets_m=900.0, net_assets_m=420.0, roe=20.0)

        apply_roe_waterfall_to_years([prior, current])

        assert "ROEDelta" not in _cd(current)

    def test_skips_when_prior_roe_none(self) -> None:
        prior = _year("2023-03-31", np_m=60.0, sales_m=1_000.0, total_assets_m=800.0, net_assets_m=400.0, roe=None)
        current = _year("2024-03-31", np_m=84.0, sales_m=1_200.0, total_assets_m=900.0, net_assets_m=420.0, roe=20.0)

        apply_roe_waterfall_to_years([prior, current])

        assert "ROEDelta" not in _cd(current)

    def test_does_not_overwrite_existing_roe_delta(self) -> None:
        prior = _year("2023-03-31", np_m=60.0, sales_m=1_000.0, total_assets_m=800.0, net_assets_m=400.0, roe=15.0)
        current = _year("2024-03-31", np_m=84.0, sales_m=1_200.0, total_assets_m=900.0, net_assets_m=420.0, roe=20.0)
        _cd(current)["ROEDelta"] = 99.9

        apply_roe_waterfall_to_years([prior, current])

        assert _cd(current)["ROEDelta"] == pytest.approx(99.9)

    def test_three_years_produces_two_deltas(self) -> None:
        y1 = _year("2022-03-31", np_m=50.0, sales_m=900.0, total_assets_m=700.0, net_assets_m=350.0, roe=50.0/350.0*PERCENT)
        y2 = _year("2023-03-31", np_m=60.0, sales_m=1_000.0, total_assets_m=800.0, net_assets_m=400.0, roe=60.0/400.0*PERCENT)
        y3 = _year("2024-03-31", np_m=72.0, sales_m=1_100.0, total_assets_m=880.0, net_assets_m=440.0, roe=72.0/440.0*PERCENT)

        apply_roe_waterfall_to_years([y1, y2, y3])

        assert "ROEDelta" not in _cd(y1)
        assert "ROEDelta" in _cd(y2)
        assert "ROEDelta" in _cd(y3)
