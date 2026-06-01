"""
fiscal_year.py ユニットテスト

CLAUDE.md で「正規関数として必ず使うこと」と定められた
normalize_date_format / parse_date_string / calculate_fiscal_year 等を検証する。
"""

from datetime import datetime

import pytest

from blue_ticker.utils.fiscal_year import (
    calculate_fiscal_year,
    calculate_fiscal_year_from_start,
    extract_fiscal_year_from_fy_end,
    extract_fiscal_year_number,
    format_date_for_display,
    format_document_date,
    normalize_date_format,
    parse_date_string,
)


# ---------------------------------------------------------------------------
# normalize_date_format
# ---------------------------------------------------------------------------

class TestNormalizeDateFormat:
    def test_yyyymmdd_to_hyphenated(self):
        assert normalize_date_format("20231231") == "2023-12-31"

    def test_already_hyphenated_is_idempotent(self):
        assert normalize_date_format("2023-12-31") == "2023-12-31"

    def test_hyphenated_with_extra_suffix_truncates(self):
        assert normalize_date_format("2023-12-31T00:00:00") == "2023-12-31"

    def test_none_returns_none(self):
        assert normalize_date_format(None) is None

    def test_empty_string_returns_none(self):
        assert normalize_date_format("") is None

    def test_invalid_string_returns_none(self):
        assert normalize_date_format("not-a-date") is None

    def test_year_only_returns_none(self):
        assert normalize_date_format("2023") is None

    def test_january_first(self):
        assert normalize_date_format("20230101") == "2023-01-01"

    def test_march_end_of_month(self):
        assert normalize_date_format("20240331") == "2024-03-31"

    def test_invalid_date_value_returns_none(self):
        assert normalize_date_format("2023-13-01") is None


# ---------------------------------------------------------------------------
# parse_date_string
# ---------------------------------------------------------------------------

class TestParseDateString:
    def test_yyyymmdd(self):
        result = parse_date_string("20231231")
        assert result == datetime(2023, 12, 31)

    def test_hyphenated(self):
        result = parse_date_string("2023-12-31")
        assert result == datetime(2023, 12, 31)

    def test_none_returns_none(self):
        assert parse_date_string(None) is None

    def test_empty_returns_none(self):
        assert parse_date_string("") is None

    def test_invalid_returns_none(self):
        assert parse_date_string("invalid") is None

    def test_hyphenated_with_time_suffix(self):
        result = parse_date_string("2023-12-31T10:00:00")
        assert result == datetime(2023, 12, 31)

    def test_january_first(self):
        result = parse_date_string("20230101")
        assert result == datetime(2023, 1, 1)


# ---------------------------------------------------------------------------
# calculate_fiscal_year
# ---------------------------------------------------------------------------

class TestCalculateFiscalYear:
    def test_march_fy_end_returns_previous_year(self):
        # 3月決算: fy_end が3月なのでmonth < 12 → year - 1
        assert calculate_fiscal_year("2024-03-31") is None or calculate_fiscal_year("2024-03-31") == 2023

    def test_december_fy_end_returns_same_year(self):
        # 12月決算: month == 12 → year
        assert calculate_fiscal_year("2023-12-31") == 2023

    def test_none_returns_none(self):
        assert calculate_fiscal_year(None) is None

    def test_yyyymmdd_format(self):
        assert calculate_fiscal_year("20231231") == 2023

    def test_fy_start_takes_priority(self):
        # fy_start が指定された場合は開始年を返す
        assert calculate_fiscal_year("2024-03-31", fy_start="2023-04-01") == 2023

    def test_fy_start_overrides_fy_end(self):
        assert calculate_fiscal_year("2023-12-31", fy_start="2023-01-01") == 2023

    def test_invalid_returns_none(self):
        assert calculate_fiscal_year("invalid") is None

    def test_march_fy_end_without_start(self):
        # fy_endが3月（month < 12）は year - 1
        result = calculate_fiscal_year("2024-03-31")
        assert result == 2023

    def test_june_fy_end_without_start(self):
        # 6月決算（month < 12）も year - 1
        result = calculate_fiscal_year("2023-06-30")
        assert result == 2022


# ---------------------------------------------------------------------------
# calculate_fiscal_year_from_start
# ---------------------------------------------------------------------------

class TestCalculateFiscalYearFromStart:
    def test_returns_start_year(self):
        assert calculate_fiscal_year_from_start("2023-04-01") == 2023

    def test_yyyymmdd_format(self):
        assert calculate_fiscal_year_from_start("20230401") == 2023

    def test_invalid_returns_none(self):
        assert calculate_fiscal_year_from_start("invalid") is None


# ---------------------------------------------------------------------------
# extract_fiscal_year_from_fy_end / extract_fiscal_year_number
# ---------------------------------------------------------------------------

class TestExtractFiscalYear:
    def test_from_fy_end_december(self):
        assert extract_fiscal_year_from_fy_end("2023-12-31") == "2023年度"

    def test_from_fy_end_none_returns_empty(self):
        assert extract_fiscal_year_from_fy_end(None) == ""

    def test_number_december(self):
        assert extract_fiscal_year_number("2023-12-31") == 2023

    def test_number_none_returns_none(self):
        assert extract_fiscal_year_number(None) is None


# ---------------------------------------------------------------------------
# format_document_date / format_date_for_display
# ---------------------------------------------------------------------------

class TestFormatHelpers:
    def test_format_document_date_yyyymmdd(self):
        assert format_document_date("20231231") == "2023-12-31"

    def test_format_document_date_non_string_returns_empty(self):
        assert format_document_date(12345) == ""  # type: ignore[arg-type]
        assert format_document_date(None) == ""   # type: ignore[arg-type]

    def test_format_document_date_invalid_returns_empty(self):
        assert format_document_date("invalid") == ""

    def test_format_date_for_display_yyyymmdd(self):
        assert format_date_for_display("20231231") == "2023-12-31"

    def test_format_date_for_display_none_returns_empty(self):
        assert format_date_for_display(None) == ""
