"""
XBRLParser.extract_sections_by_type のユニットテスト

テキストセクション（MD&A・リスク情報・設備投資等）が
正しいIDで・正しい順序で・過不足なく返されることを検証する。
"""

import tempfile
from pathlib import Path

import pytest

from blue_ticker.analysis.xbrl_parser import XBRLParser
from blue_ticker.constants.xbrl import XBRL_SECTIONS


_XML_WITH_SECTIONS = """<?xml version="1.0" encoding="UTF-8"?>
<xbrli:xbrl xmlns:xbrli="http://www.xbrl.org/2003/instance"
            xmlns:jpcrp_cor="http://disclosure.edinet-fsa.go.jp/taxonomy/jpcrp/2022-11-01/jpcrp_cor">
  <jpcrp_cor:BusinessRisksTextBlock>
    当社グループの事業におけるリスクは以下の通りです。
    1. 市場リスク... 市場状況の変動により、当社の業績に重大な影響を及ぼす可能性があります。具体的には競合他社の動向や景気後退などが挙げられます。
  </jpcrp_cor:BusinessRisksTextBlock>
  <jpcrp_cor:ManagementAnalysisOfFinancialPositionOperatingResultsAndCashFlowsTextBlock>
    当連結会計年度の経営成績は、主力のDX事業が好調に推移した結果、売上高は前期比10%増となりました。営業利益についてもコスト削減が進み、大幅な増益を達成しております。今後も成長投資を継続してまいります。
  </jpcrp_cor:ManagementAnalysisOfFinancialPositionOperatingResultsAndCashFlowsTextBlock>
  <jpcrp_cor:OverviewOfCapitalExpendituresEtcOwnUsedAssetsLEATextBlock>
    設備投資の総額は100億円です。このうち、新工場の建設に80億円、既存設備の更新に20億円を充当いたしました。これにより将来の生産能力が1.5倍に拡大する見込みです。
  </jpcrp_cor:OverviewOfCapitalExpendituresEtcOwnUsedAssetsLEATextBlock>
</xbrli:xbrl>
"""


@pytest.fixture
def xbrl_dir(tmp_path: Path) -> Path:
    (tmp_path / "test_instance.xml").write_text(_XML_WITH_SECTIONS, encoding="utf-8")
    return tmp_path


class TestExtractSectionsByType:
    def test_known_sections_are_extracted_with_correct_ids(self, xbrl_dir: Path):
        sections = XBRLParser().extract_sections_by_type(xbrl_dir)
        assert "mda" in sections
        assert "当連結会計年度の経営成績" in sections["mda"]
        assert "business_risks" in sections
        assert "市場リスク" in sections["business_risks"]
        assert "capex_overview" in sections
        assert "100億円" in sections["capex_overview"]

    def test_section_order_matches_xbrl_sections_definition(self, xbrl_dir: Path):
        sections = XBRLParser().extract_sections_by_type(xbrl_dir)
        populated = [k for k, v in sections.items() if v]
        assert "business_risks" in populated
        assert "mda" in populated
        assert "capex_overview" in populated
        assert populated.index("business_risks") < populated.index("mda")
        assert populated.index("mda") < populated.index("capex_overview")

    def test_all_defined_sections_are_present_as_keys(self, xbrl_dir: Path):
        sections = XBRLParser().extract_sections_by_type(xbrl_dir)
        for section_id in XBRL_SECTIONS:
            assert section_id in sections, f"section_id '{section_id}' が結果に含まれていない"

    def test_missing_section_is_empty_string(self, xbrl_dir: Path):
        sections = XBRLParser().extract_sections_by_type(xbrl_dir)
        empty_sections = [k for k, v in sections.items() if not v]
        assert len(empty_sections) > 0  # XML に存在しないセクションは空で返る
