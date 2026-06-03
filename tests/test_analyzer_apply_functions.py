"""
analyzer.py の _apply_* 関数ユニットテスト

各関数は IndividualAnalyzer に依存しない純粋なモジュール関数なので、
dict を直接組み立てて単体テストできる。
"""

import pytest
from typing import Any, cast

from blue_ticker.services.analyzer import (
    _apply_ibd,
    _apply_interest_expense,
    _apply_nopat,
    _apply_roic,
    _apply_tax,
    _apply_gross_profit,
    _apply_operating_profit,
    _apply_net_revenue,
    _apply_employees,
    _apply_depreciation,
    _apply_cash_conversion_analysis,
    _apply_order_book,
    _resolve_tax_rate,
)
from blue_ticker.utils.metrics_types import YearEntry
from blue_ticker.utils.metrics_access import metric_view
from blue_ticker.constants.financial import (
    MILLION_YEN,
    NOPAT_FALLBACK_TAX_RATE,
    PERCENT,
)


def _make_year(fy_end: str, **cd_fields: Any) -> YearEntry:
    return cast(YearEntry, {
        "fy_end": fy_end,
        "CalculatedData": dict(cd_fields),
        "RawData": {},
    })


# ──────────────────────────────────────────────────────────────
# _apply_ibd
# ──────────────────────────────────────────────────────────────

class TestApplyIbd:
    def test_sets_ibd_fields(self):
        years = [_make_year("2024-03-31")]
        ibd_by_year = {
            "20240331": {
                "current": 500_000_000,
                "components": [
                    {"label": "短期借入金", "current": 200_000_000, "prior": 180_000_000},
                ],
                "accounting_standard": "J-GAAP",
            }
        }
        _apply_ibd(years, ibd_by_year, {})
        cd = years[0]["CalculatedData"]
        assert cd["InterestBearingDebt"] == pytest.approx(500_000_000 / MILLION_YEN)
        assert cd["IBDAccountingStandard"] == "J-GAAP"
        assert cd["MetricSources"]["InterestBearingDebt"]["source"] == "edinet"
        assert cd["MetricSources"]["InterestBearingDebt"]["unit"] == "million_yen"
        assert len(cd["IBDComponents"]) == 1
        assert cd["IBDComponents"][0]["label"] == "短期借入金"
        assert cd["IBDComponents"][0]["current"] == pytest.approx(200_000_000 / MILLION_YEN)
        assert cd["IBDComponents"][0]["prior"] == pytest.approx(180_000_000 / MILLION_YEN)

    def test_sets_doc_id(self):
        years = [_make_year("2024-03-31")]
        _apply_ibd(years, {}, {"20240331": "S100XXXX"})
        assert years[0]["CalculatedData"]["DocID"] == "S100XXXX"
        assert years[0]["CalculatedData"]["MetricSources"]["DocID"]["docID"] == "S100XXXX"

    def test_doc_id_independent_of_ibd(self):
        """IBDデータがなくてもDocIDはセットされる"""
        years = [_make_year("2024-03-31")]
        _apply_ibd(years, {}, {"20240331": "S100YYYY"})
        cd = years[0]["CalculatedData"]
        assert cd["DocID"] == "S100YYYY"
        assert "InterestBearingDebt" not in cd

    def test_sets_amendment_doc_id_separately(self):
        years = [_make_year("2024-03-31")]
        _apply_ibd(
            years,
            {
                "20240331": {
                    "doc_id": "S100ANNUAL",
                    "amendment_doc_id": "S100AMEND",
                },
            },
        )
        cd = years[0]["CalculatedData"]
        assert cd["DocID"] == "S100ANNUAL"
        assert cd["AmendmentDocID"] == "S100AMEND"
        assert cd["MetricSources"]["AmendmentDocID"]["docID"] == "S100AMEND"

    def test_roic_not_set_by_ibd(self):
        years = [_make_year("2024-03-31", NP=100.0, NetAssets=800.0)]
        ibd_by_year = {"20240331": {"current": 200_000_000, "components": [], "accounting_standard": "J-GAAP"}}
        _apply_ibd(years, ibd_by_year, {})
        assert "ROIC" not in years[0]["CalculatedData"]

    def test_skips_when_no_ibd_entry(self):
        years = [_make_year("2024-03-31")]
        _apply_ibd(years, {}, {})
        assert "InterestBearingDebt" not in years[0]["CalculatedData"]

    def test_skips_when_current_is_none(self):
        years = [_make_year("2024-03-31")]
        ibd_by_year = {"20240331": {"current": None, "components": [], "accounting_standard": "J-GAAP"}}
        _apply_ibd(years, ibd_by_year, {})
        assert "InterestBearingDebt" not in years[0]["CalculatedData"]

    def test_component_with_none_prior(self):
        """prior が None のコンポーネントも None のまま保持される"""
        years = [_make_year("2024-03-31")]
        ibd_by_year = {
            "20240331": {
                "current": 100_000_000,
                "components": [{"label": "社債", "current": 100_000_000, "prior": None}],
                "accounting_standard": "IFRS",
            }
        }
        _apply_ibd(years, ibd_by_year, {})
        assert years[0]["CalculatedData"]["IBDComponents"][0]["prior"] is None


# ──────────────────────────────────────────────────────────────
# _apply_interest_expense
# ──────────────────────────────────────────────────────────────

class TestApplyInterestExpense:
    def test_sets_interest_expense(self):
        years = [_make_year("2024-03-31")]
        _apply_interest_expense(years, {"20240331": {"current": 1_000_000}})
        assert years[0]["CalculatedData"]["InterestExpense"] == pytest.approx(1_000_000 / MILLION_YEN)
        assert years[0]["CalculatedData"]["MetricSources"]["InterestExpense"]["source"] == "edinet"

    def test_skips_when_no_entry(self):
        years = [_make_year("2024-03-31")]
        _apply_interest_expense(years, {})
        assert "InterestExpense" not in years[0]["CalculatedData"]

    def test_skips_when_current_is_none(self):
        years = [_make_year("2024-03-31")]
        _apply_interest_expense(years, {"20240331": {"current": None}})
        assert "InterestExpense" not in years[0]["CalculatedData"]


class TestApplyDepreciation:
    def test_sets_depreciation_amortization(self):
        years = [_make_year("2024-03-31")]
        _apply_depreciation(years, {"20240331": {"current": 9_209_000_000}})
        assert years[0]["CalculatedData"]["DepreciationAmortization"] == pytest.approx(9_209_000_000 / MILLION_YEN)
        assert years[0]["CalculatedData"]["MetricSources"]["DepreciationAmortization"]["source"] == "edinet"

    def test_skips_when_no_entry(self):
        years = [_make_year("2024-03-31")]
        _apply_depreciation(years, {})
        assert "DepreciationAmortization" not in years[0]["CalculatedData"]

    def test_skips_when_current_is_none(self):
        years = [_make_year("2024-03-31")]
        _apply_depreciation(years, {"20240331": {"current": None}})
        assert "DepreciationAmortization" not in years[0]["CalculatedData"]


class TestApplyCashConversionAnalysis:
    def test_sets_other_cash_conversion_gap(self):
        years = [_make_year(
            "2024-03-31",
            CFO=4_000.0,
            OP=1_000.0,
            DepreciationAmortization=500.0,
        )]
        _apply_cash_conversion_analysis(years)
        cd = years[0]["CalculatedData"]
        assert cd["OtherCashConversionGap"] == pytest.approx(2_500.0)
        assert cd["MetricSources"]["OtherCashConversionGap"]["source"] == "derived"
        assert cd["MetricSources"]["OtherCashConversionGap"]["method"] == "CFO - OP - DepreciationAmortization"

    def test_skips_when_required_metric_is_missing(self):
        years = [_make_year("2024-03-31", CFO=4_000.0, OP=1_000.0)]
        _apply_cash_conversion_analysis(years)
        assert "OtherCashConversionGap" not in years[0]["CalculatedData"]


class TestApplyOrderBook:
    def test_sets_order_book_fields(self):
        years = [_make_year("2024-03-31")]
        _apply_order_book(
            years,
            {
                "20240331": {
                    "order_intake": 151_272_000_000,
                    "order_backlog": 105_778_000_000,
                    "method": "mda_textblock_table",
                    "docID": "S100TEST",
                }
            },
        )
        cd = years[0]["CalculatedData"]
        assert cd["OrderIntake"] == pytest.approx(151_272)
        assert cd["OrderBacklog"] == pytest.approx(105_778)
        assert cd["MetricSources"]["OrderIntake"]["docID"] == "S100TEST"
        assert cd["MetricSources"]["OrderBacklog"]["method"] == "mda_textblock_table"

    def test_skips_missing_fields_independently(self):
        years = [_make_year("2024-03-31")]
        _apply_order_book(years, {"20240331": {"order_intake": None, "order_backlog": 96_452_000_000}})
        cd = years[0]["CalculatedData"]
        assert "OrderIntake" not in cd
        assert cd["OrderBacklog"] == pytest.approx(96_452)

    def test_skips_when_no_entry(self):
        years = [_make_year("2024-03-31")]
        _apply_order_book(years, {})
        assert "OrderIntake" not in years[0]["CalculatedData"]


# ──────────────────────────────────────────────────────────────
# _apply_tax
# ──────────────────────────────────────────────────────────────

class TestApplyTax:
    def test_sets_tax_fields_computed(self):
        years = [_make_year("2024-03-31")]
        tax_by_year = {
            "20240331": {
                "method": "computed",
                "pretax_income": 50_000_000,
                "income_tax": 15_000_000,
                "effective_tax_rate": 0.30,
            }
        }
        _apply_tax(years, tax_by_year)
        cd = years[0]["CalculatedData"]
        assert cd["PretaxIncome"] == pytest.approx(50_000_000 / MILLION_YEN)
        assert cd["IncomeTax"] == pytest.approx(15_000_000 / MILLION_YEN)
        assert cd["EffectiveTaxRate"] == pytest.approx(0.30 * PERCENT)

    def test_sets_tax_fields_usgaap_html(self):
        years = [_make_year("2024-03-31")]
        tax_by_year = {
            "20240331": {
                "method": "usgaap_html",
                "pretax_income": 1_000_000,
                "income_tax": 300_000,
                "effective_tax_rate": 0.30,
            }
        }
        _apply_tax(years, tax_by_year)
        assert "PretaxIncome" in years[0]["CalculatedData"]

    def test_skips_unsupported_method(self):
        years = [_make_year("2024-03-31")]
        _apply_tax(years, {"20240331": {"method": "not_found", "pretax_income": 1_000_000}})
        assert "PretaxIncome" not in years[0]["CalculatedData"]

    def test_skips_when_no_entry(self):
        years = [_make_year("2024-03-31")]
        _apply_tax(years, {})
        assert "PretaxIncome" not in years[0]["CalculatedData"]

    def test_partial_fields_none_are_skipped(self):
        """pretax_income が None の場合はそのフィールドだけスキップ"""
        years = [_make_year("2024-03-31")]
        tax_by_year = {
            "20240331": {
                "method": "computed",
                "pretax_income": None,
                "income_tax": 15_000_000,
                "effective_tax_rate": 0.30,
            }
        }
        _apply_tax(years, tax_by_year)
        cd = years[0]["CalculatedData"]
        assert "PretaxIncome" not in cd
        assert cd["IncomeTax"] == pytest.approx(15_000_000 / MILLION_YEN)


# ──────────────────────────────────────────────────────────────
# _apply_gross_profit
# ──────────────────────────────────────────────────────────────

class TestApplyGrossProfit:
    def test_sets_gross_profit(self):
        years = [_make_year("2024-03-31", Sales=1000.0, OP=100.0)]
        gp_by_year = {"20240331": {"current": 400_000_000, "method": "direct"}}
        _apply_gross_profit(years, gp_by_year)
        cd = years[0]["CalculatedData"]
        assert cd["GrossProfit"] == pytest.approx(400.0)
        assert cd["GrossProfitMethod"] == "direct"

    def test_calculates_margin(self):
        years = [_make_year("2024-03-31", Sales=1000.0)]
        gp_by_year = {"20240331": {"current": 400_000_000, "method": "direct"}}
        _apply_gross_profit(years, gp_by_year)
        cd = years[0]["CalculatedData"]
        gp_m = 400_000_000 / MILLION_YEN
        assert cd["GrossProfitMargin"] == pytest.approx(gp_m / 1000.0 * PERCENT)
        assert cd["MetricSources"]["GrossProfit"]["method"] == "direct"
        assert cd["MetricSources"]["GrossProfitMargin"]["source"] == "derived"

    def test_no_sales_margin_is_none(self):
        """Salesがない場合、GrossProfitはセットされるがMarginはNone"""
        years = [_make_year("2024-03-31")]
        gp_by_year = {"20240331": {"current": 400_000_000, "method": "direct"}}
        _apply_gross_profit(years, gp_by_year)
        cd = years[0]["CalculatedData"]
        assert cd["GrossProfit"] == pytest.approx(400_000_000 / MILLION_YEN)
        assert cd["GrossProfitMargin"] is None

    def test_sets_method(self):
        years = [_make_year("2024-03-31", Sales=1000.0)]
        gp_by_year = {"20240331": {"current": 300_000_000, "method": "computed"}}
        _apply_gross_profit(years, gp_by_year)
        assert years[0]["CalculatedData"]["GrossProfitMethod"] == "computed"

    def test_sets_business_gross_profit_label(self):
        years = [_make_year("2024-03-31", Sales=10_000.0)]
        gp_by_year = {"20240331": {"current": 4_819_211_000_000, "method": "business_gross_profit"}}
        _apply_gross_profit(years, gp_by_year)
        cd = years[0]["CalculatedData"]
        assert cd["GrossProfit"] == pytest.approx(4_819_211.0)
        assert cd["GrossProfitMethod"] == "business_gross_profit"
        assert cd["GrossProfitLabel"] == "業務粗利益"
        assert cd["MetricSources"]["GrossProfit"]["label"] == "業務粗利益"

    def test_sets_operating_gross_profit_label(self):
        years = [_make_year("2024-03-31", Sales=27_840.047)]
        gp_by_year = {"20240331": {"current": 3_320_406_000, "method": "operating_gross_profit"}}
        _apply_gross_profit(years, gp_by_year)
        cd = years[0]["CalculatedData"]
        assert cd["GrossProfit"] == pytest.approx(3_320.406)
        assert cd["GrossProfitMethod"] == "operating_gross_profit"
        assert cd["GrossProfitLabel"] == "営業総利益"
        assert cd["MetricSources"]["GrossProfit"]["label"] == "営業総利益"

    def test_skips_when_no_entry(self):
        years = [_make_year("2024-03-31", Sales=1000.0)]
        _apply_gross_profit(years, {})
        assert "GrossProfit" not in years[0]["CalculatedData"]

    def test_skips_when_current_is_none(self):
        years = [_make_year("2024-03-31", Sales=1000.0)]
        _apply_gross_profit(years, {"20240331": {"current": None, "method": "direct"}})
        assert "GrossProfit" not in years[0]["CalculatedData"]


# ──────────────────────────────────────────────────────────────
# _apply_operating_profit
# ──────────────────────────────────────────────────────────────

class TestApplyOperatingProfit:
    def test_sets_op_and_margin(self):
        years = [_make_year("2024-03-31", Sales=1000.0)]
        op_by_year = {"20240331": {"current": 100_000_000, "label": "営業利益"}}
        _apply_operating_profit(years, op_by_year)
        cd = years[0]["CalculatedData"]
        op_m = 100_000_000 / MILLION_YEN
        assert years[0]["RawData"]["OP"] == 100_000_000
        assert metric_view(years[0])["OP"] == pytest.approx(op_m)
        assert cd["OperatingMargin"] == pytest.approx(op_m / 1000.0 * PERCENT)

    def test_sets_direct_sga_when_extracted(self):
        years = [_make_year("2024-03-31", Sales=1000.0)]
        op_by_year = {
            "20240331": {
                "current": 100_000_000,
                "label": "営業利益",
                "current_sga": 250_000_000,
            }
        }
        _apply_operating_profit(years, op_by_year)
        cd = years[0]["CalculatedData"]
        assert cd["SellingGeneralAdministrativeExpenses"] == pytest.approx(250.0)
        assert cd["MetricSources"]["SellingGeneralAdministrativeExpenses"]["source"] == "edinet"

    def test_overwrites_existing_op_with_xbrl_extracted_value(self):
        years = [_make_year("2024-03-31", OP=50.0, Sales=1000.0)]
        op_by_year = {"20240331": {"current": 999_999_999, "label": "営業利益"}}
        _apply_operating_profit(years, op_by_year)
        op_m = 999_999_999 / MILLION_YEN
        assert years[0]["RawData"]["OP"] == 999_999_999
        assert metric_view(years[0])["OP"] == pytest.approx(op_m)
        assert years[0]["CalculatedData"]["OperatingMargin"] == pytest.approx(op_m / 1000.0 * PERCENT)

    def test_sets_label_and_margin_when_op_already_set(self):
        years = [_make_year("2024-03-31", OP=50.0, Sales=1000.0)]
        op_by_year = {"20240331": {"current": 60_000_000, "label": "経常利益"}}
        _apply_operating_profit(years, op_by_year)
        cd = years[0]["CalculatedData"]
        assert years[0]["RawData"]["OP"] == 60_000_000
        assert metric_view(years[0])["OP"] == pytest.approx(60.0)
        assert cd["OPLabel"] == "経常利益"
        assert cd["OperatingMargin"] == pytest.approx(6.0)

    def test_sets_op_label_keijou(self):
        years = [_make_year("2024-03-31")]
        op_by_year = {"20240331": {"current": 100_000_000, "label": "経常利益"}}
        _apply_operating_profit(years, op_by_year)
        assert years[0]["CalculatedData"]["OPLabel"] == "経常利益"

    def test_no_label_no_op_label_key(self):
        years = [_make_year("2024-03-31")]
        op_by_year = {"20240331": {"current": 100_000_000, "label": "営業利益"}}
        _apply_operating_profit(years, op_by_year)
        assert "OPLabel" not in years[0]["CalculatedData"]

    def test_no_sales_no_margin(self):
        years = [_make_year("2024-03-31")]
        op_by_year = {"20240331": {"current": 100_000_000, "label": "営業利益"}}
        _apply_operating_profit(years, op_by_year)
        assert "OperatingMargin" not in years[0]["CalculatedData"]

    def test_skips_when_no_entry(self):
        years = [_make_year("2024-03-31", Sales=1000.0)]
        _apply_operating_profit(years, {})
        assert "OP" not in years[0]["CalculatedData"]


# ──────────────────────────────────────────────────────────────
# _apply_net_revenue
# ──────────────────────────────────────────────────────────────

class TestApplyNetRevenue:
    def test_sets_sales_when_none(self):
        years = [_make_year("2024-03-31")]
        nr_by_year = {"20240331": {"found": True, "net_revenue": 2_000_000_000, "business_profit": None}}
        _apply_net_revenue(years, nr_by_year)
        cd = years[0]["CalculatedData"]
        assert years[0]["RawData"]["Sales"] == 2_000_000_000
        assert metric_view(years[0])["Sales"] == pytest.approx(2_000_000_000 / MILLION_YEN)
        assert years[0]["RawData"]["SalesLabel"] == "純収益"
        assert cd["MetricSources"]["Sales"]["label"] == "純収益"

    def test_does_not_overwrite_existing_sales(self):
        years = [_make_year("2024-03-31", Sales=999.0)]
        nr_by_year = {"20240331": {"found": True, "net_revenue": 2_000_000_000, "business_profit": None}}
        _apply_net_revenue(years, nr_by_year)
        assert years[0]["CalculatedData"]["Sales"] == 999.0

    def test_recalculates_gp_margin_after_sales(self):
        years = [_make_year("2024-03-31", GrossProfit=500.0)]
        nr_by_year = {"20240331": {"found": True, "net_revenue": 2_000_000_000, "business_profit": None}}
        _apply_net_revenue(years, nr_by_year)
        cd = years[0]["CalculatedData"]
        nr_m = 2_000_000_000 / MILLION_YEN
        assert cd["GrossProfitMargin"] == pytest.approx(500.0 / nr_m * PERCENT)

    def test_sets_op_from_business_profit(self):
        years = [_make_year("2024-03-31", Sales=2000.0)]
        nr_by_year = {"20240331": {"found": True, "net_revenue": None, "business_profit": 300_000_000}}
        _apply_net_revenue(years, nr_by_year)
        cd = years[0]["CalculatedData"]
        bp_m = 300_000_000 / MILLION_YEN
        assert years[0]["RawData"]["OP"] == 300_000_000
        assert metric_view(years[0])["OP"] == pytest.approx(bp_m)
        assert cd["OPLabel"] == "事業利益"
        assert cd["OperatingMargin"] == pytest.approx(bp_m / 2000.0 * PERCENT)

    def test_does_not_overwrite_existing_op(self):
        years = [_make_year("2024-03-31", OP=100.0, Sales=2000.0)]
        nr_by_year = {"20240331": {"found": True, "net_revenue": None, "business_profit": 999_999_999}}
        _apply_net_revenue(years, nr_by_year)
        assert years[0]["CalculatedData"]["OP"] == 100.0

    def test_skips_when_not_found(self):
        years = [_make_year("2024-03-31")]
        nr_by_year = {"20240331": {"found": False, "net_revenue": 2_000_000_000, "business_profit": None}}
        _apply_net_revenue(years, nr_by_year)
        assert "Sales" not in years[0]["CalculatedData"]

    def test_skips_when_no_entry(self):
        years = [_make_year("2024-03-31")]
        _apply_net_revenue(years, {})
        assert "Sales" not in years[0]["CalculatedData"]

    def test_sets_raw_data_sales(self):
        years = [_make_year("2024-03-31")]
        nr_by_year = {"20240331": {"found": True, "net_revenue": 2_000_000_000, "business_profit": None}}
        _apply_net_revenue(years, nr_by_year)
        assert years[0]["RawData"]["Sales"] == 2_000_000_000


# ──────────────────────────────────────────────────────────────
# _apply_employees
# ──────────────────────────────────────────────────────────────

class TestApplyEmployees:
    def test_sets_employees(self):
        years = [_make_year("2024-03-31")]
        _apply_employees(years, {"20240331": {"current": 5000}})
        assert years[0]["CalculatedData"]["Employees"] == 5000

    def test_skips_when_no_entry(self):
        years = [_make_year("2024-03-31")]
        _apply_employees(years, {})
        assert "Employees" not in years[0]["CalculatedData"]

    def test_skips_when_current_is_none(self):
        years = [_make_year("2024-03-31")]
        _apply_employees(years, {"20240331": {"current": None}})
        assert "Employees" not in years[0]["CalculatedData"]


# ──────────────────────────────────────────────────────────────
# _resolve_tax_rate / _apply_nopat
# ──────────────────────────────────────────────────────────────

class TestResolveTaxRate:
    def test_normal_rate_returned_as_is(self):
        cd = {"EffectiveTaxRate": 25.0}
        rate, is_fallback = _resolve_tax_rate(cd)
        assert rate == pytest.approx(0.25)
        assert not is_fallback

    def test_abnormal_rate_above_50_uses_fallback(self):
        cd = {"EffectiveTaxRate": 895.0}
        rate, is_fallback = _resolve_tax_rate(cd)
        assert rate == NOPAT_FALLBACK_TAX_RATE
        assert is_fallback

    def test_negative_rate_uses_fallback(self):
        cd = {"EffectiveTaxRate": -317.0}
        rate, is_fallback = _resolve_tax_rate(cd)
        assert rate == NOPAT_FALLBACK_TAX_RATE
        assert is_fallback

    def test_missing_rate_returns_none(self):
        cd = {}
        rate, is_fallback = _resolve_tax_rate(cd)
        assert rate is None
        assert not is_fallback

    def test_boundary_50_percent_is_normal(self):
        cd = {"EffectiveTaxRate": 50.0}
        rate, is_fallback = _resolve_tax_rate(cd)
        assert rate == pytest.approx(0.50)
        assert not is_fallback


class TestApplyNopat:
    def _make_op_year(self, fy_end: str, op_yen: float, **cd_fields: Any) -> YearEntry:
        year = _make_year(fy_end, **cd_fields)
        year["RawData"]["OP"] = op_yen
        return year

    def test_normal_tax_rate(self):
        """正常税率: NOPAT = OP × (1 - 実績税率)"""
        op = 113_968 * MILLION_YEN
        years = [self._make_op_year("2024-03-31", op, EffectiveTaxRate=25.437)]
        _apply_nopat(years)
        cd = years[0]["CalculatedData"]
        expected = 113_968 * (1 - 0.25437)
        assert cd["NOPAT"] == pytest.approx(expected, rel=1e-4)
        assert "OP × (1 - income_tax" in cd["MetricSources"]["NOPAT"]["method"]

    def test_abnormal_tax_rate_uses_fallback(self):
        """異常税率: NOPAT = OP × (1 - 35%)"""
        op = 14_382 * MILLION_YEN
        years = [self._make_op_year("2024-03-31", op, EffectiveTaxRate=-317.0)]
        _apply_nopat(years)
        cd = years[0]["CalculatedData"]
        assert cd["NOPAT"] == pytest.approx(14_382 * (1 - NOPAT_FALLBACK_TAX_RATE))
        assert "fallback" in cd["MetricSources"]["NOPAT"]["method"]

    def test_missing_tax_rate_uses_fallback(self):
        """税率未取得: NOPAT = OP × (1 - 35%)"""
        op = 50_000 * MILLION_YEN
        years = [self._make_op_year("2024-03-31", op)]
        _apply_nopat(years)
        cd = years[0]["CalculatedData"]
        assert cd["NOPAT"] == pytest.approx(50_000 * (1 - NOPAT_FALLBACK_TAX_RATE))
        assert "fallback" in cd["MetricSources"]["NOPAT"]["method"]

    def test_missing_op_skips(self):
        """OP 未取得: NOPAT をセットしない"""
        years = [_make_year("2024-03-31", EffectiveTaxRate=25.0)]
        _apply_nopat(years)
        assert "NOPAT" not in years[0]["CalculatedData"]


class TestApplyRoic:
    def test_calculates_roic_using_nopat(self):
        nopat = 80.0
        net_assets = 800.0
        ibd = 200.0
        years = [_make_year("2024-03-31", NOPAT=nopat, NetAssets=net_assets, InterestBearingDebt=ibd)]
        _apply_roic(years)
        cd = years[0]["CalculatedData"]
        expected = nopat / (net_assets + ibd) * PERCENT
        assert cd["ROIC"] == pytest.approx(expected)
        assert cd["MetricSources"]["ROIC"]["method"] == "NOPAT / (NetAssets + InterestBearingDebt)"

    def test_skips_when_nopat_missing(self):
        years = [_make_year("2024-03-31", NetAssets=800.0, InterestBearingDebt=200.0)]
        _apply_roic(years)
        assert "ROIC" not in years[0]["CalculatedData"]

    def test_skips_when_net_assets_missing(self):
        years = [_make_year("2024-03-31", NOPAT=80.0, InterestBearingDebt=200.0)]
        _apply_roic(years)
        assert "ROIC" not in years[0]["CalculatedData"]

    def test_skips_when_ibd_missing(self):
        years = [_make_year("2024-03-31", NOPAT=80.0, NetAssets=800.0)]
        _apply_roic(years)
        assert "ROIC" not in years[0]["CalculatedData"]

    def test_skips_when_invested_capital_is_zero(self):
        years = [_make_year("2024-03-31", NOPAT=80.0, NetAssets=0.0, InterestBearingDebt=0.0)]
        _apply_roic(years)
        assert "ROIC" not in years[0]["CalculatedData"]

    def test_uses_calculated_data_not_raw_data(self):
        year = _make_year("2024-03-31", NOPAT=80.0, NetAssets=800.0, InterestBearingDebt=200.0)
        year["RawData"]["NetAssets"] = 500_000_000_000  # 別APIソース（500B円=500,000百万円）
        _apply_roic([year])
        cd = year["CalculatedData"]
        expected = 80.0 / (800.0 + 200.0) * PERCENT  # CalculatedData の 800M を使う
        assert cd["ROIC"] == pytest.approx(expected)
