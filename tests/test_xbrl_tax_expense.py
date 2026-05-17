"""
実効税率 XBRL 抽出 - ユニットテスト

損益計算書（Duration コンテキスト）から税引前利益・法人税等を抽出し
実効税率を計算するロジックを検証する。

会計基準: J-GAAP / IFRS / US-GAAP（HTML）
"""

import unittest
import tempfile
from pathlib import Path

from blue_ticker.analysis.tax_expense import extract_tax_expense
from blue_ticker.analysis.sections import IncomeStatementSection

NS_XBRLI = "http://www.xbrl.org/2003/instance"
NS_JPPFS = "http://disclosure.edinet-fsa.go.jp/taxonomy/jppfs/2022-11-01/jppfs_cor"
NS_JPIFRS = "http://disclosure.edinet-fsa.go.jp/taxonomy/jpifrs/2022-11-01/jpifrs_cor"
NS_JPCRP = "http://disclosure.edinet-fsa.go.jp/taxonomy/jpcrp/2022-11-01/jpcrp_cor"


def _make_xbrl(elements_xml: str) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<xbrli:xbrl
    xmlns:xbrli="{NS_XBRLI}"
    xmlns:jppfs_cor="{NS_JPPFS}"
    xmlns:jpifrs_cor="{NS_JPIFRS}"
    xmlns:jpcrp_cor="{NS_JPCRP}">

  <xbrli:context id="CurrentYearDuration">
    <xbrli:entity>
      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
    </xbrli:entity>
    <xbrli:period>
      <xbrli:startDate>2023-04-01</xbrli:startDate>
      <xbrli:endDate>2024-03-31</xbrli:endDate>
    </xbrli:period>
  </xbrli:context>

  <xbrli:context id="Prior1YearDuration">
    <xbrli:entity>
      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
    </xbrli:entity>
    <xbrli:period>
      <xbrli:startDate>2022-04-01</xbrli:startDate>
      <xbrli:endDate>2023-03-31</xbrli:endDate>
    </xbrli:period>
  </xbrli:context>

  <xbrli:context id="CurrentYearDuration_NonConsolidatedMember">
    <xbrli:entity>
      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
    </xbrli:entity>
    <xbrli:period>
      <xbrli:startDate>2023-04-01</xbrli:startDate>
      <xbrli:endDate>2024-03-31</xbrli:endDate>
    </xbrli:period>
  </xbrli:context>

  <xbrli:unit id="JPY"><xbrli:measure>iso4217:JPY</xbrli:measure></xbrli:unit>

  {elements_xml}
</xbrli:xbrl>"""


def _make_usgaap_html(rows: str) -> str:
    return f"""<!DOCTYPE html>
<html>
<body>
<table>
  <tr>
    <th>科目</th>
    <th>前連結会計年度</th>
    <th>当連結会計年度</th>
  </tr>
  {rows}
</table>
</body>
</html>"""


class TestJGaap(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_basic_jgaap(self):
        """J-GAAP: IncomeBeforeIncomeTaxes と IncomeTaxes から実効税率を計算する。"""
        xml = _make_xbrl("""
            <jppfs_cor:IncomeBeforeIncomeTaxes contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">100000000000</jppfs_cor:IncomeBeforeIncomeTaxes>
            <jppfs_cor:IncomeBeforeIncomeTaxes contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">90000000000</jppfs_cor:IncomeBeforeIncomeTaxes>
            <jppfs_cor:IncomeTaxes contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">25000000000</jppfs_cor:IncomeTaxes>
            <jppfs_cor:IncomeTaxes contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">22500000000</jppfs_cor:IncomeTaxes>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_tax_expense(IncomeStatementSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "computed")
        self.assertEqual(result["accounting_standard"], "J-GAAP")
        self.assertAlmostEqual(result["pretax_income"], 100_000_000_000)
        self.assertAlmostEqual(result["income_tax"], 25_000_000_000)
        self.assertAlmostEqual(result["effective_tax_rate"], 0.25)
        self.assertAlmostEqual(result["prior_pretax_income"], 90_000_000_000)
        self.assertAlmostEqual(result["prior_effective_tax_rate"], 0.25)

    def test_consolidated_over_nonconsolidated(self):
        """連結値が存在する場合は個別値より優先する。"""
        xml = _make_xbrl("""
            <jppfs_cor:IncomeBeforeIncomeTaxes contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">100000000000</jppfs_cor:IncomeBeforeIncomeTaxes>
            <jppfs_cor:IncomeBeforeIncomeTaxes contextRef="CurrentYearDuration_NonConsolidatedMember"
                unitRef="JPY" decimals="-6">50000000000</jppfs_cor:IncomeBeforeIncomeTaxes>
            <jppfs_cor:IncomeTaxes contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">25000000000</jppfs_cor:IncomeTaxes>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_tax_expense(IncomeStatementSection.from_xbrl(self.xbrl_dir))
        self.assertAlmostEqual(result["pretax_income"], 100_000_000_000)

    def test_effective_tax_rate_zero_pretax(self):
        """税引前利益がゼロの場合、実効税率は None を返す（ゼロ除算回避）。"""
        xml = _make_xbrl("""
            <jppfs_cor:IncomeBeforeIncomeTaxes contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">0</jppfs_cor:IncomeBeforeIncomeTaxes>
            <jppfs_cor:IncomeTaxes contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">1000000000</jppfs_cor:IncomeTaxes>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_tax_expense(IncomeStatementSection.from_xbrl(self.xbrl_dir))
        self.assertIsNone(result["effective_tax_rate"])


class TestIfrs(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_basic_ifrs(self):
        """IFRS: ProfitLossBeforeTaxIFRS と IncomeTaxExpenseIFRS から実効税率を計算する。"""
        xml = _make_xbrl("""
            <jpifrs_cor:BorrowingsCLIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">200000000000</jpifrs_cor:BorrowingsCLIFRS>
            <jpifrs_cor:ProfitLossBeforeTaxIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">80000000000</jpifrs_cor:ProfitLossBeforeTaxIFRS>
            <jpifrs_cor:ProfitLossBeforeTaxIFRS contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">70000000000</jpifrs_cor:ProfitLossBeforeTaxIFRS>
            <jpifrs_cor:IncomeTaxExpenseIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">20000000000</jpifrs_cor:IncomeTaxExpenseIFRS>
            <jpifrs_cor:IncomeTaxExpenseIFRS contextRef="Prior1YearDuration"
                unitRef="JPY" decimals="-6">17500000000</jpifrs_cor:IncomeTaxExpenseIFRS>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_tax_expense(IncomeStatementSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "computed")
        self.assertEqual(result["accounting_standard"], "IFRS")
        self.assertAlmostEqual(result["pretax_income"], 80_000_000_000)
        self.assertAlmostEqual(result["income_tax"], 20_000_000_000)
        self.assertAlmostEqual(result["effective_tax_rate"], 0.25)
        self.assertAlmostEqual(result["prior_pretax_income"], 70_000_000_000)
        self.assertAlmostEqual(result["prior_effective_tax_rate"], 0.25)


class TestUsGaapHtml(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def _write_usgaap_xbrl(self):
        xml = _make_xbrl("""
            <jpcrp_cor:TotalAssetsUSGAAPSummaryOfBusinessResults
                contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">5000000000000</jpcrp_cor:TotalAssetsUSGAAPSummaryOfBusinessResults>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")

    def test_aggregate_tax_row(self):
        """US-GAAP HTML: 法人税等合計行から税引前利益と法人税等を取得する。"""
        self._write_usgaap_xbrl()
        html = _make_usgaap_html("""
            <tr><td>税引前当期純利益</td><td>36,000</td><td>38,440</td></tr>
            <tr><td>法人税等合計</td><td>9,000</td><td>8,757</td></tr>
        """)
        (self.xbrl_dir / "0105010_test_ixbrl.htm").write_text(html, encoding="utf-8")
        result = extract_tax_expense(IncomeStatementSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "usgaap_html")
        self.assertEqual(result["accounting_standard"], "US-GAAP")
        self.assertAlmostEqual(result["pretax_income"], 38_440_000_000)
        self.assertAlmostEqual(result["income_tax"], 8_757_000_000)
        self.assertAlmostEqual(result["effective_tax_rate"], 8757 / 38440, places=4)

    def test_sum_current_deferred_tax(self):
        """US-GAAP HTML: 法人税等合計がなければ当期税 + 繰延税金を合算する。"""
        self._write_usgaap_xbrl()
        html = _make_usgaap_html("""
            <tr><td>税引前当期純利益</td><td>36,000</td><td>38,440</td></tr>
            <tr><td>法人税、住民税及び事業税</td><td>8,000</td><td>7,000</td></tr>
            <tr><td>法人税等調整額</td><td>1,000</td><td>1,757</td></tr>
        """)
        (self.xbrl_dir / "0105010_test_ixbrl.htm").write_text(html, encoding="utf-8")
        result = extract_tax_expense(IncomeStatementSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "usgaap_html")
        self.assertAlmostEqual(result["income_tax"], 8_757_000_000)  # 7000 + 1757

    def test_delta_notation(self):
        """US-GAAP HTML: △記法の繰延税金も正しく処理する。"""
        self._write_usgaap_xbrl()
        html = _make_usgaap_html("""
            <tr><td>税引前当期純利益</td><td>36,000</td><td>38,440</td></tr>
            <tr><td>法人税、住民税及び事業税</td><td>9,000</td><td>9,500</td></tr>
            <tr><td>法人税等調整額</td><td>△500</td><td>△743</td></tr>
        """)
        (self.xbrl_dir / "0105010_test_ixbrl.htm").write_text(html, encoding="utf-8")
        result = extract_tax_expense(IncomeStatementSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "usgaap_html")
        # 9500 + (-743) = 8757
        self.assertAlmostEqual(result["income_tax"], 8_757_000_000)

    def test_partial_aggregate_fills_prior_from_components(self):
        """US-GAAP HTML: 合計行に当期しかない場合、前期を個別成分から補完する。"""
        self._write_usgaap_xbrl()
        html = _make_usgaap_html("""
            <tr><td>税引前当期純利益</td><td>36,000</td><td>38,440</td></tr>
            <tr><td>法人税等合計</td><td></td><td>8,757</td></tr>
            <tr><td>法人税、住民税及び事業税</td><td>7,000</td><td>7,500</td></tr>
            <tr><td>法人税等調整額</td><td>1,000</td><td>1,257</td></tr>
        """)
        (self.xbrl_dir / "0105010_test_ixbrl.htm").write_text(html, encoding="utf-8")
        result = extract_tax_expense(IncomeStatementSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "usgaap_html")
        self.assertAlmostEqual(result["income_tax"], 8_757_000_000)       # aggregate current
        self.assertAlmostEqual(result["prior_income_tax"], 8_000_000_000)  # 7000 + 1000 from components

    def test_no_html_returns_not_found(self):
        """US-GAAP で 0105010 HTML が存在しない場合 not_found を返す。"""
        self._write_usgaap_xbrl()
        result = extract_tax_expense(IncomeStatementSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "not_found")
        self.assertEqual(result["accounting_standard"], "US-GAAP")
        self.assertIsNone(result["pretax_income"])


class TestNotFound(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_no_tags_returns_not_found(self):
        """税引前利益タグが一切存在しない場合 not_found を返す。"""
        xml = _make_xbrl("")
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_tax_expense(IncomeStatementSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "not_found")
        self.assertIsNone(result["pretax_income"])
        self.assertIsNone(result["income_tax"])

    def test_empty_directory(self):
        """XBRL ファイルが存在しない場合 not_found を返す。"""
        result = extract_tax_expense(IncomeStatementSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "not_found")
        self.assertIsNone(result["pretax_income"])


if __name__ == "__main__":
    unittest.main()
