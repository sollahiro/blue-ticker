from typing import Any, cast

from blue_ticker.analysis.calculator import calculate_metrics_flexible
from blue_ticker.utils.metrics_access import metric_view


def test_calculate_metrics_preserves_sales_label_from_xbrl_record():
    metrics = calculate_metrics_flexible(
        [
            {
                "CurFYEn": "2025-03-31",
                "CurPerType": "FY",
                "Sales": 2_922_428_000_000,
                "SalesLabel": "経常収益",
                "NP": 257_635_000_000,
                "NetAssets": 3_127_317_000_000,
            }
        ],
        analysis_years=1,
    )

    years = metrics.get("years")
    assert years is not None
    cd = cast(dict[str, Any], years[0]["CalculatedData"])
    rd = cast(dict[str, Any], years[0]["RawData"])
    assert rd["Sales"] == 2_922_428_000_000
    assert metric_view(years[0])["Sales"] == 2_922_428
    assert rd["SalesLabel"] == "経常収益"
    assert metric_view(years[0])["SalesLabel"] == "経常収益"
    assert cd["MetricSources"]["Sales"]["label"] == "経常収益"
    assert cd["MetricSources"]["Sales"]["source"] == "edinet"


def test_annual_financial_period():
    annual_data = [
        {"CurFYEn": "20240331", "CurPerType": "FY", "Sales": 1000000000, "ShOutFY": 1000},
        {"CurFYEn": "20230331", "CurPerType": "FY", "Sales": 900000000, "ShOutFY": 1000}
    ]

    metrics = calculate_metrics_flexible(annual_data, analysis_years=2)

    years = metrics.get("years")
    assert years is not None
    assert len(years) == 2
    assert years[0]["FinancialPeriod"] == "2024年03月期"
    assert years[1]["FinancialPeriod"] == "2023年03月期"


def test_eps_bps_remain_raw_values_without_share_adjustment():
    metrics = calculate_metrics_flexible(
        [
            {
                "CurFYEn": "2024-03-31",
                "CurPerType": "FY",
                "Sales": 1_000_000_000,
                "EPS": 50.0,
                "BPS": 500.0,
                "ShOutFY": 2_000,
            },
            {
                "CurFYEn": "2023-03-31",
                "CurPerType": "FY",
                "Sales": 900_000_000,
                "EPS": 100.0,
                "BPS": 800.0,
                "ShOutFY": 1_000,
            },
        ],
        analysis_years=2,
    )

    years = metrics.get("years")
    assert years is not None
    current_raw = cast(dict[str, Any], years[0]["RawData"])
    prior_raw = cast(dict[str, Any], years[1]["RawData"])
    current_calc = cast(dict[str, Any], years[0]["CalculatedData"])
    prior_calc = cast(dict[str, Any], years[1]["CalculatedData"])
    assert current_raw["EPS"] == 50.0
    assert current_raw["BPS"] == 500.0
    assert prior_raw["EPS"] == 100.0
    assert prior_raw["BPS"] == 800.0
    assert "AdjustmentRatio" not in current_calc
    assert "AdjustedEPS" not in prior_calc
    assert "AdjustedBPS" not in prior_calc


def test_calculated_eps_bps_are_exposed_as_verification_values():
    metrics = calculate_metrics_flexible(
        [
            {
                "CurFYEn": "2024-03-31",
                "CurPerType": "FY",
                "Sales": 1_000_000_000,
                "EPS": 18.25,
                "BPS": 98.0,
                "AverageShares": 100.0,
                "TreasuryShares": 10.0,
                "SharesForBPS": 100.0,
                "ParentEquity": 10_000.0,
                "CalculatedEPS": 20.0,
                "CalculatedBPS": 100.0,
                "EPSDirectDiff": -1.75,
                "BPSDirectDiff": -2.0,
                "ShareholderMetricSources": {
                    "EPS": {
                        "source": "direct",
                        "statement": "summary",
                        "confidence": 0.9,
                        "unit": "yen_per_share",
                        "method": "direct",
                    },
                    "AverageShares": {
                        "source": "fallback",
                        "statement": "notes",
                        "confidence": 0.65,
                        "unit": "shares",
                        "method": "textblock_table",
                    },
                    "CalculatedEPS": {
                        "source": "calculated",
                        "statement": "consolidated",
                        "confidence": 0.8,
                        "unit": "yen_per_share",
                        "method": "NP / AverageShares",
                    },
                },
                "_xbrl_source": True,
            },
        ],
        analysis_years=1,
    )

    years = metrics.get("years")
    assert years is not None
    current_raw = cast(dict[str, Any], years[0]["RawData"])
    current_calc = cast(dict[str, Any], years[0]["CalculatedData"])

    assert current_raw["EPS"] == 18.25
    assert current_raw["BPS"] == 98.0
    assert current_calc["CalculatedEPS"] == 20.0
    assert current_calc["CalculatedBPS"] == 100.0
    assert current_calc["EPSDirectDiff"] == -1.75
    assert current_calc["BPSDirectDiff"] == -2.0
    assert current_calc["MetricSources"]["EPS"]["method"] == "direct"
    assert current_calc["MetricSources"]["EPS"]["source"] == "direct"
    assert current_calc["MetricSources"]["EPS"]["statement"] == "summary"
    assert current_calc["MetricSources"]["EPS"]["confidence"] == 0.9
    assert current_calc["MetricSources"]["AverageShares"]["source"] == "fallback"
    assert current_calc["MetricSources"]["AverageShares"]["statement"] == "notes"
    assert current_calc["MetricSources"]["CalculatedEPS"]["method"] == "NP / AverageShares"
    assert current_calc["MetricSources"]["CalculatedEPS"]["statement"] == "consolidated"
