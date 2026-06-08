"""extract_cash_flow の基本動作テスト。

J-GAAP/IFRS/US-GAAP 各タグで CFO・CFI を取得できること、
タグが存在しない場合は None を返すことを検証する。
"""

from blue_ticker.analysis.cash_flow import extract_cash_flow
from blue_ticker.analysis.sections import CashFlowSection


def _cf(field_set: dict, std: str = "J-GAAP") -> CashFlowSection:
    return CashFlowSection(field_set, std)


def _fs(*args: tuple[str, float | None, float | None]) -> dict:
    return {tag: {"current": current, "prior": prior} for tag, current, prior in args}


class TestExtractCashFlow:
    def test_jgaap_cfo_and_cfi(self):
        fs = _fs(
            ("NetCashProvidedByUsedInOperatingActivities", 500_000.0, 450_000.0),
            ("NetCashProvidedByUsedInInvestingActivities", -300_000.0, -250_000.0),
        )
        result = extract_cash_flow(_cf(fs, "J-GAAP"))
        assert result["cfo"]["current"] == 500_000.0
        assert result["cfo"]["prior"] == 450_000.0
        assert result["cfi"]["current"] == -300_000.0
        assert result["cfi"]["prior"] == -250_000.0
        assert result["accounting_standard"] == "J-GAAP"

    def test_jgaap_cfi_spelling_variant(self):
        # NetCashProvidedByUsedInInvestmentActivities（表記ゆれ）でも取得できる
        fs = _fs(("NetCashProvidedByUsedInInvestmentActivities", -200_000.0, None))
        result = extract_cash_flow(_cf(fs, "J-GAAP"))
        assert result["cfi"]["current"] == -200_000.0

    def test_ifrs_cfo_and_cfi(self):
        fs = _fs(
            ("CashFlowsFromUsedInOperationsIFRS", 600_000.0, 580_000.0),
            ("CashFlowsUsedInInvestingActivitiesIFRS", -200_000.0, -180_000.0),
        )
        result = extract_cash_flow(_cf(fs, "IFRS"))
        assert result["cfo"]["current"] == 600_000.0
        assert result["cfi"]["current"] == -200_000.0
        assert result["accounting_standard"] == "IFRS"

    def test_not_found_returns_none(self):
        result = extract_cash_flow(_cf({}, "J-GAAP"))
        assert result["cfo"]["current"] is None
        assert result["cfo"]["prior"] is None
        assert result["cfi"]["current"] is None
        assert result["cfi"]["prior"] is None

    def test_cfo_found_cfi_missing(self):
        fs = _fs(("NetCashProvidedByUsedInOperatingActivities", 500_000.0, None))
        result = extract_cash_flow(_cf(fs, "J-GAAP"))
        assert result["cfo"]["current"] == 500_000.0
        assert result["cfi"]["current"] is None

    def test_accounting_standard_propagated(self):
        fs = _fs(("CashFlowsFromUsedInOperatingActivitiesIFRS", 100_000.0, None))
        result = extract_cash_flow(_cf(fs, "IFRS"))
        assert result["accounting_standard"] == "IFRS"

    def test_prior_only_when_current_none(self):
        fs = _fs(("NetCashProvidedByUsedInOperatingActivities", None, 450_000.0))
        result = extract_cash_flow(_cf(fs, "J-GAAP"))
        assert result["cfo"]["current"] is None
        assert result["cfo"]["prior"] == 450_000.0
