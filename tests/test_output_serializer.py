import copy

from blue_ticker.utils.output_serializer import (
    _DEBUG_FIELDS,
    serialize_half_year_periods,
    serialize_metrics_result,
)


PUBLIC_CALCULATED_DATA_KEYS = {
    "Sales",
    "OP",
    "NP",
    "NOPAT",
    "CFO",
    "CFI",
    "CashEq",
    "PayoutRatio",
    "CFC",
    "DepreciationAmortization",
    "OtherCashConversionGap",
    "ROE",
    "CFCVR",
    "GrossProfit",
    "GrossProfitMargin",
    "InterestBearingDebt",
    "ROIC",
    "TotalAssets",
    "CurrentAssets",
    "NonCurrentAssets",
    "CurrentLiabilities",
    "NonCurrentLiabilities",
    "NetAssets",
    "InterestExpense",
    "PretaxIncome",
    "IncomeTax",
    "EffectiveTaxRate",
    "OperatingMargin",
    "BusinessProfit",
    "BusinessProfitMargin",
    "OPLabel",
    "SalesLabel",
    "SellingGeneralAdministrativeExpenses",
    "OperatingProfitChange",
    "SalesChangeImpact",
    "GrossMarginChangeImpact",
    "SGAChangeImpact",
    "Employees",
    "DocID",
}

HALF_YEAR_PUBLIC_DATA_KEYS = {
    "Sales",
    "OP",
    "OperatingMargin",
    "BusinessProfit",
    "BusinessProfitMargin",
    "NP",
    "NOPAT",
    "CFO",
    "CFI",
    "CFC",
    "FreeCF",
    "GrossProfit",
    "GrossProfitMargin",
    "SellingGeneralAdministrativeExpenses",
    "OperatingProfitChange",
    "SalesChangeImpact",
    "GrossMarginChangeImpact",
    "SGAChangeImpact",
    "ROIC",
}


def _complete_calculated_data():
    return {
        "Sales": 1.0,
        "OP": 1.0,
        "NP": 1.0,
        "NOPAT": 1.0,
        "NetAssets": 1.0,
        "CFO": 1.0,
        "CFI": 1.0,
        "CashEq": 1.0,
        "PayoutRatio": 1.0,
        "CFC": 1.0,
        "DepreciationAmortization": 1.0,
        "OtherCashConversionGap": 1.0,
        "ROE": 1.0,
        "CFCVR": 1.0,
        "GrossProfit": 1.0,
        "GrossProfitMargin": 1.0,
        "InterestBearingDebt": 1.0,
        "ROIC": 1.0,
        "TotalAssets": 1.0,
        "CurrentAssets": 1.0,
        "NonCurrentAssets": 1.0,
        "CurrentLiabilities": 1.0,
        "NonCurrentLiabilities": 1.0,
        "NetAssets": 1.0,
        "InterestExpense": 1.0,
        "PretaxIncome": 1.0,
        "IncomeTax": 1.0,
        "EffectiveTaxRate": 1.0,
        "OperatingMargin": 1.0,
        "BusinessProfit": 1.0,
        "BusinessProfitMargin": 1.0,
        "OPLabel": "営業利益",
        "SalesLabel": "売上高",
        "SellingGeneralAdministrativeExpenses": 1.0,
        "OperatingProfitChange": 1.0,
        "SalesChangeImpact": 1.0,
        "GrossMarginChangeImpact": 1.0,
        "SGAChangeImpact": 1.0,
        "OperatingProfitChangeReconciliationDiff": 0.0,
        "Employees": 1,
        "DocID": "S100TEST",
        "CalculatedEPS": 1.0,
        "CalculatedBPS": 1.0,
        "EPSDirectDiff": 0.0,
        "BPSDirectDiff": 0.0,
        "MetricSources": {"Sales": {"source": "external"}},
        "IBDComponents": [{"label": "短期借入金", "current": 1.0}],
        "BalanceSheetComponents": [{"label": "流動資産", "current": 1.0}],
        "BalanceSheetAccountingStandard": "J-GAAP",
        "GrossProfitMethod": "direct",
        "IBDAccountingStandard": "J-GAAP",
    }


def _complete_metrics_result():
    return {
        "code": "7203",
        "latest_fy_end": "2024-03-31",
        "analysis_years": 1,
        "available_years": 1,
        "data_availability": "sufficient",
        "data_availability_message": "ok",
        "data_valid": True,
        "validation_message": None,
        "years": [
            {
                "fy_end": "2024-03-31",
                "FinancialPeriod": "FY",
                "RawData": {
                    "CurPerType": "FY",
                    "Sales": 1.0,
                },
                "CalculatedData": _complete_calculated_data(),
            }
        ],
    }


def _complete_half_year_data():
    return {
        "Sales": 1.0,
        "OP": 1.0,
        "OperatingMargin": 1.0,
        "BusinessProfit": 1.0,
        "BusinessProfitMargin": 1.0,
        "NP": 1.0,
        "NOPAT": 1.0,
        "CFO": 1.0,
        "CFI": 1.0,
        "CFC": 1.0,
        "FreeCF": 1.0,
        "GrossProfit": 1.0,
        "GrossProfitMargin": 1.0,
        "SellingGeneralAdministrativeExpenses": 1.0,
        "OperatingProfitChange": 1.0,
        "SalesChangeImpact": 1.0,
        "GrossMarginChangeImpact": 1.0,
        "SGAChangeImpact": 1.0,
        "OperatingProfitChangeReconciliationDiff": 0.0,
        "ROIC": 1.0,
        "MetricSources": {"Sales": {"source": "external"}},
        "IBDComponents": [{"label": "短期借入金", "current": 1.0}],
        "GrossProfitMethod": "direct",
        "IBDAccountingStandard": "J-GAAP",
    }


def test_serialize_metrics_result_excludes_debug_fields_by_default():
    metrics = {
        "code": "7203",
        "company_name": "Toyota",
        "analysis_years": 1,
        "years": [
            {
                "fy_end": "2024-03-31",
                "RawData": {"Sales": 45_000_000, "NetAssets": 4_000_000},
                "CalculatedData": {
                    "Sales": 45_000.0,
                    "SalesLabel": "売上高",
                    "NetAssets": 4_000.0,
                    "OP": 5_000.0,
                    "OPLabel": "営業利益",
                    "CalculatedEPS": 10.0,
                    "CalculatedBPS": 100.0,
                    "EPSDirectDiff": 0.1,
                    "BPSDirectDiff": -0.2,
                    "MetricSources": {"Sales": {"source": "external"}},
                    "IBDComponents": [{"label": "短期借入金", "current": 100.0}],
                    "GrossProfitMethod": "direct",
                    "IBDAccountingStandard": "J-GAAP",
                },
            }
        ],
    }

    serialized = serialize_metrics_result(metrics)

    assert serialized == {
        "code": "7203",
        "company_name": "Toyota",
        "analysis_years": 1,
        "years": [
            {
                "fy_end": "2024-03-31",
                "RawData": {"Sales": 45_000_000, "NetAssets": 4_000_000},
                "CalculatedData": {
                    "Sales": 45_000.0,
                    "SalesLabel": "売上高",
                    "NetAssets": 4_000.0,
                    "OP": 5_000.0,
                    "OPLabel": "営業利益",
                },
            }
        ],
    }
    assert "MetricSources" in metrics["years"][0]["CalculatedData"]
    assert "NetAssets" in metrics["years"][0]["CalculatedData"]


def test_serialize_metrics_result_includes_debug_fields_when_requested():
    metrics = {
        "code": "7203",
        "years": [
            {
                "fy_end": "2024-03-31",
                "CalculatedData": {
                    "Sales": 45_000.0,
                    "MetricSources": {"Sales": {"source": "external"}},
                    "IBDComponents": [{"label": "社債", "current": 200.0}],
                    "GrossProfitMethod": "computed",
                    "IBDAccountingStandard": "IFRS",
                },
            }
        ],
    }

    assert serialize_metrics_result(metrics, include_debug_fields=True) == metrics


def test_serialize_metrics_result_excludes_raw_debug_fields_by_default():
    metrics = {
        "code": "7203",
        "years": [
            {
                "fy_end": "2024-03-31",
                "RawData": {
                    "Sales": 45_000_000,
                    "CalculatedEPS": 10.0,
                    "CalculatedBPS": 100.0,
                    "EPSDirectDiff": 0.1,
                    "BPSDirectDiff": -0.2,
                },
                "CalculatedData": {},
            }
        ],
    }

    serialized = serialize_metrics_result(metrics)

    assert serialized["years"][0]["RawData"] == {"Sales": 45_000_000}
    assert "CalculatedEPS" in metrics["years"][0]["RawData"]


def test_serialize_metrics_result_handles_missing_years_or_calculated_data():
    metrics_without_years = {"code": "7203"}
    metrics_with_missing_calculated_data = {
        "code": "7203",
        "years": [{"fy_end": "2024-03-31", "RawData": {}}],
    }

    assert serialize_metrics_result(metrics_without_years) == {"code": "7203"}
    assert serialize_metrics_result(metrics_with_missing_calculated_data) == {
        "code": "7203",
        "years": [
            {
                "fy_end": "2024-03-31",
                "RawData": {},
                "CalculatedData": {},
            }
        ],
    }
    assert "CalculatedData" not in metrics_with_missing_calculated_data["years"][0]


def test_serialize_metrics_result_handles_empty_years():
    metrics = {"code": "7203", "years": []}

    assert serialize_metrics_result(metrics) == {"code": "7203", "years": []}


def test_serialize_half_year_periods_excludes_debug_fields_by_default():
    periods = [
        {
            "label": "24H1",
            "period": "H1",
            "data": {
                "Sales": 45.0,
                "CFC": 4.0,
                "FreeCF": 4.0,
                "MetricSources": {"CFC": {"method": "CFO + CFI"}},
                "IBDComponents": [{"label": "短期借入金", "current": 100.0}],
                "GrossProfitMethod": "direct",
                "IBDAccountingStandard": "J-GAAP",
            },
        }
    ]

    serialized = serialize_half_year_periods(periods)

    assert serialized == [
        {
            "label": "24H1",
            "period": "H1",
            "data": {
                "Sales": 45.0,
                "CFC": 4.0,
                "FreeCF": 4.0,
            },
        }
    ]
    assert "MetricSources" in periods[0]["data"]


def test_serialize_half_year_periods_includes_debug_fields_when_requested():
    periods = [
        {
            "label": "24H1",
            "data": {
                "Sales": 45.0,
                "MetricSources": {"Sales": {"source": "external"}},
                "IBDComponents": [{"label": "社債", "current": 200.0}],
                "GrossProfitMethod": "computed",
                "IBDAccountingStandard": "IFRS",
            },
        }
    ]

    assert serialize_half_year_periods(periods, include_debug_fields=True) == periods


def test_serialize_half_year_periods_handles_missing_data():
    periods = [{"label": "24H1", "period": "H1"}]

    assert serialize_half_year_periods(periods) == [
        {
            "label": "24H1",
            "period": "H1",
            "data": {},
        }
    ]


def test_serialize_metrics_result_preserves_all_public_calculated_data_keys():
    metrics = _complete_metrics_result()

    serialized = serialize_metrics_result(metrics)
    calculated_data = serialized["years"][0]["CalculatedData"]

    assert set(calculated_data) == PUBLIC_CALCULATED_DATA_KEYS
    for key in PUBLIC_CALCULATED_DATA_KEYS:
        assert calculated_data[key] == metrics["years"][0]["CalculatedData"][key]
    assert _DEBUG_FIELDS.isdisjoint(calculated_data)


def test_serialize_metrics_result_preserves_outer_structure():
    metrics = _complete_metrics_result()

    serialized = serialize_metrics_result(metrics)

    for key, value in metrics.items():
        if key != "years":
            assert serialized[key] == value

    original_year = metrics["years"][0]
    serialized_year = serialized["years"][0]
    assert serialized_year["fy_end"] == original_year["fy_end"]
    assert serialized_year["FinancialPeriod"] == original_year["FinancialPeriod"]
    assert serialized_year["RawData"] == original_year["RawData"]


def test_serialize_metrics_result_does_not_mutate_input():
    metrics = _complete_metrics_result()
    original = copy.deepcopy(metrics)

    serialize_metrics_result(metrics)

    assert metrics == original
    assert "MetricSources" in metrics["years"][0]["CalculatedData"]


def test_serialize_half_year_periods_preserves_all_public_data_keys():
    periods = [
        {
            "label": "24H1",
            "half": "H1",
            "fy_end": "2024-03-31",
            "data": _complete_half_year_data(),
        }
    ]

    serialized = serialize_half_year_periods(periods)
    data = serialized[0]["data"]

    assert serialized[0]["label"] == periods[0]["label"]
    assert serialized[0]["half"] == periods[0]["half"]
    assert serialized[0]["fy_end"] == periods[0]["fy_end"]
    assert set(data) == HALF_YEAR_PUBLIC_DATA_KEYS
    for key in HALF_YEAR_PUBLIC_DATA_KEYS:
        assert data[key] == periods[0]["data"][key]
    assert _DEBUG_FIELDS.isdisjoint(data)


def test_debug_fields_set_is_exactly():
    assert _DEBUG_FIELDS == frozenset({
        "MetricSources",
        "IBDComponents",
        "GrossProfitMethod",
        "IBDAccountingStandard",
        "BalanceSheetComponents",
        "BalanceSheetAccountingStandard",
        "OperatingProfitChangeReconciliationDiff",
        "ROICWaterfallReconciliationDiff",
        "CalculatedEPS",
        "CalculatedBPS",
        "EPSDirectDiff",
        "BPSDirectDiff",
    })
