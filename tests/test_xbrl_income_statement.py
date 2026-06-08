"""extract_income_statement の基本動作テスト。

J-GAAP/IFRS/US-GAAP 各タグで売上高・営業利益・純利益を取得できること、
ordinary_income フォールバック・sales_label 付与・not_found を検証する。
"""

from blue_ticker.analysis.income_statement import extract_income_statement
from blue_ticker.analysis.sections import IncomeStatementSection


def _is(field_set: dict, std: str = "J-GAAP") -> IncomeStatementSection:
    return IncomeStatementSection(field_set, std)


def _fs(*args: tuple[str, float | None, float | None]) -> dict:
    return {tag: {"current": current, "prior": prior} for tag, current, prior in args}


class TestExtractIncomeStatement:
    def test_jgaap_basic(self):
        fs = _fs(
            ("NetSales", 1_000_000.0, 900_000.0),
            ("OperatingIncomeLoss", 100_000.0, 80_000.0),
            ("ProfitLossAttributableToOwnersOfParent", 60_000.0, 50_000.0),
        )
        result = extract_income_statement(_is(fs, "J-GAAP"))
        assert result["sales"] == 1_000_000.0
        assert result["sales_prior"] == 900_000.0
        assert result["operating_profit"] == 100_000.0
        assert result["operating_profit_prior"] == 80_000.0
        assert result["net_profit"] == 60_000.0
        assert result["net_profit_prior"] == 50_000.0
        assert result["accounting_standard"] == "J-GAAP"

    def test_ordinary_income_fallback_when_no_operating_profit(self):
        # 営業利益タグなし・前期もなし → 経常利益にフォールバック
        fs = _fs(
            ("NetSales", 1_000_000.0, None),
            ("OrdinaryIncome", 90_000.0, None),
        )
        result = extract_income_statement(_is(fs, "J-GAAP"))
        assert result["operating_profit"] == 90_000.0

    def test_operating_profit_takes_precedence_over_ordinary_income(self):
        fs = _fs(
            ("OperatingIncomeLoss", 100_000.0, None),
            ("OrdinaryIncome", 90_000.0, None),
        )
        result = extract_income_statement(_is(fs, "J-GAAP"))
        assert result["operating_profit"] == 100_000.0

    def test_ifrs_tags(self):
        fs = _fs(
            ("RevenueIFRS", 2_000_000.0, 1_900_000.0),
            ("OperatingProfitLossIFRS", 200_000.0, None),
            ("ProfitLossAttributableToOwnersOfParentIFRS", 120_000.0, None),
        )
        result = extract_income_statement(_is(fs, "IFRS"))
        assert result["sales"] == 2_000_000.0
        assert result.get("sales_label") == "売上収益"
        assert result["operating_profit"] == 200_000.0
        assert result["accounting_standard"] == "IFRS"

    def test_sales_label_ordinary_revenue(self):
        # OrdinaryIncomeBNK タグ → 経常収益
        fs = _fs(("OrdinaryIncomeBNK", 500_000.0, None))
        result = extract_income_statement(_is(fs, "J-GAAP"))
        assert result.get("sales_label") == "経常収益"

    def test_sales_label_operating_revenue(self):
        # OperatingRevenue1SummaryOfBusinessResults → 営業収益
        fs = _fs(("OperatingRevenue1SummaryOfBusinessResults", 300_000.0, None))
        result = extract_income_statement(_is(fs, "J-GAAP"))
        assert result.get("sales_label") == "営業収益"

    def test_sales_label_default_net_sales(self):
        fs = _fs(("NetSales", 1_000_000.0, None))
        result = extract_income_statement(_is(fs, "J-GAAP"))
        assert result.get("sales_label") == "売上高"

    def test_sales_label_absent_when_sales_none(self):
        # 売上高が取得できない場合は sales_label を付与しない
        result = extract_income_statement(_is({}, "J-GAAP"))
        assert "sales_label" not in result

    def test_not_found_all_none(self):
        result = extract_income_statement(_is({}, "J-GAAP"))
        assert result["sales"] is None
        assert result["operating_profit"] is None
        assert result["net_profit"] is None
        assert result["method"] == "not_found"

    def test_method_includes_found_fields(self):
        fs = _fs(
            ("NetSales", 1_000_000.0, None),
            ("OperatingIncomeLoss", 100_000.0, None),
        )
        result = extract_income_statement(_is(fs, "J-GAAP"))
        fields = result["method"].split(",")
        assert "sales" in fields
        assert "operating_profit" in fields
        assert "net_profit" not in fields

    def test_ordinary_income_fallback_blocked_by_prior_only_op(self):
        # OperatingIncomeLoss が前期のみ存在する場合は経常利益フォールバックを使わない。
        # 前期 OP があれば通常の事業会社と判定し、OrdinaryIncome との混在を防ぐ意図。
        fs = _fs(
            ("OperatingIncomeLoss", None, 80_000.0),
            ("OrdinaryIncome", 90_000.0, None),
        )
        result = extract_income_statement(_is(fs, "J-GAAP"))
        assert result["operating_profit"] is None
        assert result["operating_profit_prior"] == 80_000.0

    def test_prior_values_included(self):
        fs = _fs(("NetSales", None, 900_000.0))
        result = extract_income_statement(_is(fs, "J-GAAP"))
        assert result["sales"] is None
        assert result["sales_prior"] == 900_000.0
