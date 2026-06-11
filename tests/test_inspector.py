"""
inspector（分析キャッシュ異常値候補スキャン）のテスト
"""

from blue_ticker import __version__
from blue_ticker.services.inspector import inspect_analysis_cache, inspect_analysis_entry
from blue_ticker.utils.cache import CacheManager


def _year(fy_end: str, calculated: dict, raw: dict | None = None) -> dict:
    return {
        "fy_end": fy_end,
        "FinancialPeriod": "FY",
        "RawData": {"CurPerType": "FY", **(raw or {})},
        "CalculatedData": calculated,
    }


def _clean_year(fy_end: str, sales: float = 1_000.0) -> dict:
    return _year(fy_end, {
        "Sales": sales,
        "OP": sales * 0.1,
        "NP": sales * 0.07,
        "EffectiveTaxRate": 30.0,
    })


def _entry(years: list[dict], version: str = __version__) -> dict:
    return {
        "_cache_version": version,
        "code": "72030",
        "name": "トヨタ自動車",
        "metrics": {"years": years},
    }


def test_clean_entry_has_no_candidates():
    year_count, candidates = inspect_analysis_entry("72030", _entry([_clean_year("2024-03-31")]))
    assert year_count == 1
    assert candidates == []


def test_missing_core_metrics_detected():
    entry = _entry([_year("2024-03-31", {"Sales": 1_000.0})])
    _, candidates = inspect_analysis_entry("72030", entry)
    checks = {c["check"] for c in candidates}
    assert "missing_core_metrics" in checks
    candidate = next(c for c in candidates if c["check"] == "missing_core_metrics")
    assert "OP" in candidate["message"]
    assert "NP" in candidate["message"]


def test_nonpositive_sales_detected():
    entry = _entry([_year("2024-03-31", {"Sales": -100.0, "OP": 1.0, "NP": 1.0})])
    _, candidates = inspect_analysis_entry("72030", entry)
    assert any(c["check"] == "nonpositive_sales" for c in candidates)


def test_gross_profit_exceeding_sales_detected():
    entry = _entry([_year("2024-03-31", {
        "Sales": 1_000.0, "OP": 100.0, "NP": 70.0,
        "GrossProfit": 2_000.0,
    })])
    _, candidates = inspect_analysis_entry("72030", entry)
    candidate = next(c for c in candidates if c["check"] == "gross_profit_exceeds_sales")
    assert candidate["severity"] == "warning"
    assert candidate["evidence"]["GrossProfit"] == 2_000.0


def test_tax_rate_out_of_range_is_info():
    entry = _entry([_year("2024-03-31", {
        "Sales": 1_000.0, "OP": 100.0, "NP": 70.0,
        "EffectiveTaxRate": 180.0,
    })])
    _, candidates = inspect_analysis_entry("72030", entry)
    candidate = next(c for c in candidates if c["check"] == "tax_rate_out_of_range")
    assert candidate["severity"] == "info"


def test_balance_sheet_identity_violation_detected():
    entry = _entry([_year("2024-03-31", {
        "Sales": 1_000.0, "OP": 100.0, "NP": 70.0,
        "TotalAssets": 10_000.0,
        "CurrentAssets": 4_000.0,
        "NonCurrentAssets": 4_000.0,  # 合計 8,000 ≠ 10,000
        "CurrentLiabilities": 2_000.0,
        "NonCurrentLiabilities": 3_000.0,
        "NetAssets": 5_000.0,  # 合計 10,000 = 一致
    })])
    _, candidates = inspect_analysis_entry("72030", entry)
    checks = [c["check"] for c in candidates]
    assert "balance_sheet_assets_identity" in checks
    assert "balance_sheet_equity_identity" not in checks


def test_free_cf_identity_violation_detected():
    entry = _entry([_year("2024-03-31", {
        "Sales": 1_000.0, "OP": 100.0, "NP": 70.0,
        "CFO": 500.0, "CFI": -200.0, "CFC": 900.0,  # 500-200=300 ≠ 900
    })])
    _, candidates = inspect_analysis_entry("72030", entry)
    candidate = next(c for c in candidates if c["check"] == "free_cf_identity")
    assert candidate["evidence"]["diff"] == 600.0


def test_waterfall_reconciliation_diff_detected():
    entry = _entry([_year("2024-03-31", {
        "Sales": 1_000.0, "OP": 100.0, "NP": 70.0,
        "ROICWaterfallReconciliationDiff": 1.2,
        "BusinessProfitChange": 1_000.0,
        "BusinessProfitChangeReconciliationDiff": 50.0,
    })])
    _, candidates = inspect_analysis_entry("72030", entry)
    recon = [c for c in candidates if c["check"] == "waterfall_reconciliation"]
    assert len(recon) == 2


def test_waterfall_reconciliation_within_tolerance_passes():
    entry = _entry([_year("2024-03-31", {
        "Sales": 1_000.0, "OP": 100.0, "NP": 70.0,
        "ROICWaterfallReconciliationDiff": 0.1,
        "BusinessProfitChange": 1_000.0,
        "BusinessProfitChangeReconciliationDiff": 0.5,
    })])
    _, candidates = inspect_analysis_entry("72030", entry)
    assert not any(c["check"] == "waterfall_reconciliation" for c in candidates)


def test_extreme_yoy_jump_detected():
    entry = _entry([
        _clean_year("2023-03-31", sales=1_000.0),
        _clean_year("2024-03-31", sales=1_000_000.0),  # 1000倍 → 単位誤りの疑い
    ])
    _, candidates = inspect_analysis_entry("72030", entry)
    candidate = next(c for c in candidates if c["check"] == "extreme_yoy_jump")
    assert candidate["fy_end"] == "2024-03-31"
    assert candidate["evidence"]["ratio"] == 1_000.0


def test_stale_cache_version_is_info():
    entry = _entry([_clean_year("2024-03-31")], version="0.0.0")
    _, candidates = inspect_analysis_entry("72030", entry)
    candidate = next(c for c in candidates if c["check"] == "stale_cache_version")
    assert candidate["severity"] == "info"


def test_empty_metrics_detected():
    entry = _entry([])
    year_count, candidates = inspect_analysis_entry("72030", entry)
    assert year_count == 0
    assert any(c["check"] == "empty_metrics" for c in candidates)


def test_inspect_analysis_cache_scans_all_entries(tmp_path):
    cache_manager = CacheManager(cache_dir=str(tmp_path))
    cache_manager.set("individual_analysis_72030", _entry([_clean_year("2024-03-31")]))
    cache_manager.set("individual_analysis_67580", {
        "_cache_version": __version__,
        "code": "67580",
        "name": "ソニーグループ",
        "metrics": {"years": [_year("2024-03-31", {"Sales": -1.0, "OP": 1.0, "NP": 1.0})]},
    })
    cache_manager.set("half_year_periods_72030", {"_cache_version": __version__})  # 対象外プレフィックス

    report = inspect_analysis_cache(cache_manager)

    assert report["scanned_codes"] == 2
    assert report["scanned_years"] == 2
    assert [c["code"] for c in report["candidates"]] == ["67580"]


def test_inspect_analysis_cache_filters_by_codes(tmp_path):
    cache_manager = CacheManager(cache_dir=str(tmp_path))
    cache_manager.set("individual_analysis_72030", _entry([_clean_year("2024-03-31")]))

    report = inspect_analysis_cache(cache_manager, codes=["72030", "99990"])

    assert report["scanned_codes"] == 1
    missing = next(c for c in report["candidates"] if c["check"] == "cache_not_found")
    assert missing["code"] == "99990"
