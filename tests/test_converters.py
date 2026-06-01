"""
converters.py ユニットテスト

to_float / to_int / is_nan / is_valid_value / extract_year_month 等の
基盤的変換・検証関数を検証する。
"""

import math
from datetime import datetime

import pytest

from blue_ticker.utils.converters import (
    extract_year_month,
    format_date,
    is_future_date,
    is_nan,
    is_valid_financial_record,
    is_valid_value,
    normalize_date,
    parse_date,
    to_float,
    to_int,
)


# ---------------------------------------------------------------------------
# to_float
# ---------------------------------------------------------------------------

class TestToFloat:
    def test_int_value(self):
        assert to_float(42) == 42.0

    def test_float_value(self):
        assert to_float(3.14) == pytest.approx(3.14)

    def test_string_integer(self):
        assert to_float("100") == 100.0

    def test_string_float(self):
        assert to_float("3.14") == pytest.approx(3.14)

    def test_none_returns_none(self):
        assert to_float(None) is None

    def test_nan_float_returns_none(self):
        assert to_float(float("nan")) is None

    def test_empty_string_returns_none(self):
        assert to_float("") is None

    def test_non_numeric_string_returns_none(self):
        assert to_float("abc") is None

    def test_comma_separated(self):
        assert to_float("1,000,000") == 1000000.0

    def test_japanese_dash_as_minus(self):
        assert to_float("－100") == pytest.approx(-100.0)

    def test_negative_number(self):
        assert to_float("-500") == -500.0


# ---------------------------------------------------------------------------
# to_int
# ---------------------------------------------------------------------------

class TestToInt:
    def test_int_value(self):
        assert to_int(42) == 42

    def test_float_truncates(self):
        assert to_int(3.9) == 3

    def test_string_integer(self):
        assert to_int("100") == 100

    def test_string_float(self):
        assert to_int("3.9") == 3

    def test_none_returns_none(self):
        assert to_int(None) is None

    def test_nan_float_returns_none(self):
        assert to_int(float("nan")) is None

    def test_non_numeric_returns_none(self):
        assert to_int("abc") is None


# ---------------------------------------------------------------------------
# is_nan
# ---------------------------------------------------------------------------

class TestIsNan:
    def test_nan_float(self):
        assert is_nan(float("nan")) is True

    def test_normal_float(self):
        assert is_nan(1.0) is False

    def test_zero_is_not_nan(self):
        assert is_nan(0) is False

    def test_none_is_not_nan(self):
        assert is_nan(None) is False

    def test_nan_string(self):
        assert is_nan("nan") is True

    def test_integer(self):
        assert is_nan(42) is False

    def test_regular_string(self):
        assert is_nan("hello") is False


# ---------------------------------------------------------------------------
# is_valid_value
# ---------------------------------------------------------------------------

class TestIsValidValue:
    def test_positive_float(self):
        assert is_valid_value(100.0) is True

    def test_negative_float(self):
        assert is_valid_value(-50.0) is True

    def test_zero_is_invalid(self):
        assert is_valid_value(0) is False

    def test_zero_float_is_invalid(self):
        assert is_valid_value(0.0) is False

    def test_none_is_invalid(self):
        assert is_valid_value(None) is False

    def test_empty_string_is_invalid(self):
        assert is_valid_value("") is False

    def test_nan_is_invalid(self):
        assert is_valid_value(float("nan")) is False

    def test_numeric_string(self):
        assert is_valid_value("100") is True

    def test_zero_string_is_invalid(self):
        assert is_valid_value("0") is False


# ---------------------------------------------------------------------------
# is_valid_financial_record
# ---------------------------------------------------------------------------

class TestIsValidFinancialRecord:
    def test_record_with_sales(self):
        assert is_valid_financial_record({"Sales": 1000.0}) is True

    def test_record_with_op(self):
        assert is_valid_financial_record({"OP": 200.0}) is True

    def test_record_with_np(self):
        assert is_valid_financial_record({"NP": 100.0}) is True

    def test_record_with_net_assets(self):
        assert is_valid_financial_record({"NetAssets": 500.0}) is True

    def test_empty_record_without_dates(self):
        assert is_valid_financial_record({}) is False

    def test_record_with_edinet_dates_only(self):
        record = {"CurFYEn": "2024-03-31", "DiscDate": "2024-06-20"}
        assert is_valid_financial_record(record) is True

    def test_record_with_zero_sales(self):
        assert is_valid_financial_record({"Sales": 0}) is False

    def test_record_with_none_sales(self):
        assert is_valid_financial_record({"Sales": None}) is False


# ---------------------------------------------------------------------------
# extract_year_month
# ---------------------------------------------------------------------------

class TestExtractYearMonth:
    def test_yyyymmdd(self):
        assert extract_year_month("20231231") == (2023, 12)

    def test_hyphenated(self):
        assert extract_year_month("2023-12-31") == (2023, 12)

    def test_march(self):
        assert extract_year_month("20240331") == (2024, 3)

    def test_empty_returns_none_tuple(self):
        assert extract_year_month("") == (None, None)

    def test_invalid_returns_none_tuple(self):
        assert extract_year_month("invalid") == (None, None)

    def test_slash_format(self):
        year, month = extract_year_month("2023/12/31")
        assert year == 2023
        assert month == 12


# ---------------------------------------------------------------------------
# normalize_date / parse_date / format_date
# ---------------------------------------------------------------------------

class TestDateFunctions:
    def test_normalize_date_yyyymmdd(self):
        assert normalize_date("20231231") == "2023-12-31"

    def test_normalize_date_hyphenated(self):
        assert normalize_date("2023-12-31") == "2023-12-31"

    def test_normalize_date_empty_returns_none(self):
        assert normalize_date("") is None

    def test_parse_date_hyphenated(self):
        result = parse_date("2023-12-31")
        assert result == datetime(2023, 12, 31)

    def test_parse_date_yyyymmdd(self):
        result = parse_date("20231231")
        assert result == datetime(2023, 12, 31)

    def test_parse_date_slash(self):
        result = parse_date("2023/12/31")
        assert result == datetime(2023, 12, 31)

    def test_parse_date_empty_returns_none(self):
        assert parse_date("") is None

    def test_parse_date_invalid_returns_none(self):
        assert parse_date("not-a-date") is None

    def test_format_date(self):
        dt = datetime(2023, 12, 31)
        assert format_date(dt) == "2023-12-31"

    def test_format_date_custom_fmt(self):
        dt = datetime(2023, 12, 31)
        assert format_date(dt, "%Y%m%d") == "20231231"


# ---------------------------------------------------------------------------
# is_future_date
# ---------------------------------------------------------------------------

class TestIsFutureDate:
    def test_future_date(self):
        reference = datetime(2023, 1, 1)
        assert is_future_date("2024-12-31", reference=reference) is True

    def test_past_date(self):
        reference = datetime(2024, 1, 1)
        assert is_future_date("2023-01-01", reference=reference) is False

    def test_empty_returns_false(self):
        assert is_future_date("") is False

    def test_invalid_returns_false(self):
        assert is_future_date("invalid") is False
