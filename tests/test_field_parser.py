"""
field_parser.py ユニットテスト

resolve_item / resolve_item_prefer_current / resolve_aggregate /
derive_subtraction / _normalize_duration / _normalize_instant を検証する。
"""

import pytest

from blue_ticker.analysis.field_parser import (
    FieldSet,
    ResolvedItem,
    _normalize_duration,
    _normalize_instant,
    derive_subtraction,
    field_set_from_pre_parsed,
    field_set_from_pre_parsed_duration,
    resolve_aggregate,
    resolve_item,
    resolve_item_prefer_current,
)


# ---------------------------------------------------------------------------
# テストヘルパー
# ---------------------------------------------------------------------------

def _field_set(*args: tuple[str, float | None, float | None]) -> FieldSet:
    """(tag, current, prior) のリストから FieldSet を構築する。"""
    return {tag: {"current": current, "prior": prior} for tag, current, prior in args}


# ---------------------------------------------------------------------------
# resolve_item
# ---------------------------------------------------------------------------

class TestResolveItem:
    def test_returns_first_matching_tag(self):
        fs = _field_set(("TagA", 100.0, 90.0), ("TagB", 200.0, 180.0))
        result = resolve_item(fs, ["TagA", "TagB"])
        assert result["tag"] == "TagA"
        assert result["current"] == 100.0
        assert result["prior"] == 90.0

    def test_skips_tag_with_both_none(self):
        fs = _field_set(("TagA", None, None), ("TagB", 200.0, None))
        result = resolve_item(fs, ["TagA", "TagB"])
        assert result["tag"] == "TagB"
        assert result["current"] == 200.0

    def test_returns_tag_with_only_prior(self):
        fs = _field_set(("TagA", None, 90.0))
        result = resolve_item(fs, ["TagA"])
        assert result["tag"] == "TagA"
        assert result["current"] is None
        assert result["prior"] == 90.0

    def test_not_found_returns_none_tag(self):
        fs = _field_set(("TagX", None, None))
        result = resolve_item(fs, ["TagA", "TagB"])
        assert result == {"tag": None, "current": None, "prior": None}

    def test_empty_candidates(self):
        fs = _field_set(("TagA", 100.0, None))
        result = resolve_item(fs, [])
        assert result["tag"] is None


# ---------------------------------------------------------------------------
# resolve_item_prefer_current
# ---------------------------------------------------------------------------

class TestResolveItemPreferCurrent:
    def test_prefers_tag_with_current_value(self):
        fs = _field_set(("TagA", None, 90.0), ("TagB", 200.0, None))
        result = resolve_item_prefer_current(fs, ["TagA", "TagB"])
        assert result["tag"] == "TagB"
        assert result["current"] == 200.0

    def test_falls_back_to_prior_only(self):
        fs = _field_set(("TagA", None, 90.0))
        result = resolve_item_prefer_current(fs, ["TagA"])
        assert result["tag"] == "TagA"
        assert result["current"] is None
        assert result["prior"] == 90.0

    def test_returns_first_current_among_candidates(self):
        fs = _field_set(("TagA", 100.0, None), ("TagB", 200.0, None))
        result = resolve_item_prefer_current(fs, ["TagA", "TagB"])
        assert result["tag"] == "TagA"

    def test_not_found_returns_none_tag(self):
        result = resolve_item_prefer_current({}, ["TagA"])
        assert result["tag"] is None


# ---------------------------------------------------------------------------
# resolve_aggregate
# ---------------------------------------------------------------------------

class TestResolveAggregate:
    def test_sums_all_components(self):
        fs = _field_set(("TagA", 100.0, 90.0), ("TagB", 200.0, 180.0))
        result = resolve_aggregate(fs, [["TagA"], ["TagB"]])
        assert result["current"] == pytest.approx(300.0)
        assert result["prior"] == pytest.approx(270.0)

    def test_partial_components_still_aggregate(self):
        fs = _field_set(("TagA", 100.0, None))
        result = resolve_aggregate(fs, [["TagA"], ["TagB"]])
        assert result["current"] == pytest.approx(100.0)
        assert result["prior"] is None

    def test_no_components_found(self):
        result = resolve_aggregate({}, [["TagA"], ["TagB"]])
        assert result["tag"] is None
        assert result["current"] is None
        assert result["prior"] is None

    def test_tag_is_joined_with_plus(self):
        fs = _field_set(("TagA", 100.0, None), ("TagB", 200.0, None))
        result = resolve_aggregate(fs, [["TagA"], ["TagB"]])
        assert "TagA" in (result["tag"] or "")
        assert "TagB" in (result["tag"] or "")


# ---------------------------------------------------------------------------
# derive_subtraction
# ---------------------------------------------------------------------------

class TestDeriveSubtraction:
    def test_subtracts_values(self):
        fs = _field_set(("Total", 500.0, 450.0), ("Cost", 200.0, 180.0))
        result = derive_subtraction(fs, ["Total"], ["Cost"])
        assert result["current"] == pytest.approx(300.0)
        assert result["prior"] == pytest.approx(270.0)

    def test_none_minuend_returns_none(self):
        fs = _field_set(("Total", None, None), ("Cost", 200.0, 180.0))
        result = derive_subtraction(fs, ["Total"], ["Cost"])
        assert result["current"] is None
        assert result["prior"] is None

    def test_none_subtrahend_returns_none(self):
        fs = _field_set(("Total", 500.0, 450.0))
        result = derive_subtraction(fs, ["Total"], ["Cost"])
        assert result["current"] is None
        assert result["prior"] is None

    def test_tag_contains_minus_separator(self):
        fs = _field_set(("Total", 500.0, None), ("Cost", 200.0, None))
        result = derive_subtraction(fs, ["Total"], ["Cost"])
        assert "-" in (result["tag"] or "")


# ---------------------------------------------------------------------------
# _normalize_duration (内部関数)
# ---------------------------------------------------------------------------

class TestNormalizeDuration:
    def test_exact_current_year_duration(self):
        tag_elements = {
            "Sales": {
                "CurrentYearDuration": 1000.0,
                "Prior1YearDuration": 900.0,
            }
        }
        field_set = _normalize_duration(tag_elements)
        assert field_set["Sales"]["current"] == 1000.0
        assert field_set["Sales"]["prior"] == 900.0

    def test_consolidated_duration_fallback(self):
        # Member 末尾はセグメント軸として除外される（仕様確認テスト）
        tag_elements = {
            "Sales": {
                "CurrentYearDuration_ConsolidatedMember": 1000.0,
            }
        }
        field_set = _normalize_duration(tag_elements)
        assert "Sales" not in field_set  # Member 末尾は連結コンテキストとして認識されない

    def test_consolidated_duration_non_member_suffix(self):
        # Member で終わらない連結コンテキストはフォールバックで拾われる
        tag_elements = {
            "Sales": {
                "CurrentYearDuration_SomeSegment": 1000.0,
            }
        }
        field_set = _normalize_duration(tag_elements)
        assert "Sales" in field_set
        assert field_set["Sales"]["current"] == 1000.0

    def test_empty_input_returns_empty(self):
        assert _normalize_duration({}) == {}


# ---------------------------------------------------------------------------
# _normalize_instant (内部関数)
# ---------------------------------------------------------------------------

class TestNormalizeInstant:
    def test_exact_current_year_instant(self):
        tag_elements = {
            "Assets": {
                "CurrentYearInstant": 5000.0,
                "Prior1YearInstant": 4500.0,
            }
        }
        field_set = _normalize_instant(tag_elements)
        assert field_set["Assets"]["current"] == 5000.0
        assert field_set["Assets"]["prior"] == 4500.0

    def test_empty_input_returns_empty(self):
        assert _normalize_instant({}) == {}


# ---------------------------------------------------------------------------
# field_set_from_pre_parsed (Duration / Instant)
# ---------------------------------------------------------------------------

class TestFieldSetFromPreParsed:
    def test_instant_basic(self):
        tag_elements = {
            "Assets": {"CurrentYearInstant": 5000.0}
        }
        fs = field_set_from_pre_parsed(tag_elements)
        assert "Assets" in fs
        assert fs["Assets"]["current"] == 5000.0

    def test_duration_basic(self):
        tag_elements = {
            "Sales": {"CurrentYearDuration": 1000.0}
        }
        fs = field_set_from_pre_parsed_duration(tag_elements)
        assert "Sales" in fs
        assert fs["Sales"]["current"] == 1000.0

    def test_duration_includes_instant_only_tags_as_markers(self):
        tag_elements = {
            "SomeMarker": {"CurrentYearInstant": 1.0}
        }
        fs = field_set_from_pre_parsed_duration(tag_elements)
        # Instant のみのタグは存在記録として current=None で含まれる
        assert "SomeMarker" in fs
        assert fs["SomeMarker"]["current"] is None
