"""
segment_extractor.py ユニットテスト

ファイルI/Oを伴わない純粋なヘルパー関数を対象とする。
  _expand_table       : rowspan/colspan を展開したグリッドを返す
  _grid_to_markdown   : グリッド → Markdown 文字列
  _detect_period_from_grid : 当期/前期を判定
  _apply_period_ordering   : 未ラベルテーブルに前期→当期の順序を付与
"""

import pytest

try:
    from bs4 import BeautifulSoup
    _BS4_AVAILABLE = True
except ImportError:
    _BS4_AVAILABLE = False

from blue_ticker.analysis.segment_extractor import (
    _apply_period_ordering,
    _detect_period_from_grid,
    _grid_to_markdown,
)

pytestmark = pytest.mark.skipif(not _BS4_AVAILABLE, reason="bs4 not installed")


def _make_table(html: str):
    """HTML 文字列から BeautifulSoup table タグを返す。"""
    soup = BeautifulSoup(html, "html.parser")
    return soup.find("table")


# ---------------------------------------------------------------------------
# _grid_to_markdown
# ---------------------------------------------------------------------------

class TestGridToMarkdown:
    def test_simple_2x2(self):
        grid = [["A", "B"], ["1", "2"]]
        md = _grid_to_markdown(grid)
        assert "| A | B |" in md
        assert "| 1 | 2 |" in md
        assert "|---|---|" in md or "---" in md

    def test_empty_grid_returns_empty(self):
        assert _grid_to_markdown([]) == ""

    def test_header_separator_after_first_row(self):
        grid = [["Header"], ["Value"]]
        md = _grid_to_markdown(grid)
        lines = md.splitlines()
        assert len(lines) == 3  # header / separator / value

    def test_columns_are_padded_to_max_width(self):
        grid = [["Short", "A very long column header"]]
        md = _grid_to_markdown(grid)
        assert "A very long column header" in md

    def test_single_row(self):
        grid = [["Only", "Row"]]
        md = _grid_to_markdown(grid)
        assert "Only" in md
        assert "Row" in md


# ---------------------------------------------------------------------------
# _detect_period_from_grid
# ---------------------------------------------------------------------------

class TestDetectPeriodFromGrid:
    def test_detects_current_period(self):
        grid = [["当連結会計年度", "数値"], ["売上高", "1000"]]
        assert _detect_period_from_grid(grid) == "当期"

    def test_detects_prior_period(self):
        grid = [["前連結会計年度", "数値"], ["売上高", "900"]]
        assert _detect_period_from_grid(grid) == "前期"

    def test_detects_comparison_when_both_present(self):
        grid = [["前連結会計年度", "当連結会計年度"], ["900", "1000"]]
        assert _detect_period_from_grid(grid) == "比較"

    def test_detects_short_form_current(self):
        grid = [["当期", "数値"]]
        assert _detect_period_from_grid(grid) == "当期"

    def test_detects_short_form_prior(self):
        grid = [["前期", "数値"]]
        assert _detect_period_from_grid(grid) == "前期"

    def test_no_period_keyword_returns_none(self):
        grid = [["セグメント", "売上高"], ["事業A", "500"]]
        assert _detect_period_from_grid(grid) is None

    def test_only_checks_first_3_rows(self):
        # キーワードが4行目以降にある場合は検知しない
        grid = [
            ["セグメント名", "値"],
            ["事業A", "100"],
            ["事業B", "200"],
            ["当連結会計年度の合計", "300"],
        ]
        assert _detect_period_from_grid(grid) is None

    def test_empty_grid_returns_none(self):
        assert _detect_period_from_grid([]) is None


# ---------------------------------------------------------------------------
# _apply_period_ordering
# ---------------------------------------------------------------------------

class TestApplyPeriodOrdering:
    def test_unlabeled_gets_alternating_labels(self):
        tables = [
            {"heading": "セグメント情報", "markdown": "| A |"},
            {"heading": "セグメント情報", "markdown": "| B |"},
            {"heading": "セグメント情報", "markdown": "| C |"},
            {"heading": "セグメント情報", "markdown": "| D |"},
        ]
        _apply_period_ordering(tables)
        periods = [t["period"] for t in tables]
        assert periods == ["前期", "当期", "前期", "当期"]

    def test_already_labeled_is_not_changed(self):
        tables = [
            {"heading": "X", "markdown": "| 1 |", "period": "当期"},
            {"heading": "X", "markdown": "| 2 |"},
        ]
        _apply_period_ordering(tables)
        assert tables[0]["period"] == "当期"
        assert tables[1]["period"] == "前期"

    def test_all_labeled_unchanged(self):
        tables = [
            {"heading": "X", "markdown": "| 1 |", "period": "比較"},
        ]
        _apply_period_ordering(tables)
        assert tables[0]["period"] == "比較"

    def test_empty_list_does_nothing(self):
        tables: list = []
        _apply_period_ordering(tables)
        assert tables == []


# ---------------------------------------------------------------------------
# _expand_table (BeautifulSoup 依存)
# ---------------------------------------------------------------------------

class TestExpandTable:
    def _expand(self, html: str) -> list[list[str]]:
        from blue_ticker.analysis.segment_extractor import _expand_table
        table = _make_table(html)
        return _expand_table(table)

    def test_simple_table(self):
        html = "<table><tr><td>A</td><td>B</td></tr><tr><td>1</td><td>2</td></tr></table>"
        grid = self._expand(html)
        assert grid == [["A", "B"], ["1", "2"]]

    def test_colspan_expands_cell(self):
        html = "<table><tr><td colspan='2'>合計</td></tr><tr><td>事業A</td><td>100</td></tr></table>"
        grid = self._expand(html)
        assert grid[0] == ["合計", "合計"]
        assert grid[1] == ["事業A", "100"]

    def test_rowspan_repeats_cell_downward(self):
        html = "<table><tr><td rowspan='2'>期間</td><td>Q1</td></tr><tr><td>Q2</td></tr></table>"
        grid = self._expand(html)
        assert grid[0][0] == "期間"
        assert grid[1][0] == "期間"
        assert grid[0][1] == "Q1"
        assert grid[1][1] == "Q2"

    def test_empty_table_returns_empty(self):
        html = "<table></table>"
        grid = self._expand(html)
        assert grid == []

    def test_strips_whitespace_from_cells(self):
        html = "<table><tr><td>  事業A  </td><td>  100  </td></tr></table>"
        grid = self._expand(html)
        assert grid[0] == ["事業A", "100"]
