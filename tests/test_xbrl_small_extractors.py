"""
小型 XBRL 抽出モジュール群ユニットテスト

以下の5モジュールを Section + FieldSet ダイレクト構築でテストする。
  - employees.py       : extract_employees
  - net_revenue.py     : extract_net_revenue
  - capital_expenditure.py : extract_capital_expenditure
  - research_development.py : extract_research_development
  - share_buyback.py   : extract_share_buyback
"""

import pytest

from blue_ticker.analysis.capital_expenditure import extract_capital_expenditure
from blue_ticker.analysis.employees import extract_employees
from blue_ticker.analysis.net_revenue import extract_net_revenue
from blue_ticker.analysis.research_development import extract_research_development
from blue_ticker.analysis.sections import (
    CashFlowSection,
    EmployeeSection,
    IncomeStatementSection,
)
from blue_ticker.analysis.share_buyback import extract_share_buyback


# ---------------------------------------------------------------------------
# テストヘルパー
# ---------------------------------------------------------------------------

def _fs(*args: tuple[str, float | None, float | None]) -> dict:
    """(tag, current, prior) → FieldSet 辞書"""
    return {tag: {"current": current, "prior": prior} for tag, current, prior in args}


def _income_section(field_set: dict, std: str = "J-GAAP") -> IncomeStatementSection:
    return IncomeStatementSection(field_set, std)


def _cf_section(field_set: dict, std: str = "J-GAAP") -> CashFlowSection:
    return CashFlowSection(field_set, std)


def _employee_section(
    field_set: dict,
    tag_elements: dict | None = None,
    std: str = "J-GAAP",
) -> EmployeeSection:
    return EmployeeSection(field_set, std, tag_elements or {})


# ---------------------------------------------------------------------------
# extract_employees
# ---------------------------------------------------------------------------

class TestExtractEmployees:
    def test_consolidated_direct(self):
        tag_elements = {
            "NumberOfEmployees": {
                "CurrentYearInstant": 5000.0,
                "Prior1YearInstant": 4800.0,
            }
        }
        fs = _fs(("NumberOfEmployees", 5000.0, 4800.0))
        section = _employee_section(fs, tag_elements)
        result = extract_employees(section)
        assert result["current"] == 5000.0
        assert result["prior"] == 4800.0
        assert result["method"] == "direct"

    def test_fallback_to_group_employees(self):
        tag_elements = {
            "NumberOfGroupEmployees": {
                "CurrentYearInstant": 3000.0,
            }
        }
        fs = _fs(("NumberOfGroupEmployees", 3000.0, None))
        section = _employee_section(fs, tag_elements)
        result = extract_employees(section)
        assert result["current"] == 3000.0
        assert result["method"] == "direct"

    def test_not_found(self):
        section = _employee_section({})
        result = extract_employees(section)
        assert result["current"] is None
        assert result["method"] == "not_found"
        assert result["scope"] == "unknown"

    def test_scope_consolidated_when_instant_context(self):
        tag_elements = {
            "NumberOfEmployees": {
                "CurrentYearInstant": 5000.0,
            }
        }
        fs = _fs(("NumberOfEmployees", 5000.0, None))
        section = _employee_section(fs, tag_elements)
        result = extract_employees(section)
        assert result["scope"] == "consolidated"


# ---------------------------------------------------------------------------
# extract_net_revenue
# ---------------------------------------------------------------------------

class TestExtractNetRevenue:
    def test_net_revenue_found(self):
        fs = _fs(("NetRevenueIFRS", 100_000.0, 90_000.0))
        section = _income_section(fs, "IFRS")
        result = extract_net_revenue(section)
        assert result["net_revenue"] == 100_000.0
        assert result["net_revenue_prior"] == 90_000.0
        assert result["found"] is True

    def test_business_profit_found(self):
        fs = _fs(("BusinessProfitIFRSSummaryOfBusinessResults", 20_000.0, 18_000.0))
        section = _income_section(fs, "IFRS")
        result = extract_net_revenue(section)
        assert result["business_profit"] == 20_000.0
        assert result["found"] is True

    def test_both_not_found(self):
        section = _income_section({}, "IFRS")
        result = extract_net_revenue(section)
        assert result["net_revenue"] is None
        assert result["business_profit"] is None
        assert result["found"] is False

    def test_found_flag_requires_current_value(self):
        # prior のみで current がない場合は found=False
        fs = _fs(("NetRevenueIFRS", None, 90_000.0))
        section = _income_section(fs, "IFRS")
        result = extract_net_revenue(section)
        assert result["found"] is False


# ---------------------------------------------------------------------------
# extract_capital_expenditure
# ---------------------------------------------------------------------------

class TestExtractCapitalExpenditure:
    def test_overview_method_jgaap(self):
        fs = _fs(("CapitalExpendituresOverviewOfCapitalExpendituresEtc", 5_000_000.0, 4_000_000.0))
        section = _cf_section(fs, "J-GAAP")
        result = extract_capital_expenditure(section)
        assert result["current"] == 5_000_000.0
        assert result["method"] == "overview"
        assert result["accounting_standard"] == "J-GAAP"

    def test_cf_investing_jgaap_negates_value(self):
        # J-GAAP CF は負値で記録 → 正値に変換
        fs = _fs(("PurchaseOfPropertyPlantAndEquipmentInvCF", -3_000_000.0, -2_500_000.0))
        section = _cf_section(fs, "J-GAAP")
        result = extract_capital_expenditure(section)
        assert result["current"] == 3_000_000.0
        assert result["prior"] == 2_500_000.0
        assert result["method"] == "cf_investing"

    def test_cf_investing_ifrs_negates_value(self):
        fs = _fs(("AcquisitionOfPropertyPlantAndEquipmentInvCFIFRS", -4_000_000.0, None))
        section = _cf_section(fs, "IFRS")
        result = extract_capital_expenditure(section)
        assert result["current"] == 4_000_000.0
        assert result["method"] == "cf_investing"
        assert result["accounting_standard"] == "IFRS"

    def test_not_found(self):
        section = _cf_section({}, "J-GAAP")
        result = extract_capital_expenditure(section)
        assert result["current"] is None
        assert result["method"] == "not_found"


# ---------------------------------------------------------------------------
# extract_research_development
# ---------------------------------------------------------------------------

class TestExtractResearchDevelopment:
    def test_common_tag_found(self):
        fs = _fs(
            ("ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities", 1_000_000.0, 900_000.0)
        )
        section = _income_section(fs, "J-GAAP")
        result = extract_research_development(section)
        assert result["current"] == 1_000_000.0
        assert result["method"] == "direct"

    def test_jgaap_fallback(self):
        # 共通タグなし → J-GAAP フォールバック
        fs = _fs(("ResearchAndDevelopmentExpenses", 800_000.0, 750_000.0))
        section = _income_section(fs, "J-GAAP")
        result = extract_research_development(section)
        assert result["current"] == 800_000.0
        assert result["method"] == "direct"

    def test_ifrs_fallback(self):
        fs = _fs(("ResearchAndDevelopmentExpensesIFRS", 600_000.0, None))
        section = _income_section(fs, "IFRS")
        result = extract_research_development(section)
        assert result["current"] == 600_000.0
        assert result["accounting_standard"] == "IFRS"

    def test_not_found(self):
        section = _income_section({}, "J-GAAP")
        result = extract_research_development(section)
        assert result["current"] is None
        assert result["method"] == "not_found"


# ---------------------------------------------------------------------------
# extract_share_buyback
# ---------------------------------------------------------------------------

class TestExtractShareBuyback:
    def test_jgaap_negates_value(self):
        # CF計算書は負値 → 正値に変換
        fs = _fs(("PurchaseOfTreasuryStockFinCF", -500_000.0, -400_000.0))
        section = _cf_section(fs, "J-GAAP")
        result = extract_share_buyback(section)
        assert result["current"] == 500_000.0
        assert result["prior"] == 400_000.0
        assert result["method"] == "cf_financing"
        assert result["accounting_standard"] == "J-GAAP"

    def test_ifrs_tag(self):
        fs = _fs(("PaymentsForPurchaseOfTreasurySharesFinCFIFRS", -300_000.0, None))
        section = _cf_section(fs, "IFRS")
        result = extract_share_buyback(section)
        assert result["current"] == 300_000.0
        assert result["accounting_standard"] == "IFRS"

    def test_not_found(self):
        section = _cf_section({}, "J-GAAP")
        result = extract_share_buyback(section)
        assert result["current"] is None
        assert result["method"] == "not_found"

    def test_none_current_stays_none_after_negate(self):
        fs = _fs(("PurchaseOfTreasuryStockFinCF", None, -200_000.0))
        section = _cf_section(fs, "J-GAAP")
        result = extract_share_buyback(section)
        assert result["current"] is None
        assert result["prior"] == 200_000.0
