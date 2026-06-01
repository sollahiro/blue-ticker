"""
有利子負債 XBRL 抽出 - ユニットテスト

extract_interest_bearing_debt / _extract_ifrs_lease_liabilities の動作を検証する。

既知の制約:
  - IFRS採用企業では、リース債務が OtherFinancialLiabilities{CL/NCL}IFRS に
    埋め込まれており、専用タグが存在しないケースがある。
    （例: 2802 味の素。報告書記載の有利子負債4,960億円に対し、
          XBRL抽出では約377億円のリース債務が取れず4,583億円となる）
"""

import tempfile
import unittest
from pathlib import Path

from blue_ticker.analysis.interest_bearing_debt import (
    _extract_ifrs_lease_liabilities,
    extract_interest_bearing_debt,
)
from blue_ticker.analysis.sections import BalanceSheetSection

NS_XBRLI = "http://www.xbrl.org/2003/instance"
NS_JPPFS = "http://disclosure.edinet-fsa.go.jp/taxonomy/jppfs/2022-11-01/jppfs_cor"
NS_JPCRP = "http://disclosure.edinet-fsa.go.jp/taxonomy/jpcrp/2022-11-01/jpcrp_cor"


def _make_xbrl(elements_xml: str) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<xbrli:xbrl
    xmlns:xbrli="{NS_XBRLI}"
    xmlns:jppfs_cor="{NS_JPPFS}"
    xmlns:jpcrp_cor="{NS_JPCRP}">

  <xbrli:context id="CurrentYearInstant">
    <xbrli:entity>
      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
    </xbrli:entity>
    <xbrli:period><xbrli:instant>2024-03-31</xbrli:instant></xbrli:period>
  </xbrli:context>

  <xbrli:context id="Prior1YearInstant">
    <xbrli:entity>
      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
    </xbrli:entity>
    <xbrli:period><xbrli:instant>2023-03-31</xbrli:instant></xbrli:period>
  </xbrli:context>

  <xbrli:context id="CurrentYearInstant_NonConsolidatedMember">
    <xbrli:entity>
      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
    </xbrli:entity>
    <xbrli:period><xbrli:instant>2024-03-31</xbrli:instant></xbrli:period>
  </xbrli:context>

  <xbrli:context id="Prior1YearInstant_NonConsolidatedMember">
    <xbrli:entity>
      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
    </xbrli:entity>
    <xbrli:period><xbrli:instant>2023-03-31</xbrli:instant></xbrli:period>
  </xbrli:context>

  <xbrli:unit id="JPY"><xbrli:measure>iso4217:JPY</xbrli:measure></xbrli:unit>

  {elements_xml}
</xbrli:xbrl>"""


def _make_xbrl_with_lease_textblock(base_elements_xml: str, lease_html_rows: str) -> str:
    """リース注記TextBlockを含む XBRL を生成する。"""
    lease_html = f"&lt;table&gt;{lease_html_rows}&lt;/table&gt;"
    return _make_xbrl(
        base_elements_xml
        + f"""
    <jpcrp_cor:NotesLeasesConsolidatedFinancialStatementsIFRSTextBlock
        contextRef="CurrentYearInstant">{lease_html}</jpcrp_cor:NotesLeasesConsolidatedFinancialStatementsIFRSTextBlock>
"""
    )


_IFRS_BORROWINGS_XML = """
    <jppfs_cor:BorrowingsCLIFRS contextRef="CurrentYearInstant"
        unitRef="JPY">5923000000</jppfs_cor:BorrowingsCLIFRS>
    <jppfs_cor:BondsPayableNCLIFRS contextRef="CurrentYearInstant"
        unitRef="JPY">204412000000</jppfs_cor:BondsPayableNCLIFRS>
    <jppfs_cor:BorrowingsNCLIFRS contextRef="CurrentYearInstant"
        unitRef="JPY">211795000000</jppfs_cor:BorrowingsNCLIFRS>
"""


class TestDirectExtraction(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_direct_tag(self):
        xml = _make_xbrl("""
            <jppfs_cor:InterestBearingDebt contextRef="CurrentYearInstant"
                unitRef="JPY">500000000000</jppfs_cor:InterestBearingDebt>
            <jppfs_cor:InterestBearingDebt contextRef="Prior1YearInstant"
                unitRef="JPY">450000000000</jppfs_cor:InterestBearingDebt>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "field_parser")
        self.assertEqual(result["accounting_standard"], "J-GAAP")
        self.assertAlmostEqual(result["current"], 500_000_000_000)
        self.assertAlmostEqual(result["prior"], 450_000_000_000)


class TestJGaapComponents(unittest.TestCase):
    """J-GAAP タグ（全8コンポーネント）のテスト。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_all_eight_components(self):
        xml = _make_xbrl("""
            <jppfs_cor:ShortTermLoansPayable contextRef="CurrentYearInstant"
                unitRef="JPY">10000000000</jppfs_cor:ShortTermLoansPayable>
            <jppfs_cor:CommercialPapersLiabilities contextRef="CurrentYearInstant"
                unitRef="JPY">5000000000</jppfs_cor:CommercialPapersLiabilities>
            <jppfs_cor:CurrentPortionOfBonds contextRef="CurrentYearInstant"
                unitRef="JPY">3000000000</jppfs_cor:CurrentPortionOfBonds>
            <jppfs_cor:CurrentPortionOfLongTermLoansPayable contextRef="CurrentYearInstant"
                unitRef="JPY">8000000000</jppfs_cor:CurrentPortionOfLongTermLoansPayable>
            <jppfs_cor:BondsPayable contextRef="CurrentYearInstant"
                unitRef="JPY">50000000000</jppfs_cor:BondsPayable>
            <jppfs_cor:LongTermLoansPayable contextRef="CurrentYearInstant"
                unitRef="JPY">30000000000</jppfs_cor:LongTermLoansPayable>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "field_parser")
        self.assertEqual(result["accounting_standard"], "J-GAAP")
        # 合計: 10+5+3+8+50+30 = 106 十億円
        self.assertAlmostEqual(result["current"], 106_000_000_000)
        labels = [c["label"] for c in result["components"] if c["tag"]]
        self.assertIn("短期借入金", labels)
        self.assertIn("コマーシャル・ペーパー", labels)
        self.assertIn("1年内償還予定の社債", labels)
        self.assertIn("1年内返済予定の長期借入金", labels)
        self.assertIn("社債", labels)
        self.assertIn("長期借入金", labels)


class TestIfrsComponents(unittest.TestCase):
    """IFRS タグのテスト。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_ifrs_tags(self):
        xml = _make_xbrl("""
            <jppfs_cor:BorrowingsCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">5923000000</jppfs_cor:BorrowingsCLIFRS>
            <jppfs_cor:CommercialPapersCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">10000000000</jppfs_cor:CommercialPapersCLIFRS>
            <jppfs_cor:CurrentPortionOfBondsCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">24989000000</jppfs_cor:CurrentPortionOfBondsCLIFRS>
            <jppfs_cor:CurrentPortionOfLongTermBorrowingsCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">8234000000</jppfs_cor:CurrentPortionOfLongTermBorrowingsCLIFRS>
            <jppfs_cor:BondsPayableNCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">204412000000</jppfs_cor:BondsPayableNCLIFRS>
            <jppfs_cor:BorrowingsNCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">211795000000</jppfs_cor:BorrowingsNCLIFRS>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "field_parser")
        self.assertEqual(result["accounting_standard"], "IFRS")
        # 合計: 5923+10000+24989+8234+204412+211795 = 465353 百万円
        self.assertAlmostEqual(result["current"], 465_353_000_000)
        tags_found = [c["tag"] for c in result["components"] if c["tag"]]
        self.assertIn("BorrowingsCLIFRS", tags_found)
        self.assertIn("BondsPayableNCLIFRS", tags_found)
        self.assertIn("BorrowingsNCLIFRS", tags_found)

    def test_ifrs_bonds_borrowings_and_lease_liabilities_tags(self):
        """三菱電機形式: 社債、借入金及びリース負債の流動/非流動集約タグを使う。"""
        xml = _make_xbrl("""
            <jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesCLIFRS contextRef="Prior1YearInstant"
                unitRef="JPY">151698000000</jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesCLIFRS>
            <jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">120889000000</jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesCLIFRS>
            <jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesNCLIFRS contextRef="Prior1YearInstant"
                unitRef="JPY">242938000000</jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesNCLIFRS>
            <jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesNCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">239772000000</jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesNCLIFRS>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "field_parser")
        self.assertEqual(result["accounting_standard"], "IFRS")
        self.assertAlmostEqual(result["current"], 360_661_000_000)
        self.assertAlmostEqual(result["prior"], 394_636_000_000)
        tags_found = [c["tag"] for c in result["components"] if c["tag"]]
        self.assertIn("BondsBorrowingsAndLeaseLiabilitiesCLIFRS", tags_found)
        self.assertIn("BondsBorrowingsAndLeaseLiabilitiesNCLIFRS", tags_found)


class TestConsolidatedPriority(unittest.TestCase):
    """連結が個別より優先されることのテスト。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_consolidated_over_nonconsolidated(self):
        """同タグに連結・個別両方ある場合、連結が使われる。"""
        xml = _make_xbrl("""
            <jppfs_cor:ShortTermLoansPayable contextRef="CurrentYearInstant"
                unitRef="JPY">999000000000</jppfs_cor:ShortTermLoansPayable>
            <jppfs_cor:ShortTermLoansPayable contextRef="CurrentYearInstant_NonConsolidatedMember"
                unitRef="JPY">100000000000</jppfs_cor:ShortTermLoansPayable>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        comp = next(c for c in result["components"] if c["label"] == "短期借入金")
        self.assertAlmostEqual(comp["current"], 999_000_000_000)

    def test_ifrs_tag_preferred_over_jgaap_nonconsolidated(self):
        """IFRS連結タグが J-GAAP 個別タグより優先される。"""
        # 実際のXBRL書類では NetAssets 等のタグが連結・個別両コンテキストに存在し
        # has_nonconsolidated_contexts が True になる。それを再現して非連結フォールバックを抑止する。
        xml = _make_xbrl("""
            <jppfs_cor:BorrowingsCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">5923000000</jppfs_cor:BorrowingsCLIFRS>
            <jppfs_cor:ShortTermLoansPayable contextRef="CurrentYearInstant_NonConsolidatedMember"
                unitRef="JPY">116294000000</jppfs_cor:ShortTermLoansPayable>
            <jppfs_cor:NetAssets contextRef="CurrentYearInstant"
                unitRef="JPY">1000000000000</jppfs_cor:NetAssets>
            <jppfs_cor:NetAssets contextRef="CurrentYearInstant_NonConsolidatedMember"
                unitRef="JPY">800000000000</jppfs_cor:NetAssets>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        comp = next(c for c in result["components"] if c["label"] == "短期借入金")
        # ShortTermLoansPayable は個別のみ → BorrowingsCLIFRS（連結）が選ばれる
        self.assertAlmostEqual(comp["current"], 5_923_000_000)
        self.assertEqual(comp["tag"], "BorrowingsCLIFRS")


class TestNotFound(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_no_debt_tags(self):
        xml = _make_xbrl("""
            <jpcrp_cor:BusinessRisksTextBlock contextRef="CurrentYearInstant">
                テキストのみ
            </jpcrp_cor:BusinessRisksTextBlock>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "not_found")
        self.assertIsNone(result["current"])


class TestExtractIfrsLeaseLiabilities(unittest.TestCase):
    """_extract_ifrs_lease_liabilities のユニットテスト。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_pattern_a_cl_and_ncl(self):
        """パターンA: 流動（1年以内）と非流動（1年超）の両方がある場合。"""
        rows = (
            "&lt;tr&gt;&lt;td&gt;支払期日が1年以内&lt;/td&gt;&lt;td&gt;4,500&lt;/td&gt;&lt;td&gt;5,000&lt;/td&gt;&lt;/tr&gt;"
            "&lt;tr&gt;&lt;td&gt;支払期日が1年超&lt;/td&gt;&lt;td&gt;28,000&lt;/td&gt;&lt;td&gt;32,000&lt;/td&gt;&lt;/tr&gt;"
        )
        xbrl = _make_xbrl_with_lease_textblock(_IFRS_BORROWINGS_XML, rows)
        (self.xbrl_dir / "instance.xml").write_text(xbrl, encoding="utf-8")
        section = BalanceSheetSection.from_xbrl(self.xbrl_dir)
        lease_c, lease_p, comps = _extract_ifrs_lease_liabilities(section)
        from blue_ticker.constants.financial import MILLION_YEN
        self.assertAlmostEqual(lease_c, 37_000 * MILLION_YEN)
        self.assertAlmostEqual(lease_p, 32_500 * MILLION_YEN)
        labels = [c["label"] for c in comps]
        self.assertIn("リース負債（流動）", labels)
        self.assertIn("リース負債（非流動）", labels)

    def test_pattern_b_book_value(self):
        """パターンB: 「帳簿価額」行のみある場合。"""
        rows = (
            "&lt;tr&gt;&lt;td&gt;帳簿価額&lt;/td&gt;&lt;td&gt;28,500&lt;/td&gt;&lt;td&gt;32,539&lt;/td&gt;&lt;/tr&gt;"
        )
        xbrl = _make_xbrl_with_lease_textblock(_IFRS_BORROWINGS_XML, rows)
        (self.xbrl_dir / "instance.xml").write_text(xbrl, encoding="utf-8")
        section = BalanceSheetSection.from_xbrl(self.xbrl_dir)
        lease_c, lease_p, comps = _extract_ifrs_lease_liabilities(section)
        from blue_ticker.constants.financial import MILLION_YEN
        self.assertAlmostEqual(lease_c, 32_539 * MILLION_YEN)
        self.assertAlmostEqual(lease_p, 28_500 * MILLION_YEN)
        self.assertEqual(len(comps), 1)
        self.assertEqual(comps[0]["label"], "リース負債")

    def test_no_matching_rows_returns_none(self):
        """マッチするリース行がない場合は (None, None, []) を返す。"""
        rows = (
            "&lt;tr&gt;&lt;td&gt;減価償却費&lt;/td&gt;&lt;td&gt;1,000&lt;/td&gt;&lt;td&gt;1,200&lt;/td&gt;&lt;/tr&gt;"
        )
        xbrl = _make_xbrl_with_lease_textblock(_IFRS_BORROWINGS_XML, rows)
        (self.xbrl_dir / "instance.xml").write_text(xbrl, encoding="utf-8")
        section = BalanceSheetSection.from_xbrl(self.xbrl_dir)
        lease_c, lease_p, comps = _extract_ifrs_lease_liabilities(section)
        self.assertIsNone(lease_c)
        self.assertIsNone(lease_p)
        self.assertEqual(comps, [])

    def test_no_textblock_returns_none(self):
        """TextBlock自体がない場合は (None, None, []) を返す。"""
        xbrl = _make_xbrl(_IFRS_BORROWINGS_XML)
        (self.xbrl_dir / "instance.xml").write_text(xbrl, encoding="utf-8")
        section = BalanceSheetSection.from_xbrl(self.xbrl_dir)
        lease_c, lease_p, comps = _extract_ifrs_lease_liabilities(section)
        self.assertIsNone(lease_c)
        self.assertIsNone(lease_p)
        self.assertEqual(comps, [])


class TestIfrsLeaseAddedToIbd(unittest.TestCase):
    """extract_interest_bearing_debt でリース負債が加算されることのテスト。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_lease_added_to_ifrs_ibd(self):
        """IFRSで借入金タグ + リース注記が両方ある場合、リース負債が加算される。"""
        rows = (
            "&lt;tr&gt;&lt;td&gt;支払期日が1年以内&lt;/td&gt;&lt;td&gt;4,000&lt;/td&gt;&lt;td&gt;5,000&lt;/td&gt;&lt;/tr&gt;"
            "&lt;tr&gt;&lt;td&gt;支払期日が1年超&lt;/td&gt;&lt;td&gt;28,000&lt;/td&gt;&lt;td&gt;32,000&lt;/td&gt;&lt;/tr&gt;"
        )
        xbrl = _make_xbrl_with_lease_textblock(_IFRS_BORROWINGS_XML, rows)
        (self.xbrl_dir / "instance.xml").write_text(xbrl, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        from blue_ticker.constants.financial import MILLION_YEN
        # 借入金合計: 5923+204412+211795 = 422130 百万円
        # リース負債: 5000+32000 = 37000 百万円
        # IBD合計: 459130 百万円
        self.assertIn("lease_textblock", result["method"])
        self.assertAlmostEqual(result["current"], (422_130 + 37_000) * MILLION_YEN)
        labels = [c["label"] for c in result["components"]]
        self.assertIn("リース負債（流動）", labels)
        self.assertIn("リース負債（非流動）", labels)

    def test_jgaap_lease_not_added(self):
        """J-GAAPではリース注記があってもリース負債は加算されない。"""
        rows = (
            "&lt;tr&gt;&lt;td&gt;支払期日が1年以内&lt;/td&gt;&lt;td&gt;4,000&lt;/td&gt;&lt;td&gt;5,000&lt;/td&gt;&lt;/tr&gt;"
        )
        jgaap_xml = """
    <jppfs_cor:ShortTermLoansPayable contextRef="CurrentYearInstant"
        unitRef="JPY">10000000000</jppfs_cor:ShortTermLoansPayable>
    <jppfs_cor:LongTermLoansPayable contextRef="CurrentYearInstant"
        unitRef="JPY">50000000000</jppfs_cor:LongTermLoansPayable>
"""
        xbrl = _make_xbrl_with_lease_textblock(jgaap_xml, rows)
        (self.xbrl_dir / "instance.xml").write_text(xbrl, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["accounting_standard"], "J-GAAP")
        self.assertNotIn("lease_textblock", result["method"])
        self.assertAlmostEqual(result["current"], 60_000_000_000)


if __name__ == "__main__":
    unittest.main(verbosity=2)
