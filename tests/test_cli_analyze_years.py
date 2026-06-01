"""
cmd_analyze の出力フォーマットテスト

テーブル形式で出力されるフィールドラベルの網羅性と順序を検証する。
"""

import asyncio
from unittest.mock import AsyncMock, patch

from blue_ticker.app.cli import cmd_analyze


class _Args:
    code = "7203"
    years = 1
    format = "table"
    no_cache = False


_MOCK_RESULT = {
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
            }
        ]
    }
}


def test_table_output_contains_required_labels(capsys):
    """テーブル形式で全財務項目ラベルが出力される。"""
    with (
        patch("blue_ticker.services.data_service.data_service.fetch_stock_basic_info") as mock_info,
        patch("blue_ticker.services.data_service.data_service.get_raw_analysis_data") as mock_data,
        patch("blue_ticker.services.data_service.data_service.close", new_callable=AsyncMock),
    ):
        mock_info.return_value = {"name": "トヨタ自動車", "market_name": "プライム"}
        mock_data.return_value = _MOCK_RESULT
        asyncio.run(cmd_analyze(_Args()))

    err = capsys.readouterr().err
    required = [
        "売上高 (百万)",
        "売上総利益 (百万)",
        "粗利率 (%)",
        "営業利益 (百万)",
        "純利益 (百万)",
        "実効税率 (%)",
        "ROE (%)",
        "ROIC (%)",
        "WACC (%)",
        "有利子負債合計 (百万)",
        "現金及び現金同等物 (百万)",
        "営業CF (百万)",
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
    for label in required:
        assert label in err, f"ラベル '{label}' が出力に含まれない"


def test_table_output_labels_in_defined_order(capsys):
    """財務項目ラベルが定義順（売上→利益→CF→株主還元）で出力される。"""
    with (
        patch("blue_ticker.services.data_service.data_service.fetch_stock_basic_info") as mock_info,
        patch("blue_ticker.services.data_service.data_service.get_raw_analysis_data") as mock_data,
        patch("blue_ticker.services.data_service.data_service.close", new_callable=AsyncMock),
    ):
        mock_info.return_value = {"name": "トヨタ自動車", "market_name": "プライム"}
        mock_data.return_value = _MOCK_RESULT
        asyncio.run(cmd_analyze(_Args()))

    err = capsys.readouterr().err
    ordered_labels = [
        "売上高 (百万)",
        "営業利益 (百万)",
        "純利益 (百万)",
        "ROE (%)",
        "ROIC (%)",
        "WACC (%)",
        "現金及び現金同等物 (百万)",
        "営業CF (百万)",
        "EPS (円)",
        "BPS (円)",
        "年間配当 (円)",
        "DocID",
    ]
    positions = [err.index(label) for label in ordered_labels]
    assert positions == sorted(positions), "ラベルの出力順が期待する定義順と異なる"
