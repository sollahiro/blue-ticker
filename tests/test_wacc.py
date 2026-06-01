"""
wacc.py ユニットテスト

_parse_mof_date / resolve_rf_for_date / calculate_wacc を検証する。
load_rf_rates / _fetch_csv_rates は外部 I/O を伴うため対象外。
"""

import pytest

from blue_ticker.constants.financial import (
    PERCENT,
    WACC_DEFAULT_BETA,
    WACC_LABEL_COST_OF_DEBT_OUT_OF_RANGE,
    WACC_LABEL_MISSING_INPUT,
    WACC_MARKET_RISK_PREMIUM,
    WACC_RF_FALLBACK,
)
from blue_ticker.utils.wacc import (
    _parse_mof_date,
    calculate_wacc,
    get_rf_for_date,
    resolve_rf_for_date,
)


# ---------------------------------------------------------------------------
# _parse_mof_date
# ---------------------------------------------------------------------------

class TestParseMofDate:
    def test_reiwa(self):
        assert _parse_mof_date("R6.4.23") == "2024-04-23"

    def test_heisei(self):
        assert _parse_mof_date("H31.3.31") == "2019-03-31"

    def test_showa(self):
        assert _parse_mof_date("S49.9.24") == "1974-09-24"

    def test_taisho(self):
        assert _parse_mof_date("T10.1.1") == "1921-01-01"

    def test_invalid_returns_none(self):
        assert _parse_mof_date("2024-04-23") is None
        assert _parse_mof_date("") is None
        assert _parse_mof_date("X6.4.23") is None

    def test_zero_padded_month_day(self):
        result = _parse_mof_date("R6.1.5")
        assert result == "2024-01-05"


# ---------------------------------------------------------------------------
# resolve_rf_for_date
# ---------------------------------------------------------------------------

class TestResolveRfForDate:
    RATES = {
        "2024-03-29": 0.017,
        "2024-03-28": 0.016,
    }

    def test_exact_date_match(self):
        rf, source = resolve_rf_for_date(self.RATES, "2024-03-29")
        assert rf == pytest.approx(0.017)
        assert source == "mof"

    def test_fallback_within_14_days(self):
        # 2024-03-31 は rates に存在しない → 遡って 2024-03-29 を発見
        rf, source = resolve_rf_for_date(self.RATES, "2024-03-31")
        assert rf == pytest.approx(0.017)
        assert source == "mof"

    def test_fallback_when_no_rate_within_range(self):
        rf, source = resolve_rf_for_date(self.RATES, "2024-04-30")
        assert rf == pytest.approx(WACC_RF_FALLBACK)
        assert source == "fallback"

    def test_invalid_date_returns_fallback(self):
        rf, source = resolve_rf_for_date(self.RATES, "invalid-date")
        assert rf == pytest.approx(WACC_RF_FALLBACK)
        assert source == "fallback"

    def test_empty_rates_returns_fallback(self):
        rf, source = resolve_rf_for_date({}, "2024-03-31")
        assert rf == pytest.approx(WACC_RF_FALLBACK)
        assert source == "fallback"


class TestGetRfForDate:
    def test_returns_float(self):
        rates = {"2024-03-31": 0.018}
        assert get_rf_for_date(rates, "2024-03-31") == pytest.approx(0.018)


# ---------------------------------------------------------------------------
# calculate_wacc
# ---------------------------------------------------------------------------

class TestCalculateWacc:
    RF = 0.02  # 2%

    def _expected_re(self) -> float:
        return (self.RF + WACC_DEFAULT_BETA * WACC_MARKET_RISK_PREMIUM) * PERCENT

    def test_cost_of_equity_always_set(self):
        result = calculate_wacc(None, None, None, None, self.RF)
        assert result["CostOfEquity"] == pytest.approx(self._expected_re())

    def test_no_equity_returns_none_wacc(self):
        result = calculate_wacc(None, None, None, None, self.RF)
        assert result["WACC"] is None
        assert result["CostOfDebt"] is None

    def test_no_debt_wacc_equals_cost_of_equity(self):
        result = calculate_wacc(eq=1000.0, ibd=0.0, ie=None, tc_pct=None, rf=self.RF)
        assert result["WACC"] == pytest.approx(self._expected_re())

    def test_full_calculation(self):
        # eq=700, ibd=300, ie=9 (rd=3%), tc=30%
        result = calculate_wacc(eq=700.0, ibd=300.0, ie=9.0, tc_pct=30.0, rf=self.RF)
        assert result["CostOfDebt"] == pytest.approx(3.0)
        assert result["WACC"] is not None
        # WACC = (700/1000)*re + (300/1000)*(0.03)*(1-0.30), in %
        re_ = self.RF + WACC_DEFAULT_BETA * WACC_MARKET_RISK_PREMIUM
        rd_ = 9.0 / 300.0
        tc_ = 30.0 / PERCENT
        expected = ((700 / 1000) * re_ + (300 / 1000) * rd_ * (1 - tc_)) * PERCENT
        assert result["WACC"] == pytest.approx(expected)

    def test_missing_interest_expense_returns_label(self):
        result = calculate_wacc(eq=700.0, ibd=300.0, ie=None, tc_pct=30.0, rf=self.RF)
        assert result["WACCLabel"] == WACC_LABEL_MISSING_INPUT
        assert result["WACC"] is None

    def test_missing_tax_rate_returns_label(self):
        result = calculate_wacc(eq=700.0, ibd=300.0, ie=9.0, tc_pct=None, rf=self.RF)
        assert result["WACCLabel"] == WACC_LABEL_MISSING_INPUT
        assert result["WACC"] is None

    def test_cost_of_debt_over_100pct_returns_label(self):
        # rd = 600/300 = 2.0 > 1.0 → 異常
        result = calculate_wacc(eq=700.0, ibd=300.0, ie=600.0, tc_pct=30.0, rf=self.RF)
        assert result["WACCLabel"] == WACC_LABEL_COST_OF_DEBT_OUT_OF_RANGE
        assert result["CostOfDebt"] is None

    def test_zero_total_capital_returns_none_wacc(self):
        # eq + ibd = 0
        result = calculate_wacc(eq=0.0, ibd=0.0, ie=None, tc_pct=None, rf=self.RF)
        assert result["WACC"] is None
