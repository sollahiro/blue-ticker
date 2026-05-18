import asyncio
import sys
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

# プロジェクトルートを追加
project_root = Path(__file__).parent.parent
sys.path.insert(0, str(project_root))

# Mock missing dependencies before imports
sys.modules["keyring"] = MagicMock()
sys.modules["questionary"] = MagicMock()

from blue_ticker.app.cli import cmd_analyze


def test_cmd_analyze_multi_year():
    # Mock args
    class MockArgs:
        code = "7203"
        years = 3
        format = "table"
        no_cache = False

    args = MockArgs()

    # Mock data_service
    mock_result = {
        "metrics": {
            "years": [
                {
                    "fy_end": "20240331",
                    "CalculatedData": {
                        "Sales": 1000000,
                        "OP": 100000,
                        "ROE": 15.0,
                    },
                },
                {
                    "fy_end": "20230331",
                    "CalculatedData": {
                        "Sales": 900000,
                        "OP": 90000,
                        "ROE": 14.0,
                    },
                },
                {
                    "fy_end": "20220331",
                    "CalculatedData": {
                        "Sales": 800000,
                        "OP": 80000,
                        "ROE": 13.0,
                    },
                },
            ]
        }
    }

    with (
        patch("blue_ticker.services.data_service.data_service.fetch_stock_basic_info") as mock_info,
        patch("blue_ticker.services.data_service.data_service.get_raw_analysis_data") as mock_get_data,
    ):
        mock_info.return_value = {"name": "トヨタ自動車", "market_name": "プライム"}
        mock_get_data.return_value = mock_result

        asyncio.run(cmd_analyze(args))


def test_cmd_analyze_table_shows_net_profit_and_cash_equivalents(capsys):
    class MockArgs:
        code = "7203"
        years = 1
        format = "table"
        no_cache = False

    args = MockArgs()
    mock_result = {
        "metrics": {
            "years": [
                {
                    "fy_end": "20240331",
                    "RawData": {
                        "CurPerType": "FY",
                        "EPS": 320.5,
                        "BPS": 2_100.25,
                        "ShOutFY": 1_234_567,
                        "DivTotalAnn": 12_000_000_000,
                        "DivAnn": 80.0,
                        "Div2Q": 40.0,
                    },
                    "CalculatedData": {
                        "Sales": 45_095_325.0,
                        "OrderIntake": 50_000_000.0,
                        "OrderBacklog": 60_000_000.0,
                        "GrossProfit": 12_345_678.0,
                        "GrossProfitMargin": 27.38,
                        "SellingGeneralAdministrativeExpenses": 6_992_744.0,
                        "OP": 5_352_934.0,
                        "OperatingMargin": 11.87,
                        "AdjustedOperatingProfit": 5_352_934.0,
                        "AdjustedOperatingMargin": 11.87,
                        "NP": 4_944_933.0,
                        "EffectiveTaxRate": 30.1,
                        "NOPAT": 3_741_700.0,
                        "OperatingProfitChange": 1_000.0,
                        "SalesChangeImpact": 2_000.0,
                        "GrossMarginChangeImpact": 3_000.0,
                        "SGAChangeImpact": -4_000.0,
                        "ROE": 14.0,
                        "ROIC": 9.5,
                        "CostOfEquity": 7.1,
                        "CostOfDebt": 1.2,
                        "WACC": 5.4,
                        "InterestBearingDebt": 30_000_000.0,
                        "InterestExpense": 123_000.0,
                        "TotalAssets": 90_000_000.0,
                        "CurrentAssets": 40_000_000.0,
                        "NonCurrentAssets": 50_000_000.0,
                        "CurrentLiabilities": 20_000_000.0,
                        "NonCurrentLiabilities": 25_000_000.0,
                        "NetAssets": 45_000_000.0,
                        "CashEq": 9_412_060.0,
                        "CFO": 4_000_000.0,
                        "CFI": -2_000_000.0,
                        "CFC": 2_000_000.0,
                        "DepreciationAmortization": 1_500_000.0,
                        "OtherCashConversionGap": -2_852_934.0,
                        "PayoutRatio": 25.0,
                        "Employees": 100_000,
                        "DocID": "S100TEST",
                    },
                },
            ]
        }
    }

    with (
        patch("blue_ticker.services.data_service.data_service.fetch_stock_basic_info") as mock_info,
        patch("blue_ticker.services.data_service.data_service.get_raw_analysis_data") as mock_get_data,
        patch("blue_ticker.services.data_service.data_service.close", new_callable=AsyncMock),
    ):
        mock_info.return_value = {"name": "トヨタ自動車", "market_name": "プライム"}
        mock_get_data.return_value = mock_result

        asyncio.run(cmd_analyze(args))

    captured = capsys.readouterr()
    assert "純利益 (百万)" in captured.err
    assert "現金及び現金同等物 (百万)" in captured.err
    assert "EPS (円)" in captured.err
    assert "BPS (円)" in captured.err
    assert "期末発行済株式数 (株)" in captured.err
    assert "年間配当総額 (百万)" in captured.err
    assert "年間配当 (円)" in captured.err
    assert "中間配当 (円)" in captured.err
    assert "4944933.00" in captured.err
    assert "9412060.00" in captured.err
    assert "320.50" in captured.err
    assert "2100.25" in captured.err
    assert "1,234,567" in captured.err
    assert "12000.00" in captured.err
    labels_in_order = [
        "売上高 (百万)",
        "受注高 (百万)",
        "受注残高 (百万)",
        "売上総利益 (百万)",
        "粗利率 (%)",
        "販管費 (百万)",
        "営業利益 (百万)",
        "営業利益率 (%)",
        "コア営業利益 (百万)",
        "コア営業利益率 (%)",
        "NOPAT (百万)",
        "純利益 (百万)",
        "実効税率 (%)",
        "コア営業利益前年差",
        "売上差影響",
        "粗利率差影響",
        "販管費差影響",
        "ROE (%)",
        "ROIC (%)",
        "株主資本コスト (%)",
        "負債コスト (%)",
        "WACC (%)",
        "投下資本 (百万)",
        "有利子負債合計 (百万)",
        "支払利息 (百万)",
        "総資産 (百万)",
        "流動資産 (百万)",
        "固定資産 (百万)",
        "流動負債 (百万)",
        "固定負債 (百万)",
        "純資産 (百万)",
        "現金及び現金同等物 (百万)",
        "営業CF (百万)",
        "減価償却費 (百万)",
        "その他現金化差分 (百万)",
        "投資CF (百万)",
        "フリーCF (百万)",
        "EPS (円)",
        "BPS (円)",
        "年間配当 (円)",
        "中間配当 (円)",
        "年間配当総額 (百万)",
        "配当性向 (%)",
        "期末発行済株式数 (株)",
        "従業員数 (人)",
        "DocID",
    ]
    positions = [captured.err.index(label) for label in labels_in_order]
    assert positions == sorted(positions)


if __name__ == "__main__":
    test_cmd_analyze_multi_year()
