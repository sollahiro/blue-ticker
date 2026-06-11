"""
cmd_analyze（分析指標出力）のテスト

ウォーターフォール分解指標の JSON 構造とテーブル出力ラベルを検証する。
"""

import asyncio
import json
from unittest.mock import AsyncMock, patch

from blue_ticker.app.cli import cmd_analyze


class _Args:
    code = "7203"
    years = 2
    format = "json"
    no_cache = False
    indicators = None


_MOCK_RESULT = {
    "code": "72030",
    "metrics": {
        "years": [
            {
                "fy_end": "2024-03-31",
                "RawData": {"CurPerType": "FY"},
                "CalculatedData": {
                    "ROIC": 9.5,
                    "NOPATMargin": 8.0,
                    "InvestedCapitalTurnover": 1.2,
                    "ROICDelta": 1.0,
                    "ROICMarginEffect": 0.6,
                    "ROICTurnoverEffect": 0.4,
                    "ROICWaterfallReconciliationDiff": 0.0,
                    "ROE": 14.0,
                    "NetMargin": 10.0,
                    "AssetTurnover": 0.8,
                    "FinancialLeverage": 1.8,
                    "ROEDelta": 0.5,
                    "ROENetMarginEffect": 0.3,
                    "ROEAssetTurnoverEffect": 0.1,
                    "ROELeverageEffect": 0.1,
                    "ROEWaterfallReconciliationDiff": 0.0,
                    "BusinessProfit": 5_000.0,
                    "BusinessProfitChange": 1_000.0,
                    "SalesChangeImpact": 600.0,
                    "GrossMarginChangeImpact": 300.0,
                    "SGAChangeImpact": 100.0,
                    "BusinessProfitChangeReconciliationDiff": 0.0,
                },
            },
            {
                "fy_end": "2023-03-31",
                "RawData": {"CurPerType": "FY"},
                "CalculatedData": {
                    "ROIC": 8.5,
                    "NOPATMargin": 7.5,
                    "InvestedCapitalTurnover": 1.13,
                    "ROE": 13.5,
                },
            },
        ]
    },
}


def _run(args) -> None:
    with (
        patch("blue_ticker.services.data_service.data_service.fetch_stock_basic_info") as mock_info,
        patch("blue_ticker.services.data_service.data_service.get_raw_analysis_data") as mock_data,
        patch("blue_ticker.services.data_service.data_service.close", new_callable=AsyncMock),
        patch("blue_ticker.app.cli.analyze._ensure_edinet_index", new_callable=AsyncMock, return_value=True),
    ):
        mock_info.return_value = {"name": "トヨタ自動車", "market_name": "プライム"}
        mock_data.return_value = _MOCK_RESULT
        asyncio.run(cmd_analyze(args))


def test_json_output_contains_all_indicators(capsys):
    """JSON形式で3指標すべてが年度昇順で出力される。"""
    _run(_Args())

    out = capsys.readouterr().out
    data = json.loads(out)
    assert data["code"] == "72030"
    assert data["name"] == "トヨタ自動車"

    indicator_ids = [indicator["id"] for indicator in data["indicators"]]
    assert indicator_ids == ["business-profit", "roic", "roe"]

    roic = next(i for i in data["indicators"] if i["id"] == "roic")
    fy_ends = [year["fy_end"] for year in roic["years"]]
    assert fy_ends == ["2023-03-31", "2024-03-31"]
    assert roic["years"][-1]["values"]["ROICDelta"] == 1.0
    assert roic["years"][-1]["values"]["ROICMarginEffect"] == 0.6


def test_json_output_respects_indicator_selection(capsys):
    """--indicators で指定した指標のみ出力される。"""
    args = _Args()
    args.indicators = ["roe"]
    _run(args)

    data = json.loads(capsys.readouterr().out)
    assert [indicator["id"] for indicator in data["indicators"]] == ["roe"]


def test_table_output_contains_waterfall_labels(capsys):
    """テーブル形式でウォーターフォール分解の行ラベルが出力される。"""
    args = _Args()
    args.format = "table"
    _run(args)

    err = capsys.readouterr().err
    required = [
        "[事業利益前年差分解]",
        "事業利益前年差 (百万)",
        "  売上差影響",
        "  粗利率差影響",
        "  販管費差影響",
        "[ROICウォーターフォール (NOPATマージン × 投下資本回転率)]",
        "ROIC前年差 (%pt)",
        "  NOPATマージン差影響",
        "  投下資本回転率差影響",
        "[ROEウォーターフォール (デュポン3要因)]",
        "ROE前年差 (%pt)",
        "  純利益率差影響",
        "  総資産回転率差影響",
        "  財務レバレッジ差影響",
    ]
    for label in required:
        assert label in err, f"ラベル '{label}' が出力に含まれない"


def test_invalid_years_rejected(capsys):
    """years に 0 以下を指定するとエラーになる。"""
    args = _Args()
    args.years = 0
    asyncio.run(cmd_analyze(args))

    err = capsys.readouterr().err
    assert "years には正の整数を指定してください" in err
