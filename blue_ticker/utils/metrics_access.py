"""RawData を正本として分析用の表示値を取り出すヘルパー。"""

from collections.abc import Mapping
from typing import Any

from blue_ticker.constants.financial import MILLION_YEN
from blue_ticker.utils.metrics_types import YearEntry


# RawData の金額ファクトは円単位で保持する。表示・派生計算で百万円単位に
# 変換して扱うフィールドはここに明示する。
RAW_MILLION_FIELDS = frozenset((
    "Sales",
    "OP",
    "NP",
    "NetAssets",
    "CFO",
    "CFI",
    "CashEq",
    "Capex",
    "Buyback",
    "RD",
))


def to_millions_or_none(value: object) -> float | None:
    """円単位の数値を百万円単位へ変換する。"""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) / MILLION_YEN


def raw_metric_millions(raw_data: Mapping[str, Any], key: str) -> float | None:
    """RawData の円単位ファクトを百万円単位で返す。"""
    return to_millions_or_none(raw_data.get(key))


def year_metric_value(year: YearEntry, key: str) -> object:
    """RawData を優先し、なければ CalculatedData から値を返す。"""
    raw_data = dict(year.get("RawData") or {})
    if key in RAW_MILLION_FIELDS:
        raw_value = raw_metric_millions(raw_data, key)
        if raw_value is not None:
            return raw_value
    elif raw_data.get(key) is not None:
        return raw_data.get(key)
    calculated = year.get("CalculatedData") or {}
    return calculated.get(key)


def metric_view(year: YearEntry) -> dict[str, Any]:
    """表示・派生計算用に RawData と CalculatedData を重ねたビューを返す。"""
    calculated = dict(year.get("CalculatedData") or {})
    raw_data = dict(year.get("RawData") or {})
    for key in RAW_MILLION_FIELDS:
        raw_value = raw_metric_millions(raw_data, key)
        if raw_value is not None:
            calculated[key] = raw_value
    sales_label = raw_data.get("SalesLabel")
    if isinstance(sales_label, str) and sales_label:
        calculated["SalesLabel"] = sales_label
    return calculated
