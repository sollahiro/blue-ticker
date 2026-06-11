"""分析指標（ウォーターフォール分解等）出力コマンド。

財務指標の一覧表示は summarize コマンドが担い、analyze コマンドは
ROIC・ROE・事業利益前年差のウォーターフォール分解など、要因分解系の
分析指標に特化した出力を行う。
"""

import json
import sys
import logging
from collections.abc import Mapping, Sequence
from typing import Any
import aiohttp
from blue_ticker import __version__
from blue_ticker.infrastructure.helpers import validate_stock_code
from blue_ticker.utils.converters import extract_year_month
from blue_ticker.utils.metrics_access import metric_view
from blue_ticker.constants.api import ANALYZE_DEFAULT_YEARS, EDINET_PREPARE_DEFAULT_YEARS
from .summarize import _ensure_edinet_index, _gross_profit_labels

logger = logging.getLogger(__name__)

INDICATOR_CHOICES = ("business-profit", "roic", "roe")


def _indicator_definitions(latest_view: Mapping[str, object]) -> list[dict[str, Any]]:
    """出力する分析指標の定義（id・表示ラベル・行構成）を返す。

    行ラベルは最新年度の表示ラベル（IFRS金融会社の純収益系など）に追従する。
    """
    _, _, gross_margin_change_label = _gross_profit_labels(latest_view)
    return [
        {
            "id": "business-profit",
            "label": "事業利益前年差分解",
            "rows": [
                ("BusinessProfit", "事業利益 (百万)"),
                ("BusinessProfitChange", "事業利益前年差 (百万)"),
                ("SalesChangeImpact", "  売上差影響"),
                ("GrossMarginChangeImpact", f"  {gross_margin_change_label}"),
                ("SGAChangeImpact", "  販管費差影響"),
                ("BusinessProfitChangeReconciliationDiff", "  分解残差"),
            ],
        },
        {
            "id": "roic",
            "label": "ROICウォーターフォール (NOPATマージン × 投下資本回転率)",
            "rows": [
                ("ROIC", "ROIC (%)"),
                ("NOPATMargin", "NOPATマージン (%)"),
                ("InvestedCapitalTurnover", "投下資本回転率 (倍)"),
                ("ROICDelta", "ROIC前年差 (%pt)"),
                ("ROICMarginEffect", "  NOPATマージン差影響"),
                ("ROICTurnoverEffect", "  投下資本回転率差影響"),
                ("ROICWaterfallReconciliationDiff", "  分解残差"),
            ],
        },
        {
            "id": "roe",
            "label": "ROEウォーターフォール (デュポン3要因)",
            "rows": [
                ("ROE", "ROE (%)"),
                ("NetMargin", "純利益率 (%)"),
                ("AssetTurnover", "総資産回転率 (倍)"),
                ("FinancialLeverage", "財務レバレッジ (倍)"),
                ("ROEDelta", "ROE前年差 (%pt)"),
                ("ROENetMarginEffect", "  純利益率差影響"),
                ("ROEAssetTurnoverEffect", "  総資産回転率差影響"),
                ("ROELeverageEffect", "  財務レバレッジ差影響"),
                ("ROEWaterfallReconciliationDiff", "  分解残差"),
            ],
        },
    ]


def _period_header(year_entry: Mapping[str, Any]) -> str:
    """年度エントリの列見出し（YY/MM 形式）を返す。"""
    fy_end = year_entry.get("fy_end", "不明")
    year, month = extract_year_month(fy_end)
    if year is not None:
        header = f"{str(year)[2:]}/{month:02d}"
    else:
        header = str(fy_end)
    per_type = (year_entry.get("RawData") or {}).get("CurPerType", "FY")
    if per_type == "2Q":
        header += "(2Q)"
    return header


def _build_indicator_output(
    periods: list[dict[str, Any]],
    selected: Sequence[str],
) -> list[dict[str, Any]]:
    """年度別の CalculatedData から指標別の出力構造を組み立てる。"""
    views = [metric_view(p) for p in periods]  # type: ignore[arg-type]
    latest_view = views[-1] if views else {}
    indicators = []
    for definition in _indicator_definitions(latest_view):
        if definition["id"] not in selected:
            continue
        years_out = []
        for period, view in zip(periods, views):
            values = {key: view.get(key) for key, _label in definition["rows"]}
            years_out.append({
                "fy_end": period.get("fy_end"),
                "period_type": (period.get("RawData") or {}).get("CurPerType", "FY"),
                "values": values,
            })
        indicators.append({
            "id": definition["id"],
            "label": definition["label"],
            "rows": definition["rows"],
            "years": years_out,
        })
    return indicators


def _print_indicator_tables(indicators: list[dict[str, Any]], periods: list[dict[str, Any]]) -> None:
    """指標ごとの年度横並びテーブルを表示する。"""
    headers = ["項目 \\ 年度"] + [_period_header(p) for p in periods]
    row_format = "{:<24}" + " {:>10}" * len(periods)
    sep = "-" * (24 + 11 * len(periods))

    for indicator in indicators:
        print(f"\n[{indicator['label']}]", file=sys.stderr)
        print(sep, file=sys.stderr)
        print(row_format.format(*headers), file=sys.stderr)
        print(sep, file=sys.stderr)
        for key, label in indicator["rows"]:
            values = [year["values"].get(key) for year in indicator["years"]]
            if all(v is None for v in values):
                continue
            row = [label]
            for val in values:
                if val is None:
                    row.append(f"{'-':>10}")
                elif isinstance(val, str):
                    row.append(f"{val:>10}")
                else:
                    row.append(f"{val:>10.2f}")
            print(row_format.format(*row), file=sys.stderr)
        print(sep, file=sys.stderr)


async def cmd_analyze(args):
    """分析指標（ウォーターフォール分解等）出力コマンド"""
    from blue_ticker.services.data_service import data_service

    try:
        code = validate_stock_code(args.code)
    except ValueError as e:
        print(f"エラー: {e}", file=sys.stderr)
        return

    requested_years = getattr(args, "years", None)
    if requested_years is not None and requested_years <= 0:
        print("エラー: years には正の整数を指定してください。", file=sys.stderr)
        return

    selected = list(getattr(args, "indicators", None) or INDICATOR_CHOICES)

    try:
        info = data_service.fetch_stock_basic_info(code)
        if not info.get("name"):
            print(f"エラー: 銘柄コード {code} が見つかりません。", file=sys.stderr)
            return

        years_to_analyze = requested_years or ANALYZE_DEFAULT_YEARS

        analysis_cache_key = f"individual_analysis_{code}"
        analysis_cached = data_service.cache_manager.get(analysis_cache_key)
        analysis_cache_valid = (
            not args.no_cache
            and isinstance(analysis_cached, dict)
            and analysis_cached.get("_cache_version") == __version__
        )
        if not analysis_cache_valid:
            if not await _ensure_edinet_index(max(years_to_analyze, EDINET_PREPARE_DEFAULT_YEARS)):
                return

        print(f"\n分析中: {code} {info['name']} ({info['market_name']}) ...", file=sys.stderr)
        print(f"分析対象期間: 直近 {years_to_analyze} 年分", file=sys.stderr)

        result = await data_service.get_raw_analysis_data(
            code, use_cache=not args.no_cache, analysis_years=years_to_analyze,
        )

        if not result or not result.get("metrics"):
            print("エラー: 財務データの取得に失敗しました。APIキーが正しく設定されているか確認してください。", file=sys.stderr)
            return

        years_data = result.get("metrics", {}).get("years", [])
        if not years_data:
            print("エラー: 指標データが見つかりませんでした。", file=sys.stderr)
            return

        periods = list(reversed(years_data))  # 古い順に表示
        indicators = _build_indicator_output(periods, selected)

        if args.format == "json":
            output = {
                "code": result.get("code", code),
                "name": info.get("name"),
                "indicators": [
                    {k: v for k, v in indicator.items() if k != "rows"}
                    for indicator in indicators
                ],
            }
            print(json.dumps(output, indent=2, ensure_ascii=False))
            return

        _print_indicator_tables(indicators, periods)
        print("\n財務指標の一覧は ticker summarize コマンドで表示できます。", file=sys.stderr)

    except ValueError as e:
        print(f"エラー: {e}", file=sys.stderr)
    except aiohttp.ClientError as e:
        print(f"エラー: {e}", file=sys.stderr)
        logger.exception(e)
    finally:
        await data_service.close()
