from typing import Any, cast

import pytest

from blue_ticker.constants.financial import PERCENT
from blue_ticker.utils.operating_profit_change import (
    apply_operating_profit_change_from_xbrl,
    apply_operating_profit_change_to_periods,
    apply_operating_profit_change_to_periods_from_xbrl,
    apply_operating_profit_change_to_years,
)
from blue_ticker.utils.metrics_types import YearEntry


def _year(fy_end: str, sales: float, gross_profit: float | None, op: float) -> YearEntry:
    return cast(YearEntry, {
        "fy_end": fy_end,
        "FinancialPeriod": fy_end,
        "RawData": {},
        "CalculatedData": {
            "Sales": sales,
            "GrossProfit": gross_profit,
            "OP": op,
        },
    })


def _blank_year(fy_end: str) -> YearEntry:
    return cast(YearEntry, {
        "fy_end": fy_end,
        "FinancialPeriod": fy_end,
        "RawData": {},
        "CalculatedData": {},
    })


def _cd(year: YearEntry) -> dict[str, Any]:
    return cast(dict[str, Any], year["CalculatedData"])


def _period(label: str, half: str, fy_end: str, sales: float, gross_profit: float, op: float) -> dict:
    return {
        "label": label,
        "half": half,
        "fy_end": fy_end,
        "data": {
            "Sales": sales,
            "GrossProfit": gross_profit,
            "OP": op,
        },
    }


def test_apply_operating_profit_change_to_years_decomposes_op_change() -> None:
    years = [
        _year("2024-03-31", 1_200.0, 480.0, 150.0),
        _year("2023-03-31", 1_000.0, 350.0, 100.0),
    ]

    apply_operating_profit_change_to_years(years)

    current = _cd(years[0])
    assert current["SellingGeneralAdministrativeExpenses"] == pytest.approx(330.0)
    assert current["OperatingProfitChange"] == pytest.approx(50.0)
    assert current["SalesChangeImpact"] == pytest.approx(70.0)
    assert current["GrossMarginChangeImpact"] == pytest.approx(60.0)
    assert current["SGAChangeImpact"] == pytest.approx(-80.0)
    assert current["OperatingProfitChangeReconciliationDiff"] == pytest.approx(0.0)
    assert current["MetricSources"]["SalesChangeImpact"]["source"] == "derived"


def test_apply_operating_profit_change_to_years_preserves_direct_sga() -> None:
    years = [
        _year("2024-03-31", 1_200.0, 480.0, 150.0),
        _year("2023-03-31", 1_000.0, 350.0, 100.0),
    ]
    _cd(years[0])["SellingGeneralAdministrativeExpenses"] = 320.0
    _cd(years[0])["MetricSources"] = {
        "SellingGeneralAdministrativeExpenses": {
            "source": "edinet",
            "method": "direct",
            "unit": "million_yen",
        }
    }

    apply_operating_profit_change_to_years(years)

    current = _cd(years[0])
    assert current["SellingGeneralAdministrativeExpenses"] == pytest.approx(320.0)
    assert current["MetricSources"]["SellingGeneralAdministrativeExpenses"]["source"] == "edinet"
    assert current["SGAChangeImpact"] == pytest.approx(-70.0)


def test_apply_operating_profit_change_to_years_uses_adjusted_operating_profit() -> None:
    years = [
        _year("2025-03-31", 284_900.0, 154_364.0, 62_971.0),
        _year("2024-03-31", 238_883.0, 140_531.0, 64_381.0),
    ]
    _cd(years[0])["SellingGeneralAdministrativeExpenses"] = 92_946.0
    _cd(years[1])["SellingGeneralAdministrativeExpenses"] = 75_003.0

    apply_operating_profit_change_to_years(years)

    current = _cd(years[0])
    assert current["BusinessProfit"] == pytest.approx(61_418.0)
    assert current["OperatingProfitChange"] == pytest.approx(-4_110.0)
    assert current["SalesChangeImpact"] == pytest.approx(27_071.05581812017)
    assert current["GrossMarginChangeImpact"] == pytest.approx(-13_238.055818120169)
    assert current["SGAChangeImpact"] == pytest.approx(-17_943.0)
    assert current["OperatingProfitChangeReconciliationDiff"] == pytest.approx(0.0, abs=1e-6)


def test_apply_operating_profit_change_to_years_preserves_xbrl_change() -> None:
    years = [
        _year("2024-03-31", 1_200.0, 480.0, 150.0),
        _year("2023-03-31", 1_000.0, 350.0, 100.0),
    ]
    _cd(years[0])["OperatingProfitChange"] = 55.0

    apply_operating_profit_change_to_years(years)

    assert _cd(years[0])["OperatingProfitChange"] == pytest.approx(55.0)


def test_apply_operating_profit_change_to_years_uses_financial_revenue_as_profit_base() -> None:
    years = [
        _year("2024-03-31", 1_200.0, None, 150.0),
        _year("2023-03-31", 1_000.0, None, 100.0),
    ]
    _cd(years[0])["OPLabel"] = "経常利益"
    _cd(years[1])["OPLabel"] = "経常利益"
    _cd(years[0])["SalesLabel"] = "経常収益"
    _cd(years[1])["SalesLabel"] = "経常収益"

    apply_operating_profit_change_to_years(years)

    current = _cd(years[0])
    assert current["SellingGeneralAdministrativeExpenses"] == pytest.approx(1_050.0)
    assert current["OperatingProfitChange"] == pytest.approx(50.0)
    assert current["SalesChangeImpact"] == pytest.approx(200.0)
    assert current["GrossMarginChangeImpact"] == pytest.approx(0.0)
    assert current["SGAChangeImpact"] == pytest.approx(-150.0)
    assert current["OperatingProfitChangeReconciliationDiff"] == pytest.approx(0.0)


def test_apply_operating_profit_change_to_years_skips_ordinary_income_for_non_financial_sales() -> None:
    years = [
        _year("2024-03-31", 1_200.0, None, 150.0),
        _year("2023-03-31", 1_000.0, None, 100.0),
    ]
    _cd(years[0])["OPLabel"] = "経常利益"
    _cd(years[1])["OPLabel"] = "経常利益"
    _cd(years[0])["SalesLabel"] = "売上高"
    _cd(years[1])["SalesLabel"] = "売上高"

    apply_operating_profit_change_to_years(years)

    current = _cd(years[0])
    assert "SellingGeneralAdministrativeExpenses" not in current
    assert "OperatingProfitChange" not in current
    assert "SalesChangeImpact" not in current
    assert "GrossMarginChangeImpact" not in current
    assert "SGAChangeImpact" not in current


def test_apply_operating_profit_change_to_years_uses_business_gross_profit_margin() -> None:
    years = [
        _year("2024-03-31", 1_200.0, 600.0, 150.0),
        _year("2023-03-31", 1_000.0, 350.0, 100.0),
    ]
    _cd(years[0])["GrossProfitLabel"] = "業務粗利益"
    _cd(years[1])["GrossProfitLabel"] = "業務粗利益"

    apply_operating_profit_change_to_years(years)

    current = _cd(years[0])
    assert current["SellingGeneralAdministrativeExpenses"] == pytest.approx(450.0)
    assert current["OperatingProfitChange"] == pytest.approx(50.0)
    assert current["SalesChangeImpact"] == pytest.approx(70.0)
    assert current["GrossMarginChangeImpact"] == pytest.approx(180.0)
    assert current["SGAChangeImpact"] == pytest.approx(-200.0)
    assert current["OperatingProfitChangeReconciliationDiff"] == pytest.approx(0.0)
    assert current["MetricSources"]["SellingGeneralAdministrativeExpenses"]["method"] == "業務粗利益 - OP"
    assert (
        current["MetricSources"]["GrossMarginChangeImpact"]["method"]
        == "current Sales * (current BusinessGrossProfitMargin - prior BusinessGrossProfitMargin)"
    )


def test_apply_operating_profit_change_to_years_skips_change_without_prior() -> None:
    years = [_year("2024-03-31", 1_200.0, 480.0, 150.0)]

    apply_operating_profit_change_to_years(years)

    current = _cd(years[0])
    assert current["SellingGeneralAdministrativeExpenses"] == pytest.approx(330.0)
    assert "OperatingProfitChange" not in current


def test_apply_operating_profit_change_to_periods_compares_same_half() -> None:
    periods = [
        _period("23H1", "H1", "2023-03-31", 400.0, 140.0, 40.0),
        _period("23H2", "H2", "2023-03-31", 600.0, 210.0, 60.0),
        _period("24H1", "H1", "2024-03-31", 500.0, 200.0, 70.0),
        _period("24H2", "H2", "2024-03-31", 700.0, 280.0, 80.0),
    ]

    apply_operating_profit_change_to_periods(periods)

    h1 = periods[2]["data"]
    h2 = periods[3]["data"]
    assert h1["OperatingProfitChange"] == pytest.approx(30.0)
    assert h1["SalesChangeImpact"] == pytest.approx(35.0)
    assert h1["GrossMarginChangeImpact"] == pytest.approx(25.0)
    assert h1["SGAChangeImpact"] == pytest.approx(-30.0)
    assert h1["OperatingProfitChangeReconciliationDiff"] == pytest.approx(0.0)
    assert h2["OperatingProfitChange"] == pytest.approx(20.0)
    assert h2["SalesChangeImpact"] == pytest.approx(35.0)


def test_apply_operating_profit_change_to_periods_from_xbrl_completes_single_year() -> None:
    periods = [
        _period("24H1", "H1", "2024-03-31", 500.0, 200.0, 70.0),
        _period("24H2", "H2", "2024-03-31", 700.0, 280.0, 80.0),
    ]
    half_gp_by_year = {
        "20240331": {
            "current": 200.0 * _M,
            "prior": 140.0 * _M,
            "current_sales": 500.0 * _M,
            "prior_sales": 400.0 * _M,
            "method": "computed",
        }
    }
    half_op_by_year = {
        "20240331": {
            "current": 70.0 * _M,
            "prior": 40.0 * _M,
            "label": "営業利益",
        }
    }
    fy_gp_by_year = {
        "20240331": {
            "current": 480.0 * _M,
            "prior": 350.0 * _M,
            "current_sales": 1_200.0 * _M,
            "prior_sales": 1_000.0 * _M,
            "method": "computed",
        }
    }
    fy_op_by_year = {
        "20240331": {
            "current": 150.0 * _M,
            "prior": 100.0 * _M,
            "label": "営業利益",
        }
    }

    apply_operating_profit_change_to_periods_from_xbrl(
        periods,
        half_gp_by_year,
        half_op_by_year,
        fy_gp_by_year,
        fy_op_by_year,
    )

    h1 = periods[0]["data"]
    h2 = periods[1]["data"]
    assert h1["OperatingProfitChange"] == pytest.approx(30.0)
    assert h1["SalesChangeImpact"] == pytest.approx(35.0)
    assert h1["GrossMarginChangeImpact"] == pytest.approx(25.0)
    assert h1["SGAChangeImpact"] == pytest.approx(-30.0)
    assert h2["OperatingProfitChange"] == pytest.approx(20.0)
    assert h2["SalesChangeImpact"] == pytest.approx(35.0)
    assert h2["GrossMarginChangeImpact"] == pytest.approx(35.0)
    assert h2["SGAChangeImpact"] == pytest.approx(-50.0)


_M = 1_000_000  # MILLION_YEN


def _gp_entry(
    current: float,
    prior: float,
    current_sales: float,
    prior_sales: float,
) -> dict:
    return {
        "current": current * _M,
        "prior": prior * _M,
        "method": "computed",
        "accounting_standard": "J-GAAP",
        "components": [],
        "current_sales": current_sales * _M,
        "prior_sales": prior_sales * _M,
    }


def _op_entry(current: float, prior: float) -> dict:
    return {"current": current * _M, "prior": prior * _M, "method": "direct", "label": "営業利益", "accounting_standard": "J-GAAP"}


def _financial_op_entry(
    current: float,
    prior: float,
    current_sales: float,
    prior_sales: float,
) -> dict:
    return {
        "current": current * _M,
        "prior": prior * _M,
        "method": "ordinary_income",
        "label": "経常利益",
        "accounting_standard": "J-GAAP",
        "current_sales": current_sales * _M,
        "prior_sales": prior_sales * _M,
    }


def test_apply_operating_profit_change_from_xbrl_uses_filing_prior_values() -> None:
    """有報の前期値（XBRL）から全年度の前年差を計算できる。"""
    years = [_blank_year("2022-03-31"), _blank_year("2023-03-31")]
    # 2022年度の有報に「当期(2022)」と「前期(2021)」の数値が入っている
    gp_by_year = {
        "20220331": _gp_entry(current=480.0, prior=350.0, current_sales=1_200.0, prior_sales=1_000.0),
        "20230331": _gp_entry(current=600.0, prior=480.0, current_sales=1_500.0, prior_sales=1_200.0),
    }
    op_by_year = {
        "20220331": _op_entry(current=150.0, prior=100.0),
        "20230331": _op_entry(current=200.0, prior=150.0),
    }

    apply_operating_profit_change_from_xbrl(years, gp_by_year, op_by_year)

    cd_2022 = _cd(years[0])
    assert cd_2022["OperatingProfitChange"] == pytest.approx(50.0)
    assert cd_2022["SalesChangeImpact"] == pytest.approx(70.0)
    assert cd_2022["GrossMarginChangeImpact"] == pytest.approx(60.0)
    assert cd_2022["SGAChangeImpact"] == pytest.approx(-80.0)
    assert cd_2022["OperatingProfitChangeReconciliationDiff"] == pytest.approx(0.0)

    cd_2023 = _cd(years[1])
    assert cd_2023["OperatingProfitChange"] == pytest.approx(50.0)


def test_apply_operating_profit_change_from_xbrl_uses_direct_sga_values() -> None:
    years = [_blank_year("2022-03-31")]
    gp_by_year = {
        "20220331": _gp_entry(current=480.0, prior=350.0, current_sales=1_200.0, prior_sales=1_000.0),
    }
    op_by_year = {
        "20220331": {
            **_op_entry(current=150.0, prior=100.0),
            "current_sga": 320.0 * _M,
            "prior_sga": 240.0 * _M,
        },
    }

    apply_operating_profit_change_from_xbrl(years, gp_by_year, op_by_year)

    cd = _cd(years[0])
    assert cd["SellingGeneralAdministrativeExpenses"] == pytest.approx(320.0)
    assert cd["MetricSources"]["SellingGeneralAdministrativeExpenses"]["method"] == "SGA(XBRL)"
    assert cd["SGAChangeImpact"] == pytest.approx(-80.0)


def test_apply_operating_profit_change_from_xbrl_uses_adjusted_operating_profit() -> None:
    years = [_blank_year("2025-03-31")]
    gp_by_year = {
        "20250331": _gp_entry(
            current=154_364.0,
            prior=140_531.0,
            current_sales=284_900.0,
            prior_sales=238_883.0,
        )
    }
    op_by_year = {
        "20250331": {
            **_op_entry(current=62_971.0, prior=64_381.0),
            "current_sga": 92_946.0 * _M,
            "prior_sga": 75_003.0 * _M,
        },
    }

    apply_operating_profit_change_from_xbrl(years, gp_by_year, op_by_year)

    cd = _cd(years[0])
    assert cd["BusinessProfit"] == pytest.approx(61_418.0)
    assert cd["BusinessProfitMargin"] == pytest.approx(61_418.0 / 284_900.0 * PERCENT)
    assert cd["OperatingProfitChange"] == pytest.approx(-4_110.0)
    assert cd["SalesChangeImpact"] == pytest.approx(27_071.05581812017)
    assert cd["GrossMarginChangeImpact"] == pytest.approx(-13_238.055818120169)
    assert cd["SGAChangeImpact"] == pytest.approx(-17_943.0)
    assert cd["OperatingProfitChangeReconciliationDiff"] == pytest.approx(0.0, abs=1e-6)


def test_apply_operating_profit_change_from_xbrl_uses_financial_filing_prior_values() -> None:
    """金融機関は単年有報の経常収益・経常利益の当期/前期値で前年差分解できる。"""
    years = [_blank_year("2023-03-31")]
    op_by_year = {
        "20230331": _financial_op_entry(
            current=789_606.0,
            prior=559_847.0,
            current_sales=5_778_772.0,
            prior_sales=3_963_091.0,
        )
    }

    apply_operating_profit_change_from_xbrl(years, {}, op_by_year)

    cd = _cd(years[0])
    assert cd["SellingGeneralAdministrativeExpenses"] == pytest.approx(4_989_166.0)
    assert cd["OperatingProfitChange"] == pytest.approx(229_759.0)
    assert cd["SalesChangeImpact"] == pytest.approx(1_815_681.0)
    assert cd["GrossMarginChangeImpact"] == pytest.approx(0.0)
    assert cd["SGAChangeImpact"] == pytest.approx(-1_585_922.0)
    assert cd["OperatingProfitChangeReconciliationDiff"] == pytest.approx(0.0, abs=1e-6)


def test_apply_operating_profit_change_from_xbrl_uses_business_gross_profit_margin() -> None:
    """金融機関はXBRLの業務粗利益で粗利率差影響を計算する。"""
    years = [_blank_year("2025-03-31")]
    gp_by_year = {
        "20250331": {
            **_gp_entry(current=691_665.0, prior=627_469.0, current_sales=1_117_491.0, prior_sales=941_663.0),
            "method": "business_gross_profit",
        }
    }
    op_by_year = {
        "20250331": _financial_op_entry(
            current=292_160.0,
            prior=222_962.0,
            current_sales=1_117_491.0,
            prior_sales=941_663.0,
        )
    }

    apply_operating_profit_change_from_xbrl(years, gp_by_year, op_by_year)

    cd = _cd(years[0])
    assert cd["SellingGeneralAdministrativeExpenses"] == pytest.approx(399_505.0)
    assert cd["OperatingProfitChange"] == pytest.approx(69_198.0)
    assert cd["SalesChangeImpact"] == pytest.approx(117_161.46788394575)
    assert cd["GrossMarginChangeImpact"] == pytest.approx(-52_965.46788394579)
    assert cd["SGAChangeImpact"] == pytest.approx(5_002.0)
    assert cd["OperatingProfitChangeReconciliationDiff"] == pytest.approx(0.0, abs=1e-6)
    assert cd["MetricSources"]["SellingGeneralAdministrativeExpenses"]["method"] == "業務粗利益(XBRL) - OP(XBRL)"
    assert (
        cd["MetricSources"]["GrossMarginChangeImpact"]["method"]
        == "current Sales * (current BusinessGrossProfitMargin - prior BusinessGrossProfitMargin) (XBRL)"
    )


def test_apply_operating_profit_change_from_xbrl_skips_when_xbrl_missing() -> None:
    """XBRLデータがない年度はスキップされる。"""
    years = [_blank_year("2022-03-31")]
    apply_operating_profit_change_from_xbrl(years, {}, {})
    assert "OperatingProfitChange" not in _cd(years[0])


def test_apply_operating_profit_change_from_xbrl_sga_without_prior() -> None:
    """当期GP/OPはあるが前期値が欠ける場合、販管費は付与されるが前年差分解は出ない。"""
    years = [_blank_year("2022-03-31")]
    gp_by_year = {
        "20220331": {
            "current": 480.0 * _M,
            "prior": None,
            "method": "computed",
            "accounting_standard": "J-GAAP",
            "components": [],
            "current_sales": 1_200.0 * _M,
            "prior_sales": None,
        }
    }
    op_by_year = {
        "20220331": {"current": 150.0 * _M, "prior": None, "method": "direct", "label": "営業利益", "accounting_standard": "J-GAAP"},
    }

    apply_operating_profit_change_from_xbrl(years, gp_by_year, op_by_year)

    cd = _cd(years[0])
    assert cd["SellingGeneralAdministrativeExpenses"] == pytest.approx(330.0)
    assert "OperatingProfitChange" not in cd
