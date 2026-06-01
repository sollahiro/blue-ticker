"""
_edinet_doc_filter.py ユニットテスト

書類分類・フィルタ系の純粋関数を検証する。
"""

import pytest

from blue_ticker.services._edinet_doc_filter import (
    _amendment_doc_ids_by_year,
    _doc_ids_by_year,
    _doc_type_code,
    _fy_end_key,
    _is_annual_amendment_doc,
    _is_half_year_doc,
    _is_primary_annual_doc,
    _primary_annual_docs,
    _slice_docs_preserving_amendments,
    _slice_half_year_docs,
)


def _annual(doc_id: str, fy_end: str = "2024-03-31") -> dict:
    return {"docID": doc_id, "edinet_fy_end": fy_end, "docTypeCode": "120"}


def _amendment(doc_id: str, fy_end: str = "2024-03-31") -> dict:
    return {"docID": doc_id, "edinet_fy_end": fy_end, "docTypeCode": "130"}


def _half_year(doc_id: str, fy_end: str = "2024-09-30") -> dict:
    return {"docID": doc_id, "edinet_fy_end": fy_end, "docTypeCode": "160"}


def _quarterly(doc_id: str, fy_end: str = "2024-06-30") -> dict:
    return {"docID": doc_id, "edinet_fy_end": fy_end, "docTypeCode": "140"}


# ---------------------------------------------------------------------------
# _fy_end_key
# ---------------------------------------------------------------------------

class TestFyEndKey:
    def test_removes_hyphens(self):
        assert _fy_end_key("2024-03-31") == "20240331"

    def test_non_string_returns_empty(self):
        assert _fy_end_key(None) == ""
        assert _fy_end_key(123) == ""

    def test_already_compact(self):
        assert _fy_end_key("20240331") == "20240331"


# ---------------------------------------------------------------------------
# _doc_type_code
# ---------------------------------------------------------------------------

class TestDocTypeCode:
    def test_annual_report(self):
        assert _doc_type_code({"docTypeCode": "120"}) == "120"

    def test_missing_key_returns_empty(self):
        assert _doc_type_code({}) == ""

    def test_non_string_returns_empty(self):
        assert _doc_type_code({"docTypeCode": 120}) == ""


# ---------------------------------------------------------------------------
# _is_half_year_doc
# ---------------------------------------------------------------------------

class TestIsHalfYearDoc:
    def test_half_year_by_type_code(self):
        assert _is_half_year_doc(_half_year("D001")) is True

    def test_quarterly_by_type_code(self):
        assert _is_half_year_doc(_quarterly("D001")) is True

    def test_annual_is_not_half_year(self):
        assert _is_half_year_doc(_annual("D001")) is False

    def test_period_type_2q(self):
        assert _is_half_year_doc({"period_type": "2Q", "docTypeCode": ""}) is True


# ---------------------------------------------------------------------------
# _is_annual_amendment_doc
# ---------------------------------------------------------------------------

class TestIsAnnualAmendmentDoc:
    def test_amendment_by_type_code(self):
        assert _is_annual_amendment_doc(_amendment("D001")) is True

    def test_amendment_by_flag(self):
        doc = {"docTypeCode": "120", "_is_amendment": True, "edinet_fy_end": "2024-03-31"}
        assert _is_annual_amendment_doc(doc) is True

    def test_annual_is_not_amendment(self):
        assert _is_annual_amendment_doc(_annual("D001")) is False

    def test_half_year_amendment_is_not_annual_amendment(self):
        doc = {"docTypeCode": "160", "_is_amendment": True}
        assert _is_annual_amendment_doc(doc) is False


# ---------------------------------------------------------------------------
# _is_primary_annual_doc
# ---------------------------------------------------------------------------

class TestIsPrimaryAnnualDoc:
    def test_annual_report(self):
        assert _is_primary_annual_doc(_annual("D001")) is True

    def test_empty_type_code_is_primary(self):
        doc = {"docTypeCode": "", "edinet_fy_end": "2024-03-31"}
        assert _is_primary_annual_doc(doc) is True

    def test_half_year_is_not_primary(self):
        assert _is_primary_annual_doc(_half_year("D001")) is False

    def test_amendment_is_not_primary(self):
        assert _is_primary_annual_doc(_amendment("D001")) is False


# ---------------------------------------------------------------------------
# _primary_annual_docs
# ---------------------------------------------------------------------------

class TestPrimaryAnnualDocs:
    def test_returns_only_annual_docs(self):
        docs = [_annual("A"), _half_year("B"), _annual("C")]
        result = _primary_annual_docs(docs)
        ids = [d["docID"] for d in result]
        assert ids == ["A", "C"]

    def test_falls_back_when_no_primary(self):
        docs = [_half_year("B"), _quarterly("Q")]
        result = _primary_annual_docs(docs)
        assert len(result) == 0  # 半期・四半期は fallback でも除外される

    def test_empty_input(self):
        assert _primary_annual_docs([]) == []


# ---------------------------------------------------------------------------
# _doc_ids_by_year
# ---------------------------------------------------------------------------

class TestDocIdsByYear:
    def test_maps_fy_end_to_doc_id(self):
        docs = [_annual("D001", "2024-03-31"), _annual("D002", "2023-03-31")]
        result = _doc_ids_by_year(docs)
        assert result["20240331"] == "D001"
        assert result["20230331"] == "D002"

    def test_first_entry_wins_on_duplicate_fy_end(self):
        docs = [_annual("D001", "2024-03-31"), _annual("D002", "2024-03-31")]
        result = _doc_ids_by_year(docs)
        assert result["20240331"] == "D001"

    def test_half_year_docs_excluded(self):
        docs = [_annual("A", "2024-03-31"), _half_year("B", "2024-09-30")]
        result = _doc_ids_by_year(docs)
        assert "20240930" not in result
        assert "20240331" in result

    def test_empty_input(self):
        assert _doc_ids_by_year([]) == {}


# ---------------------------------------------------------------------------
# _amendment_doc_ids_by_year
# ---------------------------------------------------------------------------

class TestAmendmentDocIdsByYear:
    def test_maps_amendment_to_fy_end(self):
        docs = [_annual("D001", "2024-03-31"), _amendment("D002", "2024-03-31")]
        result = _amendment_doc_ids_by_year(docs)
        assert result["20240331"] == "D002"

    def test_later_entry_overwrites(self):
        docs = [_amendment("D001", "2024-03-31"), _amendment("D002", "2024-03-31")]
        result = _amendment_doc_ids_by_year(docs)
        assert result["20240331"] == "D002"

    def test_empty_input(self):
        assert _amendment_doc_ids_by_year([]) == {}


# ---------------------------------------------------------------------------
# _slice_docs_preserving_amendments
# ---------------------------------------------------------------------------

class TestSliceDocsPreservingAmendments:
    def test_slices_to_max_years(self):
        docs = [_annual(f"D{i:03d}", f"202{4 - i}-03-31") for i in range(5)]
        result = _slice_docs_preserving_amendments(docs, max_years=3)
        assert len(result) == 3

    def test_amendment_for_sliced_year_is_preserved(self):
        docs = [
            _annual("D001", "2024-03-31"),
            _annual("D002", "2023-03-31"),
            _amendment("A001", "2024-03-31"),
        ]
        result = _slice_docs_preserving_amendments(docs, max_years=1)
        ids = [d["docID"] for d in result]
        assert "D001" in ids
        assert "A001" in ids
        assert "D002" not in ids

    def test_amendment_for_excluded_year_is_dropped(self):
        docs = [
            _annual("D001", "2024-03-31"),
            _annual("D002", "2023-03-31"),
            _amendment("A002", "2023-03-31"),
        ]
        result = _slice_docs_preserving_amendments(docs, max_years=1)
        ids = [d["docID"] for d in result]
        assert "A002" not in ids


# ---------------------------------------------------------------------------
# _slice_half_year_docs
# ---------------------------------------------------------------------------

class TestSliceHalfYearDocs:
    def test_slices_non_amendment_docs(self):
        docs = [_half_year(f"H{i:03d}") for i in range(5)]
        result = _slice_half_year_docs(docs, max_years=3)
        assert len(result) == 3

    def test_amendment_docs_excluded(self):
        docs = [
            _half_year("H001"),
            {"docTypeCode": "160", "edinet_fy_end": "2024-09-30", "docID": "HA001", "_is_amendment": True},
        ]
        result = _slice_half_year_docs(docs, max_years=10)
        ids = [d["docID"] for d in result]
        assert "H001" in ids
        assert "HA001" not in ids
