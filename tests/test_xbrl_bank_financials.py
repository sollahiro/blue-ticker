"""
銀行業固有 貸借対照表項目 XBRL 抽出テスト

テスト対象: blue_ticker.analysis.bank_financials.extract_bank_financials

カバー範囲:
  - J-GAAP 標準タグ（預金・貸出金・現金預け金・譲渡性預金）の4項目一括抽出
  - 譲渡性預金なし（NegotiableCertificatesOfDepositLiabilitiesBNK 不在 → None）
  - 保険タグ（CashAndDepositsAssetsINS）による現金預け金フォールバック
  - NonConsolidatedMember コンテキストへのフォールバック（個別財務のみ企業）
  - 連結コンテキスト優先（連結・個別両方ある場合は連結を使う）
  - 非銀行企業では not_found
  - 当期・前期値の両取得
"""

import tempfile
import unittest
from pathlib import Path

from blue_ticker.analysis.bank_financials import extract_bank_financials
from blue_ticker.analysis.sections import BalanceSheetSection
from blue_ticker.constants.financial import MILLION_YEN

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
      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E99999</xbrli:identifier>
    </xbrli:entity>
    <xbrli:period><xbrli:instant>2025-03-31</xbrli:instant></xbrli:period>
  </xbrli:context>

  <xbrli:context id="Prior1YearInstant">
    <xbrli:entity>
      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E99999</xbrli:identifier>
    </xbrli:entity>
    <xbrli:period><xbrli:instant>2024-03-31</xbrli:instant></xbrli:period>
  </xbrli:context>

  <xbrli:context id="CurrentYearInstant_NonConsolidatedMember">
    <xbrli:entity>
      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E99999</xbrli:identifier>
    </xbrli:entity>
    <xbrli:period><xbrli:instant>2025-03-31</xbrli:instant></xbrli:period>
  </xbrli:context>

  <xbrli:context id="Prior1YearInstant_NonConsolidatedMember">
    <xbrli:entity>
      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E99999</xbrli:identifier>
    </xbrli:entity>
    <xbrli:period><xbrli:instant>2024-03-31</xbrli:instant></xbrli:period>
  </xbrli:context>

  <xbrli:unit id="JPY"><xbrli:measure>iso4217:JPY</xbrli:measure></xbrli:unit>

  {elements_xml}
</xbrli:xbrl>"""


def _section(xbrl_dir: Path) -> BalanceSheetSection:
    return BalanceSheetSection.from_xbrl(xbrl_dir)


class TestAllFourItems(unittest.TestCase):
    """4項目（預金・貸出金・現金預け金・譲渡性預金）が揃っている場合。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_all_four_items_extracted(self):
        xml = _make_xbrl("""
            <jppfs_cor:DepositsLiabilitiesBNK contextRef="CurrentYearInstant"
                unitRef="JPY">228512749000000</jppfs_cor:DepositsLiabilitiesBNK>
            <jppfs_cor:LoansAndBillsDiscountedAssetsBNK contextRef="CurrentYearInstant"
                unitRef="JPY">121436133000000</jppfs_cor:LoansAndBillsDiscountedAssetsBNK>
            <jppfs_cor:CashAndDueFromBanksAssetsBNK contextRef="CurrentYearInstant"
                unitRef="JPY">109095437000000</jppfs_cor:CashAndDueFromBanksAssetsBNK>
            <jppfs_cor:NegotiableCertificatesOfDepositLiabilitiesBNK contextRef="CurrentYearInstant"
                unitRef="JPY">17374010000000</jppfs_cor:NegotiableCertificatesOfDepositLiabilitiesBNK>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_bank_financials(_section(self.xbrl_dir))

        self.assertEqual(result["method"], "field_parser")
        self.assertEqual(result["accounting_standard"], "J-GAAP")
        self.assertAlmostEqual(result["deposits"],          228_512_749 * MILLION_YEN)
        self.assertAlmostEqual(result["loans"],             121_436_133 * MILLION_YEN)
        self.assertAlmostEqual(result["cash_due_from_banks"], 109_095_437 * MILLION_YEN)
        self.assertAlmostEqual(result["negotiable_cds"],     17_374_010 * MILLION_YEN)


class TestNoNegotiableCDs(unittest.TestCase):
    """譲渡性預金タグがない場合 negotiable_cds は None。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_negotiable_cds_none_when_tag_absent(self):
        xml = _make_xbrl("""
            <jppfs_cor:DepositsLiabilitiesBNK contextRef="CurrentYearInstant"
                unitRef="JPY">4243962000000</jppfs_cor:DepositsLiabilitiesBNK>
            <jppfs_cor:LoansAndBillsDiscountedAssetsBNK contextRef="CurrentYearInstant"
                unitRef="JPY">3899036000000</jppfs_cor:LoansAndBillsDiscountedAssetsBNK>
            <jppfs_cor:CashAndDepositsAssetsINS contextRef="CurrentYearInstant"
                unitRef="JPY">956268000000</jppfs_cor:CashAndDepositsAssetsINS>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_bank_financials(_section(self.xbrl_dir))

        self.assertEqual(result["method"], "field_parser")
        self.assertIsNone(result["negotiable_cds"])
        self.assertIsNone(result["negotiable_cds_prior"])


class TestInsuranceCashTag(unittest.TestCase):
    """現金預け金に CashAndDepositsAssetsINS（保険業タグ）が使われる場合。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_insurance_cash_tag_used_as_fallback(self):
        xml = _make_xbrl("""
            <jppfs_cor:DepositsLiabilitiesBNK contextRef="CurrentYearInstant"
                unitRef="JPY">4243962000000</jppfs_cor:DepositsLiabilitiesBNK>
            <jppfs_cor:LoansAndBillsDiscountedAssetsBNK contextRef="CurrentYearInstant"
                unitRef="JPY">3899036000000</jppfs_cor:LoansAndBillsDiscountedAssetsBNK>
            <jppfs_cor:CashAndDepositsAssetsINS contextRef="CurrentYearInstant"
                unitRef="JPY">956268000000</jppfs_cor:CashAndDepositsAssetsINS>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_bank_financials(_section(self.xbrl_dir))

        self.assertAlmostEqual(result["cash_due_from_banks"], 956_268 * MILLION_YEN)

    def test_bnk_tag_takes_priority_over_ins_tag(self):
        """BNKタグとINSタグが両方ある場合、BNKタグが優先される。"""
        xml = _make_xbrl("""
            <jppfs_cor:CashAndDueFromBanksAssetsBNK contextRef="CurrentYearInstant"
                unitRef="JPY">100000000000</jppfs_cor:CashAndDueFromBanksAssetsBNK>
            <jppfs_cor:CashAndDepositsAssetsINS contextRef="CurrentYearInstant"
                unitRef="JPY">999000000000</jppfs_cor:CashAndDepositsAssetsINS>
            <jppfs_cor:DepositsLiabilitiesBNK contextRef="CurrentYearInstant"
                unitRef="JPY">1000000000000</jppfs_cor:DepositsLiabilitiesBNK>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_bank_financials(_section(self.xbrl_dir))

        self.assertAlmostEqual(result["cash_due_from_banks"], 100_000_000_000)


class TestNonConsolidatedFallback(unittest.TestCase):
    """個別財務諸表のみ企業（NonConsolidatedMember）へのフォールバック。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_nonconsolidated_context_used_when_no_consolidated(self):
        """連結コンテキストが存在せず個別のみの場合、個別値が使われる。"""
        xml = _make_xbrl("""
            <jppfs_cor:DepositsLiabilitiesBNK
                contextRef="CurrentYearInstant_NonConsolidatedMember"
                unitRef="JPY">2236350000000</jppfs_cor:DepositsLiabilitiesBNK>
            <jppfs_cor:LoansAndBillsDiscountedAssetsBNK
                contextRef="CurrentYearInstant_NonConsolidatedMember"
                unitRef="JPY">2515593000000</jppfs_cor:LoansAndBillsDiscountedAssetsBNK>
            <jppfs_cor:CashAndDueFromBanksAssetsBNK
                contextRef="CurrentYearInstant_NonConsolidatedMember"
                unitRef="JPY">241754000000</jppfs_cor:CashAndDueFromBanksAssetsBNK>
            <jppfs_cor:NegotiableCertificatesOfDepositLiabilitiesBNK
                contextRef="CurrentYearInstant_NonConsolidatedMember"
                unitRef="JPY">207590000000</jppfs_cor:NegotiableCertificatesOfDepositLiabilitiesBNK>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_bank_financials(_section(self.xbrl_dir))

        self.assertEqual(result["method"], "field_parser")
        self.assertAlmostEqual(result["deposits"],           2_236_350 * MILLION_YEN)
        self.assertAlmostEqual(result["loans"],              2_515_593 * MILLION_YEN)
        self.assertAlmostEqual(result["cash_due_from_banks"],  241_754 * MILLION_YEN)
        self.assertAlmostEqual(result["negotiable_cds"],       207_590 * MILLION_YEN)

    def test_consolidated_preferred_over_nonconsolidated(self):
        """連結・個別両方ある場合は連結が優先される。"""
        xml = _make_xbrl("""
            <jppfs_cor:DepositsLiabilitiesBNK contextRef="CurrentYearInstant"
                unitRef="JPY">500000000000</jppfs_cor:DepositsLiabilitiesBNK>
            <jppfs_cor:DepositsLiabilitiesBNK
                contextRef="CurrentYearInstant_NonConsolidatedMember"
                unitRef="JPY">999000000000</jppfs_cor:DepositsLiabilitiesBNK>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_bank_financials(_section(self.xbrl_dir))

        self.assertAlmostEqual(result["deposits"], 500_000_000_000)


class TestPriorValues(unittest.TestCase):
    """前期値も正しく取得できること。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_prior_values_extracted(self):
        xml = _make_xbrl("""
            <jppfs_cor:DepositsLiabilitiesBNK contextRef="CurrentYearInstant"
                unitRef="JPY">200000000000000</jppfs_cor:DepositsLiabilitiesBNK>
            <jppfs_cor:DepositsLiabilitiesBNK contextRef="Prior1YearInstant"
                unitRef="JPY">190000000000000</jppfs_cor:DepositsLiabilitiesBNK>
            <jppfs_cor:LoansAndBillsDiscountedAssetsBNK contextRef="CurrentYearInstant"
                unitRef="JPY">100000000000000</jppfs_cor:LoansAndBillsDiscountedAssetsBNK>
            <jppfs_cor:LoansAndBillsDiscountedAssetsBNK contextRef="Prior1YearInstant"
                unitRef="JPY">95000000000000</jppfs_cor:LoansAndBillsDiscountedAssetsBNK>
            <jppfs_cor:NegotiableCertificatesOfDepositLiabilitiesBNK
                contextRef="CurrentYearInstant"
                unitRef="JPY">15000000000000</jppfs_cor:NegotiableCertificatesOfDepositLiabilitiesBNK>
            <jppfs_cor:NegotiableCertificatesOfDepositLiabilitiesBNK
                contextRef="Prior1YearInstant"
                unitRef="JPY">12000000000000</jppfs_cor:NegotiableCertificatesOfDepositLiabilitiesBNK>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_bank_financials(_section(self.xbrl_dir))

        self.assertAlmostEqual(result["deposits"],        200_000_000_000_000)
        self.assertAlmostEqual(result["deposits_prior"],  190_000_000_000_000)
        self.assertAlmostEqual(result["loans"],           100_000_000_000_000)
        self.assertAlmostEqual(result["loans_prior"],      95_000_000_000_000)
        self.assertAlmostEqual(result["negotiable_cds"],   15_000_000_000_000)
        self.assertAlmostEqual(result["negotiable_cds_prior"], 12_000_000_000_000)


class TestNotFound(unittest.TestCase):
    """非銀行企業（BNKタグなし）では not_found を返す。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_non_bank_returns_not_found(self):
        xml = _make_xbrl("""
            <jppfs_cor:NetAssets contextRef="CurrentYearInstant"
                unitRef="JPY">500000000000</jppfs_cor:NetAssets>
            <jppfs_cor:TotalAssets contextRef="CurrentYearInstant"
                unitRef="JPY">2000000000000</jppfs_cor:TotalAssets>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_bank_financials(_section(self.xbrl_dir))

        self.assertEqual(result["method"], "not_found")
        self.assertIsNone(result["deposits"])
        self.assertIsNone(result["loans"])
        self.assertIsNone(result["cash_due_from_banks"])
        self.assertIsNone(result["negotiable_cds"])
        self.assertIn("reason", result)

    def test_partial_tags_still_found(self):
        """預金タグだけあれば method は field_parser。"""
        xml = _make_xbrl("""
            <jppfs_cor:DepositsLiabilitiesBNK contextRef="CurrentYearInstant"
                unitRef="JPY">100000000000</jppfs_cor:DepositsLiabilitiesBNK>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_bank_financials(_section(self.xbrl_dir))

        self.assertEqual(result["method"], "field_parser")
        self.assertIsNotNone(result["deposits"])
        self.assertIsNone(result["loans"])
        self.assertIsNone(result["negotiable_cds"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
