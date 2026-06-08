"""
個別詳細分析モジュール

個別銘柄の詳細分析を実行します。
EdinetFetcher を中心に財務データとEDINET補完指標を組み立てます。
"""

import logging
import asyncio
from typing import Any, cast
from collections.abc import Callable, Iterator, Sequence

from blue_ticker.api.edinet_client import EdinetAPIClient
from blue_ticker.infrastructure.settings import settings_store
from blue_ticker.constants.financial import PERCENT, MILLION_YEN, NOPAT_FALLBACK_TAX_RATE, NOPAT_MIN_NORMAL_TAX_RATE, NOPAT_MAX_NORMAL_TAX_RATE
from blue_ticker.analysis.calculator import calculate_metrics_flexible
from blue_ticker.utils.cache import CacheManager
from blue_ticker.utils.cache_paths import edinet_cache_dir
from blue_ticker.utils.operating_profit_change import (
    apply_operating_profit_change_from_xbrl,
    apply_operating_profit_change_to_years,
)
from blue_ticker.utils.roe_waterfall import apply_roe_waterfall_to_years
from blue_ticker.utils.roic_waterfall import (
    apply_roic_waterfall_from_xbrl,
    apply_roic_waterfall_to_years,
)
from blue_ticker.utils.metrics_access import year_metric_value
from blue_ticker.utils.metrics_types import CalculatedData, MetricSource, RawXbrlExtraction, YearEntry

from .edinet_fetcher import EdinetFetcher, XbrlBuildContext

logger = logging.getLogger(__name__)


def _fy_end_key(year: YearEntry) -> str:
    fy_end = year.get("fy_end")
    return fy_end.replace("-", "") if fy_end is not None else ""


def _set_metric_source(
    cd: CalculatedData,
    metric: str,
    *,
    source: str,
    unit: str,
    method: str | None = None,
    doc_id: str | None = None,
    label: str | None = None,
) -> None:
    sources = cd.setdefault("MetricSources", {})
    item: MetricSource = {"source": source, "unit": unit}
    if method is not None:
        item["method"] = method
    if doc_id is not None:
        item["docID"] = doc_id
    if label is not None:
        item["label"] = label
    sources[metric] = item


def _metric_doc_id(result: dict[str, Any]) -> str | None:
    doc_id = result.get("docID")
    return doc_id if isinstance(doc_id, str) and doc_id else None


def _to_millions_or_none(value: float | None) -> float | None:
    return value / MILLION_YEN if value is not None else None


def _year_metric_float(year: YearEntry, key: str) -> float | None:
    value = year_metric_value(year, key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def _raw_by_year(all_metrics: dict[str, dict[str, Any]]) -> dict[str, RawXbrlExtraction]:
    """抽出器ごとの結果を年度別のXBRL生値へ正規化する。

    この段階では金額を円単位のまま保持し、百万円変換や比率計算は
    CalculatedData への反映段階に閉じ込める。
    """
    by_year: dict[str, RawXbrlExtraction] = {}

    def raw_for(fy_end_key: str) -> RawXbrlExtraction:
        if fy_end_key not in by_year:
            by_year[fy_end_key] = {}
        return by_year[fy_end_key]

    for fy_end_key, doc_id in all_metrics.get("doc_ids", {}).items():
        if isinstance(doc_id, str) and doc_id:
            raw_for(fy_end_key)["doc_id"] = doc_id

    for fy_end_key, doc_id in all_metrics.get("amendment_doc_ids", {}).items():
        if isinstance(doc_id, str) and doc_id:
            raw_for(fy_end_key)["amendment_doc_id"] = doc_id

    for fy_end_key, gp in all_metrics.get("gp", {}).items():
        raw = raw_for(fy_end_key)
        if (doc_id := _metric_doc_id(gp)) is not None and "doc_id" not in raw:
            raw["doc_id"] = doc_id
        raw["gross_profit"] = gp.get("current")
        raw["gross_profit_method"] = str(gp.get("method", "unknown"))
        gp_method = gp.get("method")
        if gp_method == "business_gross_profit":
            raw["gross_profit_label"] = "業務粗利益"
        elif gp_method == "operating_gross_profit":
            raw["gross_profit_label"] = "営業総利益"
        else:
            raw["gross_profit_label"] = None

    for fy_end_key, op in all_metrics.get("op", {}).items():
        raw = raw_for(fy_end_key)
        if (doc_id := _metric_doc_id(op)) is not None and "doc_id" not in raw:
            raw["doc_id"] = doc_id
        raw["operating_profit"] = op.get("current")
        raw["operating_profit_method"] = str(op.get("method", "unknown"))
        raw["operating_profit_label"] = str(op.get("label", "営業利益"))
        raw["selling_general_administrative_expenses"] = op.get("current_sga")
        raw["selling_general_administrative_expenses_method"] = "direct" if op.get("current_sga") is not None else "derived"
        if op.get("current_sales") is not None:
            raw["sales"] = op.get("current_sales")
            raw["sales_label"] = "経常収益"

    for fy_end_key, nr in all_metrics.get("nr", {}).items():
        if not nr.get("found"):
            continue
        raw = raw_for(fy_end_key)
        if (doc_id := _metric_doc_id(nr)) is not None and "doc_id" not in raw:
            raw["doc_id"] = doc_id
        raw["net_revenue"] = nr.get("net_revenue")
        raw["business_profit"] = nr.get("business_profit")

    for fy_end_key, ibd in all_metrics.get("ibd", {}).items():
        raw = raw_for(fy_end_key)
        if (doc_id := _metric_doc_id(ibd)) is not None and "doc_id" not in raw:
            raw["doc_id"] = doc_id
        raw["interest_bearing_debt"] = ibd.get("current")
        raw["ibd_components"] = [
            {
                "label": c["label"],
                "current": c.get("current"),
                "prior": c.get("prior"),
            }
            for c in ibd.get("components", [])
        ]
        raw["ibd_method"] = str(ibd.get("method", "unknown"))
        raw["ibd_accounting_standard"] = str(ibd.get("accounting_standard", "unknown"))

    for fy_end_key, bs in all_metrics.get("bs", {}).items():
        raw = raw_for(fy_end_key)
        if (doc_id := _metric_doc_id(bs)) is not None and "doc_id" not in raw:
            raw["doc_id"] = doc_id
        raw["current_assets"] = bs.get("current_assets")
        raw["total_assets"] = bs.get("total_assets")
        raw["non_current_assets"] = bs.get("non_current_assets")
        raw["current_liabilities"] = bs.get("current_liabilities")
        raw["non_current_liabilities"] = bs.get("non_current_liabilities")
        raw["net_assets"] = bs.get("net_assets")
        raw["prior_net_assets"] = bs.get("prior_net_assets")
        raw["balance_sheet_components"] = [
            {
                "label": c["label"],
                "current": c.get("current"),
                "prior": c.get("prior"),
            }
            for c in bs.get("components", [])
        ]
        raw["balance_sheet_method"] = str(bs.get("method", "unknown"))
        raw["balance_sheet_accounting_standard"] = str(bs.get("accounting_standard", "unknown"))

    for fy_end_key, ie in all_metrics.get("ie", {}).items():
        raw = raw_for(fy_end_key)
        if (doc_id := _metric_doc_id(ie)) is not None and "doc_id" not in raw:
            raw["doc_id"] = doc_id
        raw["interest_expense"] = ie.get("current")
        raw["interest_expense_method"] = str(ie.get("method", "unknown"))

    for fy_end_key, tax in all_metrics.get("tax", {}).items():
        if tax.get("method") not in ("computed", "usgaap_html"):
            continue
        raw = raw_for(fy_end_key)
        if (doc_id := _metric_doc_id(tax)) is not None and "doc_id" not in raw:
            raw["doc_id"] = doc_id
        raw["pretax_income"] = tax.get("pretax_income")
        raw["income_tax"] = tax.get("income_tax")
        raw["effective_tax_rate"] = tax.get("effective_tax_rate")
        raw["tax_method"] = str(tax.get("method", "unknown"))

    for fy_end_key, emp in all_metrics.get("emp", {}).items():
        if emp.get("current") is None:
            continue
        raw = raw_for(fy_end_key)
        if (doc_id := _metric_doc_id(emp)) is not None and "doc_id" not in raw:
            raw["doc_id"] = doc_id
        raw["employees"] = int(emp["current"])
        raw["employees_method"] = str(emp.get("method", "unknown"))
        raw["employees_scope"] = str(emp.get("scope", "unknown"))

    for fy_end_key, ob in all_metrics.get("ob", {}).items():
        raw = raw_for(fy_end_key)
        if (doc_id := _metric_doc_id(ob)) is not None and "doc_id" not in raw:
            raw["doc_id"] = doc_id
        raw["order_intake"] = ob.get("order_intake")
        raw["order_backlog"] = ob.get("order_backlog")
        raw["order_book_method"] = str(ob.get("method", "unknown"))

    for fy_end_key, ppe in all_metrics.get("ppe", {}).items():
        raw = raw_for(fy_end_key)
        if (doc_id := _metric_doc_id(ppe)) is not None and "doc_id" not in raw:
            raw["doc_id"] = doc_id
        raw["ppe_total"] = ppe.get("total")
        raw["ppe_method"] = str(ppe.get("method", "unknown"))
        raw["ppe_accounting_standard"] = str(ppe.get("accounting_standard", "unknown"))

    return by_year


def _ensure_raw_by_year(
    metric_key: str,
    data: dict[str, dict[str, Any]] | dict[str, RawXbrlExtraction],
    doc_id_by_year: dict[str, str] | None = None,
) -> dict[str, RawXbrlExtraction]:
    """旧形式の抽出器結果を受け取った場合も RawXbrlExtraction に揃える。"""
    if any(
        "interest_bearing_debt" in item
        or "gross_profit" in item
        or "balance_sheet_method" in item
        or "doc_id" in item
        or "amendment_doc_id" in item
        for item in data.values()
    ):
        return cast(dict[str, RawXbrlExtraction], data)
    payload: dict[str, dict[str, Any]] = {metric_key: cast(dict[str, dict[str, Any]], data)}
    if doc_id_by_year is not None:
        payload["doc_ids"] = doc_id_by_year
    return _raw_by_year(payload)


def _iter_raw(
    years: Sequence[YearEntry],
    raw_by_year: dict[str, dict[str, Any]] | dict[str, RawXbrlExtraction],
    spec_key: str,
    doc_id_by_year: dict[str, str] | None = None,
) -> Iterator[tuple[YearEntry, RawXbrlExtraction]]:
    """各年度の YearEntry と正規化済み RawXbrlExtraction を順に yield する。"""
    normalized = _ensure_raw_by_year(spec_key, raw_by_year, doc_id_by_year)
    for year in years:
        yield year, normalized.get(_fy_end_key(year), {})


def _apply_ibd(
    years: list[YearEntry],
    raw_by_year: dict[str, dict[str, Any]] | dict[str, RawXbrlExtraction],
    doc_id_by_year: dict[str, str] | None = None,
) -> None:
    for year, raw in _iter_raw(years, raw_by_year, "ibd", doc_id_by_year):
        doc_id = raw.get("doc_id")
        amendment_doc_id = raw.get("amendment_doc_id")
        cd = year["CalculatedData"]
        if doc_id:
            cd["DocID"] = doc_id
            _set_metric_source(cd, "DocID", source="edinet", unit="id", doc_id=doc_id)
        if amendment_doc_id:
            cd["AmendmentDocID"] = amendment_doc_id
            _set_metric_source(
                cd,
                "AmendmentDocID",
                source="edinet",
                unit="id",
                doc_id=amendment_doc_id,
            )
        ibd_value = raw.get("interest_bearing_debt")
        if ibd_value is None:
            continue
        ibd_m = ibd_value / MILLION_YEN
        cd["InterestBearingDebt"] = ibd_m
        cd["IBDComponents"] = [
            {
                "label": c.get("label", ""),
                "current": _to_millions_or_none(c.get("current")),
                "prior": _to_millions_or_none(c.get("prior")),
            }
            for c in raw.get("ibd_components", [])
        ]
        cd["IBDAccountingStandard"] = raw.get("ibd_accounting_standard", "unknown")
        _set_metric_source(
            cd,
            "InterestBearingDebt",
            source="edinet",
            unit="million_yen",
            method=raw.get("ibd_method"),
            doc_id=doc_id,
            label=raw.get("ibd_accounting_standard"),
        )


def _apply_balance_sheet(
    years: list[YearEntry],
    raw_by_year: dict[str, dict[str, Any]] | dict[str, RawXbrlExtraction],
) -> None:
    field_map = {
        "total_assets": "TotalAssets",
        "current_assets": "CurrentAssets",
        "non_current_assets": "NonCurrentAssets",
        "current_liabilities": "CurrentLiabilities",
        "non_current_liabilities": "NonCurrentLiabilities",
        "net_assets": "NetAssets",
    }
    for year, raw in _iter_raw(years, raw_by_year, "bs"):
        if not raw:
            continue
        cd = year["CalculatedData"]
        for source_key, target_key in field_map.items():
            value = raw.get(source_key)
            if source_key in raw:
                cd[target_key] = None
            if value is None:
                continue
            cd[target_key] = value / MILLION_YEN
            _set_metric_source(
                cd,
                target_key,
                source="edinet",
                unit="million_yen",
                method=raw.get("balance_sheet_method"),
                doc_id=raw.get("doc_id"),
            )
        cd["BalanceSheetComponents"] = [
            {
                "label": c.get("label", ""),
                "current": _to_millions_or_none(c.get("current")),
                "prior": _to_millions_or_none(c.get("prior")),
            }
            for c in raw.get("balance_sheet_components", [])
        ]
        cd["BalanceSheetAccountingStandard"] = raw.get("balance_sheet_accounting_standard", "unknown")


def _apply_ppe(
    years: list[YearEntry],
    raw_by_year: dict[str, dict[str, Any]] | dict[str, RawXbrlExtraction],
) -> None:
    for year, raw in _iter_raw(years, raw_by_year, "ppe"):
        ppe_total = raw.get("ppe_total")
        if ppe_total is None:
            continue
        cd = year["CalculatedData"]
        cd["PPETotal"] = ppe_total / MILLION_YEN
        cd["PPEAccountingStandard"] = raw.get("ppe_accounting_standard", "unknown")
        _set_metric_source(cd, "PPETotal", source="edinet", unit="million_yen", method=raw.get("ppe_method"), doc_id=raw.get("doc_id"))


def _apply_interest_expense(
    years: list[YearEntry],
    raw_by_year: dict[str, dict[str, Any]] | dict[str, RawXbrlExtraction],
) -> None:
    for year, raw in _iter_raw(years, raw_by_year, "ie"):
        interest_expense = raw.get("interest_expense")
        if interest_expense is not None:
            cd = year["CalculatedData"]
            cd["InterestExpense"] = interest_expense / MILLION_YEN
            _set_metric_source(
                cd,
                "InterestExpense",
                source="edinet",
                unit="million_yen",
                method=raw.get("interest_expense_method"),
                doc_id=raw.get("doc_id"),
            )


def _apply_tax(
    years: list[YearEntry],
    raw_by_year: dict[str, dict[str, Any]] | dict[str, RawXbrlExtraction],
) -> None:
    for year, raw in _iter_raw(years, raw_by_year, "tax"):
        if not raw or "tax_method" not in raw:
            continue
        cd = year["CalculatedData"]
        pretax_income = raw.get("pretax_income")
        income_tax = raw.get("income_tax")
        effective_tax_rate = raw.get("effective_tax_rate")
        if pretax_income is not None:
            cd["PretaxIncome"] = pretax_income / MILLION_YEN
            _set_metric_source(cd, "PretaxIncome", source="edinet", unit="million_yen", method=raw.get("tax_method"), doc_id=raw.get("doc_id"))
        if income_tax is not None:
            cd["IncomeTax"] = income_tax / MILLION_YEN
            _set_metric_source(cd, "IncomeTax", source="edinet", unit="million_yen", method=raw.get("tax_method"), doc_id=raw.get("doc_id"))
        if effective_tax_rate is not None:
            cd["EffectiveTaxRate"] = effective_tax_rate * PERCENT
            _set_metric_source(cd, "EffectiveTaxRate", source="derived", unit="percent", method=raw.get("tax_method"), doc_id=raw.get("doc_id"))


def _apply_gross_profit(
    years: list[YearEntry],
    raw_by_year: dict[str, dict[str, Any]] | dict[str, RawXbrlExtraction],
) -> None:
    for year, raw in _iter_raw(years, raw_by_year, "gp"):
        gross_profit = raw.get("gross_profit")
        if gross_profit is None:
            continue
        gp_m = gross_profit / MILLION_YEN
        gp_method = raw.get("gross_profit_method", "unknown")
        gp_label = raw.get("gross_profit_label")
        sales_m = _year_metric_float(year, "Sales")
        cd = year["CalculatedData"]
        cd["GrossProfit"] = gp_m
        cd["GrossProfitMethod"] = gp_method
        if gp_label is not None:
            cd["GrossProfitLabel"] = gp_label
        cd["GrossProfitMargin"] = gp_m / sales_m * PERCENT if sales_m else None
        _set_metric_source(
            cd,
            "GrossProfit",
            source="edinet",
            unit="million_yen",
            method=gp_method,
            doc_id=raw.get("doc_id"),
            label=gp_label,
        )
        _set_metric_source(cd, "GrossProfitMargin", source="derived", unit="percent", method="GrossProfit / Sales")


def _apply_operating_profit(
    years: list[YearEntry],
    raw_by_year: dict[str, dict[str, Any]] | dict[str, RawXbrlExtraction],
) -> None:
    for year, raw in _iter_raw(years, raw_by_year, "op"):
        operating_profit = raw.get("operating_profit")
        if operating_profit is None:
            continue
        cd = year["CalculatedData"]
        op_m = operating_profit / MILLION_YEN
        year["RawData"]["OP"] = operating_profit
        if raw.get("operating_profit_label") == "経常利益":
            cd["OPLabel"] = "経常利益"
        _set_metric_source(
            cd,
            "OP",
            source="edinet",
            unit="million_yen",
            method=raw.get("operating_profit_method"),
            doc_id=raw.get("doc_id"),
            label=raw.get("operating_profit_label"),
        )
        sga = raw.get("selling_general_administrative_expenses")
        if sga is not None:
            cd["SellingGeneralAdministrativeExpenses"] = sga / MILLION_YEN
            _set_metric_source(
                cd,
                "SellingGeneralAdministrativeExpenses",
                source="edinet",
                unit="million_yen",
                method=raw.get("selling_general_administrative_expenses_method"),
                doc_id=raw.get("doc_id"),
            )
        sales = _year_metric_float(year, "Sales")
        if sales:
            cd["OperatingMargin"] = op_m / sales * PERCENT
            _set_metric_source(cd, "OperatingMargin", source="derived", unit="percent", method="OP / Sales")


def _apply_net_revenue(
    years: list[YearEntry],
    raw_by_year: dict[str, dict[str, Any]] | dict[str, RawXbrlExtraction],
) -> None:
    for year, raw in _iter_raw(years, raw_by_year, "nr"):
        if not raw:
            continue
        cd = year["CalculatedData"]
        rd = year["RawData"]
        net_revenue = raw.get("net_revenue")
        business_profit = raw.get("business_profit")
        if year_metric_value(year, "Sales") is None and net_revenue is not None:
            nr_m = net_revenue / MILLION_YEN
            rd["Sales"] = net_revenue
            rd["SalesLabel"] = "純収益"
            _set_metric_source(cd, "Sales", source="edinet", unit="million_yen", doc_id=raw.get("doc_id"), label="純収益")
            # GrossProfitMargin を Sales 確定後に再計算
            gp = cd.get("GrossProfit")
            if gp is not None:
                cd["GrossProfitMargin"] = gp / nr_m * PERCENT
                _set_metric_source(cd, "GrossProfitMargin", source="derived", unit="percent", method="GrossProfit / Sales")
        if year_metric_value(year, "OP") is None and business_profit is not None:
            bp_m = business_profit / MILLION_YEN
            rd["OP"] = business_profit
            cd["OPLabel"] = "事業利益"
            _set_metric_source(cd, "OP", source="edinet", unit="million_yen", doc_id=raw.get("doc_id"), label="事業利益")
            sales = _year_metric_float(year, "Sales")
            if sales:
                cd["OperatingMargin"] = bp_m / sales * PERCENT
                _set_metric_source(cd, "OperatingMargin", source="derived", unit="percent", method="OP / Sales")


def _apply_employees(
    years: list[YearEntry],
    raw_by_year: dict[str, dict[str, Any]] | dict[str, RawXbrlExtraction],
) -> None:
    for year, raw in _iter_raw(years, raw_by_year, "emp"):
        employees = raw.get("employees")
        if employees is not None:
            cd = year["CalculatedData"]
            cd["Employees"] = employees
            _set_metric_source(cd, "Employees", source="edinet", unit="persons", method=raw.get("employees_method"), doc_id=raw.get("doc_id"), label=raw.get("employees_scope"))


def _apply_order_book(
    years: list[YearEntry],
    raw_by_year: dict[str, dict[str, Any]] | dict[str, RawXbrlExtraction],
) -> None:
    for year, raw in _iter_raw(years, raw_by_year, "ob"):
        if not raw:
            continue
        cd = year["CalculatedData"]
        order_intake = raw.get("order_intake")
        order_backlog = raw.get("order_backlog")
        if order_intake is not None:
            cd["OrderIntake"] = order_intake / MILLION_YEN
            _set_metric_source(
                cd,
                "OrderIntake",
                source="edinet",
                unit="million_yen",
                method=raw.get("order_book_method"),
                doc_id=raw.get("doc_id"),
            )
        if order_backlog is not None:
            cd["OrderBacklog"] = order_backlog / MILLION_YEN
            _set_metric_source(
                cd,
                "OrderBacklog",
                source="edinet",
                unit="million_yen",
                method=raw.get("order_book_method"),
                doc_id=raw.get("doc_id"),
            )


def _resolve_tax_rate(cd: CalculatedData) -> tuple[float | None, bool]:
    """EffectiveTaxRate から計算用の税率（小数）を返す。

    - 0-50% 範囲内: 実績値（is_fallback=False）
    - 範囲外（異常値）: NOPAT_FALLBACK_TAX_RATE（is_fallback=True）
    - 未取得（None）: None（is_fallback=False）— 呼び出し元が判断する

    Returns: (rate_as_decimal_or_None, is_fallback)
    """
    rate_pct = cd.get("EffectiveTaxRate")
    if rate_pct is None:
        return None, False
    rate = rate_pct / PERCENT
    if NOPAT_MIN_NORMAL_TAX_RATE <= rate <= NOPAT_MAX_NORMAL_TAX_RATE:
        return rate, False
    return NOPAT_FALLBACK_TAX_RATE, True


def _apply_nopat(years: list[YearEntry]) -> None:
    for year in years:
        cd = year["CalculatedData"]
        op_m = _year_metric_float(year, "OP")
        if op_m is None:
            continue
        tax_rate, is_fallback = _resolve_tax_rate(cd)
        if tax_rate is None:
            tax_rate, is_fallback = NOPAT_FALLBACK_TAX_RATE, True
        method = f"OP × (1 - {int(NOPAT_FALLBACK_TAX_RATE * PERCENT)}%_fallback)" if is_fallback else "OP × (1 - income_tax / pretax_income)"
        cd["NOPAT"] = op_m * (1 - tax_rate)
        _set_metric_source(cd, "NOPAT", source="derived", unit="million_yen", method=method)


def _apply_roic(years: list[YearEntry]) -> None:
    for year in years:
        cd = year["CalculatedData"]
        nopat = cd.get("NOPAT")
        net_assets = cd.get("NetAssets")
        ibd = cd.get("InterestBearingDebt")
        if nopat is None or net_assets is None or ibd is None:
            continue
        invested_capital = net_assets + ibd
        if invested_capital == 0:
            continue
        cd["ROIC"] = nopat / invested_capital * PERCENT
        _set_metric_source(cd, "ROIC", source="derived", unit="percent", method="NOPAT / (NetAssets + InterestBearingDebt)")


def _apply_net_cash(years: list[YearEntry]) -> None:
    for year in years:
        cd = year["CalculatedData"]
        cash_eq_m = _year_metric_float(year, "CashEq")
        ibd_m = cd.get("InterestBearingDebt")
        if cash_eq_m is None or ibd_m is None:
            continue
        cd["NetCash"] = cash_eq_m - ibd_m
        _set_metric_source(cd, "NetCash", source="derived", unit="million_yen", method="CashEq - InterestBearingDebt")


def _apply_net_de(years: list[YearEntry]) -> None:
    for year in years:
        cd = year["CalculatedData"]
        net_cash = cd.get("NetCash")
        net_assets = cd.get("NetAssets")
        if net_cash is None or net_assets is None or net_assets == 0:
            continue
        cd["NetDE"] = -net_cash / net_assets
        _set_metric_source(cd, "NetDE", source="derived", unit="ratio", method="-NetCash / NetAssets")


_METRIC_APPLIERS: list[Callable[[list[YearEntry], dict[str, RawXbrlExtraction]], None]] = [
    _apply_ibd,
    _apply_balance_sheet,
    _apply_ppe,
    _apply_interest_expense,
    _apply_tax,
    _apply_gross_profit,
    _apply_operating_profit,
    _apply_net_revenue,
    _apply_employees,
    _apply_order_book,
]



class IndividualAnalyzer:
    """個別詳細分析クラス"""

    def __init__(
        self,
        edinet_client: EdinetAPIClient | None = None,
        cache_manager: CacheManager | None = None,
    ) -> None:
        if edinet_client is not None:
            self.edinet_client = edinet_client
        else:
            try:
                self.edinet_client = EdinetAPIClient(
                    api_key=settings_store.edinet_api_key,
                    cache_dir=str(edinet_cache_dir(settings_store.cache_dir)),
                )
            except Exception as e:
                logger.warning(f"EDINETクライアントの初期化に失敗しました: {e}")
                self.edinet_client = None

        if cache_manager is None:
            cache_manager = CacheManager(
                cache_dir=str(settings_store.cache_dir),
                enabled=settings_store.cache_enabled,
            )
        self._cache_manager = cache_manager

        self._edinet_fetcher = EdinetFetcher(
            self.edinet_client,
            cache_manager=self._cache_manager,
        )

    async def fetch_analysis_data(
        self,
        code: str,
        analysis_years: int | None = None,
        max_documents: int = 10,
        include_2q: bool = False,
        prefetched_stock_info: dict[str, Any] | None = None,
        prefetched_financial_data: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        """財務指標 + EDINETデータを取得する公開API（use_cache=False）。

        data_service などの上位層が private メソッドを直接呼ばずに済むよう提供する。
        """
        stock_info = prefetched_stock_info or {"Code": code}
        financial_data = prefetched_financial_data or []
        annual_data: list[dict[str, Any]] = []
        annual_context: XbrlBuildContext | None = None

        if prefetched_stock_info is not None and prefetched_financial_data is not None:
            from blue_ticker.utils.financial_data import extract_annual_data

            try:
                annual_data = extract_annual_data(financial_data, include_2q=include_2q)
            except Exception as e:
                logger.error(f"銘柄コード {code}: 年度データ抽出中にエラーが発生しました - {e}", exc_info=True)
                return {}

        if not annual_data:
            fallback_years = analysis_years or max_documents
            annual_context = await self._edinet_fetcher.build_xbrl_annual_context(
                code,
                fallback_years,
            )
            annual_data = annual_context["records"]
            if not annual_data:
                return {}
            financial_data = annual_data

        available_years = sum(1 for d in annual_data if d.get("CurPerType") == "FY")
        actual_years = min(available_years, analysis_years) if analysis_years else available_years

        try:
            metrics = calculate_metrics_flexible(annual_data, actual_years)
        except Exception as e:
            logger.error(f"銘柄コード {code}: 指標計算中にエラーが発生しました - {e}", exc_info=True)
            return {}

        edinet_data: dict[str, Any] = {}
        all_metrics: dict[str, dict[str, Any]] = {}

        if financial_data:
            if annual_context is None:
                pre_parsed_map, edinet_data = await asyncio.gather(
                    self._edinet_fetcher.predownload_and_parse(code, financial_data, actual_years),
                    self._edinet_fetcher.fetch_edinet_data_async(code, financial_data, max_documents=max_documents),
                )
            else:
                pre_parsed_map = annual_context["pre_parsed_map"]
                edinet_data = await self._edinet_fetcher.fetch_edinet_data_async(
                    code,
                    financial_data,
                    max_documents=max_documents,
                )
            all_metrics = await self._edinet_fetcher.extract_all_by_year(
                code,
                financial_data,
                actual_years,
                docs=annual_context["docs"] if annual_context is not None else None,
                pre_parsed_map=pre_parsed_map,
            )

        years: list[YearEntry] = metrics.get("years", [])

        raw_xbrl_by_year = _raw_by_year(all_metrics)
        for apply_fn in _METRIC_APPLIERS:
            apply_fn(years, raw_xbrl_by_year)
        apply_operating_profit_change_from_xbrl(years, all_metrics.get("gp", {}), all_metrics.get("op", {}))
        apply_operating_profit_change_to_years(years)
        _apply_nopat(years)
        _apply_roic(years)
        _apply_net_cash(years)
        _apply_net_de(years)
        apply_roic_waterfall_from_xbrl(
            years,
            all_metrics.get("gp", {}),
            all_metrics.get("op", {}),
            all_metrics.get("ibd", {}),
            all_metrics.get("bs", {}),
        )
        apply_roic_waterfall_to_years(years)
        apply_roe_waterfall_to_years(years)

        return {
            "stock_info": stock_info,
            "financial_data": financial_data,
            "annual_data": annual_data,
            "metrics": metrics,
            "edinet_data": edinet_data,
        }


# 互換性維持
# パターン評価関数は patterns.py に移動済み
