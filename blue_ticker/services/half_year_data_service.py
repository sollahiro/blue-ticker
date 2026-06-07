"""
半期財務データ構築サービス
"""

import asyncio
import logging
from collections.abc import Mapping
from typing import Any

from blue_ticker import __version__
from blue_ticker.api.edinet_client import EdinetAPIClient
from blue_ticker.constants.api import EDINET_DOC_DISCOVERY_BUFFER, EDINET_DOC_DISCOVERY_LIMIT
from blue_ticker.constants.financial import (
    MILLION_YEN,
    NOPAT_FALLBACK_TAX_RATE,
    NOPAT_MAX_NORMAL_TAX_RATE,
    NOPAT_MIN_NORMAL_TAX_RATE,
    PERCENT,
)
from blue_ticker.utils.cache import CacheManager
from blue_ticker.utils.converters import to_float
from blue_ticker.utils.financial_data import build_half_year_periods
from blue_ticker.utils.operating_profit_change import (
    apply_operating_profit_change_to_periods,
    apply_operating_profit_change_to_periods_from_xbrl,
)
from blue_ticker.utils.roic_waterfall import apply_roic_waterfall_to_periods
from blue_ticker.utils.output_serializer import serialize_half_year_periods
from blue_ticker.utils.xbrl_result_types import GrossProfitResult, HalfYearEdinetEntry, TaxExpenseResult

from .edinet_fetcher import EdinetFetcher

logger = logging.getLogger(__name__)

_CACHE_VERSION = __version__


def _fy_end_key(value: object) -> str:
    return value.replace("-", "") if isinstance(value, str) else ""


def _set_metric_source(
    data: dict[str, Any],
    metric: str,
    *,
    source: str,
    unit: str,
    method: str | None = None,
    doc_id: str | None = None,
    label: str | None = None,
) -> None:
    sources = data.setdefault("MetricSources", {})
    item: dict[str, str | None] = {"source": source, "unit": unit}
    if method is not None:
        item["method"] = method
    if doc_id is not None:
        item["docID"] = doc_id
    if label is not None:
        item["label"] = label
    sources[metric] = item


def _to_gross_profit_result(value: dict[str, Any] | None) -> GrossProfitResult | None:
    if value is None:
        return None

    required_keys = ("current", "prior", "method", "accounting_standard", "components")
    if not all(key in value for key in required_keys):
        return None

    result: GrossProfitResult = {
        "current": value.get("current"),
        "prior": value.get("prior"),
        "method": str(value["method"]),
        "accounting_standard": str(value["accounting_standard"]),
        "components": value["components"] if isinstance(value["components"], list) else [],
    }
    if isinstance(value.get("docID"), str):
        result["docID"] = value["docID"]
    if isinstance(value.get("reason"), str):
        result["reason"] = value["reason"]
    for key in ("current_sales", "prior_sales"):
        raw_value = value.get(key)
        if raw_value is None or isinstance(raw_value, (int, float)):
            result[key] = raw_value
    return result


def _resolve_tax_rate(data: dict[str, Any]) -> tuple[float, bool]:
    rate_pct = to_float(data.get("EffectiveTaxRate"))
    if rate_pct is None:
        return NOPAT_FALLBACK_TAX_RATE, True
    rate = rate_pct / PERCENT
    if NOPAT_MIN_NORMAL_TAX_RATE <= rate <= NOPAT_MAX_NORMAL_TAX_RATE:
        return rate, False
    return NOPAT_FALLBACK_TAX_RATE, True


def _apply_effective_tax_rate(data: dict[str, Any]) -> None:
    """PreTaxIncome / IncomeTax（百万円）からEffectiveTaxRate（%）を計算して格納する。"""
    pretax_m = to_float(data.get("PreTaxIncome"))
    income_tax_m = to_float(data.get("IncomeTax"))
    if pretax_m is not None and pretax_m != 0 and income_tax_m is not None:
        data["EffectiveTaxRate"] = income_tax_m / pretax_m * PERCENT
        _set_metric_source(data, "EffectiveTaxRate", source="derived", unit="percent", method="IncomeTax / PreTaxIncome")


def _apply_nopat_and_roic(
    data: dict[str, Any],
    net_assets_m: float | None,
    ibd_m: float | None,
) -> None:
    op_m = to_float(data.get("OP"))
    if op_m is not None:
        tax_rate, is_fallback = _resolve_tax_rate(data)
        method = (
            f"OP × (1 - {int(NOPAT_FALLBACK_TAX_RATE * PERCENT)}%_fallback)"
            if is_fallback
            else "OP × (1 - income_tax / pretax_income)"
        )
        data["NOPAT"] = op_m * (1 - tax_rate)
        _set_metric_source(data, "NOPAT", source="derived", unit="million_yen", method=method)

    nopat = to_float(data.get("NOPAT"))
    if nopat is None or net_assets_m is None or ibd_m is None:
        return
    invested_capital = net_assets_m + ibd_m
    if invested_capital == 0:
        return
    data["InvestedCapital"] = invested_capital
    data["ROIC"] = nopat / invested_capital * PERCENT
    _set_metric_source(data, "ROIC", source="derived", unit="percent", method="NOPAT / (NetAssets + InterestBearingDebt)")


def _apply_bs_snapshot(
    data: dict[str, Any],
    bs: Mapping[str, Any],
    ibd_m: float | None,
    cash_eq_raw: float | None,
) -> None:
    """BSスナップショットからBS・IBD・キャッシュ・ROE指標を格納する。"""
    for data_key, bs_key in [
        ("TotalAssets", "total_assets"),
        ("CurrentAssets", "current_assets"),
        ("NonCurrentAssets", "non_current_assets"),
        ("CurrentLiabilities", "current_liabilities"),
        ("NonCurrentLiabilities", "non_current_liabilities"),
        ("NetAssets", "net_assets"),
    ]:
        raw = to_float(bs.get(bs_key))
        if raw is not None:
            data[data_key] = raw / MILLION_YEN
            _set_metric_source(data, data_key, source="edinet", unit="million_yen")

    if ibd_m is not None:
        data["InterestBearingDebt"] = ibd_m
        _set_metric_source(data, "InterestBearingDebt", source="edinet", unit="million_yen")

    if cash_eq_raw is not None:
        cash_eq_m = cash_eq_raw / MILLION_YEN
        data["CashEq"] = cash_eq_m
        _set_metric_source(data, "CashEq", source="edinet", unit="million_yen")
        if ibd_m is not None:
            data["NetCash"] = cash_eq_m - ibd_m
            _set_metric_source(data, "NetCash", source="derived", unit="million_yen", method="CashEq - IBD")

    net_assets_m = to_float(data.get("NetAssets"))
    np_m = to_float(data.get("NP"))
    if np_m is not None and net_assets_m is not None and net_assets_m != 0:
        data["ROE"] = np_m / net_assets_m * PERCENT
        _set_metric_source(data, "ROE", source="derived", unit="percent", method="NP / NetAssets")


def _apply_h1_edinet_data(
    data: dict[str, Any],
    edinet_q2: HalfYearEdinetEntry,
    q2_rec: dict[str, Any],
) -> tuple[float | None, float | None, float | None, float | None, float | None]:
    """H1期間のEDINET補完を適用。(gp_m, cfo_m, cfi_m, pretax_m, tax_m) を返す（H2キャリーオーバー用）。"""
    gp_result = edinet_q2["gp"]
    cf_result = edinet_q2["cf"]
    ibd_result = edinet_q2["ibd"]
    tax_result = edinet_q2["tax"]
    bs_result = edinet_q2["bs"]

    h1_gp_m = None
    gp_current = gp_result.get("current")
    if gp_current is not None:
        h1_gp_m = gp_current / MILLION_YEN
        sales = data.get("Sales")
        data["GrossProfit"] = h1_gp_m
        data["GrossProfitMargin"] = h1_gp_m / sales * 100 if sales else None
        data["DocID"] = gp_result.get("docID")
        _set_metric_source(data, "GrossProfit", source="edinet", unit="million_yen", method=gp_result.get("method"), doc_id=gp_result.get("docID"))
        _set_metric_source(data, "GrossProfitMargin", source="derived", unit="percent", method="GrossProfit / Sales")
        _set_metric_source(data, "DocID", source="edinet", unit="id", doc_id=gp_result.get("docID"))

    h1_cfo_m = h1_cfi_m = None
    cfo_raw = cf_result["cfo"].get("current")
    cfi_raw = cf_result["cfi"].get("current")
    if cfo_raw is not None:
        h1_cfo_m = cfo_raw / MILLION_YEN
        data["CFO"] = h1_cfo_m
        _set_metric_source(data, "CFO", source="edinet", unit="million_yen")
    if cfi_raw is not None:
        h1_cfi_m = cfi_raw / MILLION_YEN
        data["CFI"] = h1_cfi_m
        _set_metric_source(data, "CFI", source="edinet", unit="million_yen")
    if h1_cfo_m is not None and h1_cfi_m is not None:
        data["CFC"] = h1_cfo_m + h1_cfi_m
        data["FreeCF"] = data["CFC"]
        _set_metric_source(data, "CFC", source="derived", unit="million_yen", method="CFO + CFI")
        _set_metric_source(data, "FreeCF", source="derived", unit="million_yen", method="alias of CFC")

    # PreTaxIncome / IncomeTax を先に設定してEffectiveTaxRateを確定させる（NOPATの税率に使用）
    h1_pretax_m = h1_tax_m = None
    pretax_raw = tax_result.get("pretax_income")
    tax_raw = tax_result.get("income_tax")
    if pretax_raw is not None:
        h1_pretax_m = pretax_raw / MILLION_YEN
        data["PreTaxIncome"] = h1_pretax_m
        _set_metric_source(data, "PreTaxIncome", source="edinet", unit="million_yen", method=tax_result.get("method"))
    if tax_raw is not None:
        h1_tax_m = tax_raw / MILLION_YEN
        data["IncomeTax"] = h1_tax_m
        _set_metric_source(data, "IncomeTax", source="edinet", unit="million_yen", method=tax_result.get("method"))
    _apply_effective_tax_rate(data)

    ibd_current = ibd_result.get("current")
    h1_ibd_m = ibd_current / MILLION_YEN if ibd_current is not None else None

    # BS から NetAssets を優先取得（NOPAT/ROIC の分母に使用）
    bs_net_assets_raw = to_float(bs_result.get("net_assets"))
    q2_net_assets_raw = to_float(q2_rec.get("NetAssets"))
    net_assets_raw = bs_net_assets_raw if bs_net_assets_raw is not None else q2_net_assets_raw
    q2_net_assets_m = net_assets_raw / MILLION_YEN if net_assets_raw is not None else None
    _apply_nopat_and_roic(data, q2_net_assets_m, h1_ibd_m)

    _apply_bs_snapshot(data, bs_result, h1_ibd_m, to_float(q2_rec.get("CashEq")))

    return h1_gp_m, h1_cfo_m, h1_cfi_m, h1_pretax_m, h1_tax_m


def _apply_h2_edinet_data(
    data: dict[str, Any],
    fy_rec: dict[str, Any],
    h1_carry: tuple[float | None, float | None, float | None, float | None, float | None],
    fy_gp_result: GrossProfitResult | None,
    ibd_by_year: dict[str, Any],
    fy_end_8: str,
    fy_tax_by_year: dict[str, Any] | None = None,
    fy_bs_by_year: dict[str, Any] | None = None,
) -> None:
    """H2期間の派生計算（FY - H1）と補完を適用。"""
    h1_gp_m, h1_cfo_m, h1_cfi_m, h1_pretax_m, h1_tax_m = h1_carry

    fy_cfo = to_float(fy_rec.get("CFO"))
    fy_cfi = to_float(fy_rec.get("CFI"))
    fy_cfo_m = fy_cfo / MILLION_YEN if fy_cfo is not None else None
    fy_cfi_m = fy_cfi / MILLION_YEN if fy_cfi is not None else None
    fy_source = "EDINET" if fy_rec.get("_xbrl_source") else "EXTERNAL"

    if fy_cfo_m is not None and h1_cfo_m is not None:
        data["CFO"] = fy_cfo_m - h1_cfo_m
        _set_metric_source(data, "CFO", source="derived", unit="million_yen", method=f"FY {fy_source} CFO - H1 EDINET CFO")
    if fy_cfi_m is not None and h1_cfi_m is not None:
        data["CFI"] = fy_cfi_m - h1_cfi_m
        _set_metric_source(data, "CFI", source="derived", unit="million_yen", method=f"FY {fy_source} CFI - H1 EDINET CFI")
    cfo = data.get("CFO")
    cfi = data.get("CFI")
    if cfo is not None and cfi is not None:
        data["CFC"] = cfo + cfi
        data["FreeCF"] = data["CFC"]
        _set_metric_source(data, "CFC", source="derived", unit="million_yen", method="CFO + CFI")
        _set_metric_source(data, "FreeCF", source="derived", unit="million_yen", method="alias of CFC")

    fy_gp_current = fy_gp_result.get("current") if fy_gp_result is not None else None
    if fy_gp_result is not None and fy_gp_current is not None:
        fy_gp_m = fy_gp_current / MILLION_YEN
        if h1_gp_m is not None:
            h2_gp_m = fy_gp_m - h1_gp_m
            sales = data.get("Sales")
            data["GrossProfit"] = h2_gp_m
            data["GrossProfitMargin"] = h2_gp_m / sales * 100 if sales else None
            data["DocID"] = fy_gp_result.get("docID")
            _set_metric_source(data, "GrossProfit", source="derived", unit="million_yen", method="FY EDINET GrossProfit - H1 EDINET GrossProfit", doc_id=fy_gp_result.get("docID"))
            _set_metric_source(data, "GrossProfitMargin", source="derived", unit="percent", method="GrossProfit / Sales")
            _set_metric_source(data, "DocID", source="edinet", unit="id", doc_id=fy_gp_result.get("docID"))

    # PreTaxIncome / IncomeTax（FY - H1）を先に設定してEffectiveTaxRateを確定させる
    fy_tax = fy_tax_by_year.get(fy_end_8) if fy_tax_by_year else None
    if fy_tax is not None:
        fy_pretax_raw = fy_tax.get("pretax_income")
        fy_income_tax_raw = fy_tax.get("income_tax")
        fy_pretax_m = fy_pretax_raw / MILLION_YEN if fy_pretax_raw is not None else None
        fy_tax_m = fy_income_tax_raw / MILLION_YEN if fy_income_tax_raw is not None else None
        if fy_pretax_m is not None and h1_pretax_m is not None:
            data["PreTaxIncome"] = fy_pretax_m - h1_pretax_m
            _set_metric_source(data, "PreTaxIncome", source="derived", unit="million_yen", method="FY PreTaxIncome - H1 PreTaxIncome")
        if fy_tax_m is not None and h1_tax_m is not None:
            data["IncomeTax"] = fy_tax_m - h1_tax_m
            _set_metric_source(data, "IncomeTax", source="derived", unit="million_yen", method="FY IncomeTax - H1 IncomeTax")
    _apply_effective_tax_rate(data)

    h2_ibd = ibd_by_year.get(fy_end_8)
    h2_ibd_m = h2_ibd["current"] / MILLION_YEN if h2_ibd and h2_ibd.get("current") is not None else None

    fy_bs = fy_bs_by_year.get(fy_end_8) if fy_bs_by_year else None
    bs_net_assets_raw = to_float(fy_bs.get("net_assets")) if fy_bs else None
    fy_net_assets_raw = to_float(fy_rec.get("NetAssets"))
    net_assets_raw = bs_net_assets_raw if bs_net_assets_raw is not None else fy_net_assets_raw
    h2_net_assets_m = net_assets_raw / MILLION_YEN if net_assets_raw is not None else None
    _apply_nopat_and_roic(data, h2_net_assets_m, h2_ibd_m)

    if fy_bs is not None:
        _apply_bs_snapshot(data, fy_bs, h2_ibd_m, to_float(fy_rec.get("CashEq")))


def _apply_fy_only_edinet_data(
    data: dict[str, Any],
    fy_gp_result: GrossProfitResult | None,
    fy_rec: dict[str, Any],
    ibd_by_year: dict[str, Any],
    fy_end_8: str,
    fy_tax_by_year: dict[str, Any] | None = None,
    fy_bs_by_year: dict[str, Any] | None = None,
) -> None:
    """FY-onlyエントリ（2Qデータなし）にFY EDINET GP + ROIC を補完。"""
    fy_gp_current = fy_gp_result.get("current") if fy_gp_result is not None else None
    if fy_gp_result is not None and fy_gp_current is not None:
        gp_m = fy_gp_current / MILLION_YEN
        sales = data.get("Sales")
        data["GrossProfit"] = gp_m
        data["GrossProfitMargin"] = gp_m / sales * 100 if sales else None
        _set_metric_source(data, "GrossProfit", source="edinet", unit="million_yen", method=fy_gp_result.get("method"), doc_id=fy_gp_result.get("docID"))
        _set_metric_source(data, "GrossProfitMargin", source="derived", unit="percent", method="GrossProfit / Sales")

    # PreTaxIncome / IncomeTax を先に設定
    fy_tax = fy_tax_by_year.get(fy_end_8) if fy_tax_by_year else None
    if fy_tax is not None:
        pretax_raw = fy_tax.get("pretax_income")
        income_tax_raw = fy_tax.get("income_tax")
        if pretax_raw is not None:
            data["PreTaxIncome"] = pretax_raw / MILLION_YEN
            _set_metric_source(data, "PreTaxIncome", source="edinet", unit="million_yen", method=fy_tax.get("method"))
        if income_tax_raw is not None:
            data["IncomeTax"] = income_tax_raw / MILLION_YEN
            _set_metric_source(data, "IncomeTax", source="edinet", unit="million_yen", method=fy_tax.get("method"))
    _apply_effective_tax_rate(data)

    fy_ibd = ibd_by_year.get(fy_end_8)
    fy_ibd_m = fy_ibd["current"] / MILLION_YEN if fy_ibd and fy_ibd.get("current") is not None else None

    fy_bs = fy_bs_by_year.get(fy_end_8) if fy_bs_by_year else None
    bs_net_assets_raw = to_float(fy_bs.get("net_assets")) if fy_bs else None
    fy_net_assets_raw = to_float(fy_rec.get("NetAssets"))
    net_assets_raw = bs_net_assets_raw if bs_net_assets_raw is not None else fy_net_assets_raw
    fy_net_assets_m = net_assets_raw / MILLION_YEN if net_assets_raw is not None else None
    _apply_nopat_and_roic(data, fy_net_assets_m, fy_ibd_m)

    if fy_bs is not None:
        _apply_bs_snapshot(data, fy_bs, fy_ibd_m, to_float(fy_rec.get("CashEq")))


def _trim_half_year_periods(
    periods: list[dict[str, Any]],
    years: int,
) -> list[dict[str, Any]]:
    """完結 H1+H2 ペア N 組 + 当期 H1（FY 未公開）に trim する。

    periods は古い順を前提とする。
    完結ペア = 同じ fy_end に H1 と H2 の両方がある年度。
    当期 H1 = H1 はあるが H2 が存在しない最新fy_end（ペア数を圧迫しない）。
    """
    h2_ends = {p["fy_end"] for p in periods if p.get("half") == "H2"}
    h1_ends = {p["fy_end"] for p in periods if p.get("half") == "H1"}
    current_h1_ends = h1_ends - h2_ends  # H1 はあるが H2 がない = 当期進行中

    # 完結ペアを新しい順に N 件選択
    complete_sorted = sorted(h2_ends, reverse=True)[:years]
    selected = set(complete_sorted)

    result = [p for p in periods if p["fy_end"] in selected]
    # 当期 H1 を末尾に追加（最新 1 件のみ）
    for p in reversed(periods):
        if p["fy_end"] in current_h1_ends and p.get("half") == "H1":
            result.append(p)
            break
    return result


class HalfYearDataService:
    """H1/H2 の半期財務データ構築と EDINET 補完を担当するサービス"""

    def __init__(self, edinet_client: EdinetAPIClient, cache_manager: CacheManager) -> None:
        self.edinet_client = edinet_client
        self.cache_manager = cache_manager

    async def get_half_year_periods(
        self,
        code: str,
        years: int = 3,
        use_cache: bool = True,
        include_debug_fields: bool = False,
    ) -> list[dict[str, Any]]:
        """H1/H2 の半期財務データを返す。"""
        cache_key = f"half_year_periods_{code}"
        if use_cache:
            cached = self.cache_manager.get(cache_key)
            if cached and cached.get("_cache_version") == _CACHE_VERSION:
                # 完結ペア数が要求 years を満たすか確認（不足なら再取得）
                cached_pair_count = len({
                    p["fy_end"] for p in cached.get("periods", []) if p.get("half") == "H2"
                })
                if cached_pair_count >= years:
                    trimmed = _trim_half_year_periods(cached["periods"], years)
                    return serialize_half_year_periods(trimmed, include_debug_fields=include_debug_fields)

        fetch_years = max(EDINET_DOC_DISCOVERY_LIMIT, years) + EDINET_DOC_DISCOVERY_BUFFER
        edinet_fetcher = EdinetFetcher(
            self.edinet_client,
            cache_manager=self.cache_manager,
        )
        try:
            annual_context, half_context = await asyncio.gather(
                edinet_fetcher.build_xbrl_annual_context(code, fetch_years),
                edinet_fetcher.build_xbrl_half_year_context(code, fetch_years),
            )
            fy_records = annual_context["records"]
            q2_records = half_context["records"]
            financial_data = fy_records + q2_records
        except Exception as e:
            logger.warning(f"[HALF] {code}: EDINET-only財務データ構築スキップ - {e}")
            return []

        # 全量生成（LIMIT 件）してキャッシュ保存、返却時に trim
        base_periods = build_half_year_periods(financial_data, years=EDINET_DOC_DISCOVERY_LIMIT)
        if not base_periods:
            return base_periods

        # 完結ペアの fy_end セットを補完抽出の範囲として使う
        selected_fy_ends = {p["fy_end"] for p in base_periods if p.get("half") == "H2"}

        # EDINET からの補完（GrossProfit + CFO/CFI for H1）
        # 表示中の FY 数だけ 2Q EDINET を取得（26H1 等の extra 分も含む）
        unique_fy_ends = len(set(p["fy_end"] for p in base_periods))
        try:
            half_edinet, fy_gp_all, ibd_all, fy_op_all, fy_tax_all, fy_bs_all = await asyncio.gather(
                edinet_fetcher.extract_half_year_edinet_data(
                    code,
                    financial_data,
                    max_years=unique_fy_ends,
                    docs=half_context["docs"],
                    pre_parsed_map=half_context["pre_parsed_map"],
                ),
                edinet_fetcher.extract_gross_profit_by_year(
                    code,
                    financial_data,
                    max_years=EDINET_DOC_DISCOVERY_LIMIT,
                    docs=annual_context["docs"],
                    pre_parsed_map=annual_context["pre_parsed_map"],
                ),
                edinet_fetcher.extract_ibd_by_year(
                    code,
                    financial_data,
                    max_years=EDINET_DOC_DISCOVERY_LIMIT,
                    docs=annual_context["docs"],
                    pre_parsed_map=annual_context["pre_parsed_map"],
                ),
                edinet_fetcher.extract_operating_profit_by_year(
                    code,
                    financial_data,
                    max_years=EDINET_DOC_DISCOVERY_LIMIT,
                    docs=annual_context["docs"],
                    pre_parsed_map=annual_context["pre_parsed_map"],
                ),
                edinet_fetcher.extract_tax_expense_by_year(
                    code,
                    financial_data,
                    max_years=EDINET_DOC_DISCOVERY_LIMIT,
                    docs=annual_context["docs"],
                    pre_parsed_map=annual_context["pre_parsed_map"],
                ),
                edinet_fetcher.extract_bs_by_year(
                    code,
                    financial_data,
                    max_years=EDINET_DOC_DISCOVERY_LIMIT,
                    docs=annual_context["docs"],
                    pre_parsed_map=annual_context["pre_parsed_map"],
                ),
            )
            # 選択済み年度のみにフィルタ
            fy_gp = {k: v for k, v in fy_gp_all.items() if k in selected_fy_ends}
            ibd_by_year = {k: v for k, v in ibd_all.items() if k in selected_fy_ends}
            fy_op = {k: v for k, v in fy_op_all.items() if k in selected_fy_ends}
            fy_tax_by_year = {k: v for k, v in fy_tax_all.items() if k in selected_fy_ends}
            fy_bs_by_year = {k: v for k, v in fy_bs_all.items() if k in selected_fy_ends}
        except Exception as e:
            logger.warning(f"[HALF] {code}: EDINET補完スキップ - {e}")
            self.cache_manager.set(cache_key, {
                "_cache_version": _CACHE_VERSION,
                "periods": base_periods,
            })
            trimmed = _trim_half_year_periods(base_periods, years)
            return serialize_half_year_periods(trimmed, include_debug_fields=include_debug_fields)

        fy_gp_by_end: dict[str, GrossProfitResult] = {}
        for fy_end, result in fy_gp.items():
            if not isinstance(result, dict):
                continue
            gp_result = _to_gross_profit_result(result)
            if gp_result is not None:
                fy_gp_by_end[fy_end] = gp_result

        half_gp_by_end: dict[str, Mapping[str, Any]] = {}
        half_op_by_end: dict[str, Mapping[str, Any]] = {}
        for fy_end, entry in half_edinet.items():
            if not isinstance(entry, dict):
                continue
            gp = entry.get("gp")
            op = entry.get("op")
            if isinstance(gp, dict):
                half_gp_by_end[fy_end] = gp
            if isinstance(op, dict):
                half_op_by_end[fy_end] = op

        fy_op_by_end: dict[str, Mapping[str, Any]] = {}
        for fy_end, result in fy_op.items():
            if isinstance(result, dict):
                fy_op_by_end[fy_end] = result

        # FY レコードを fy_end → record で引けるようにしておく
        fy_by_end: dict[str, dict[str, Any]] = {}
        for r in financial_data:
            if r.get("CurPerType") == "FY":
                fy_end_8 = _fy_end_key(r.get("CurFYEn"))
                if fy_end_8:
                    fy_by_end[fy_end_8] = r

        # 2Q レコードを fy_end → record で引けるようにしておく
        q2_by_end: dict[str, dict[str, Any]] = {}
        for r in financial_data:
            if r.get("CurPerType") == "2Q":
                fy_end_8 = _fy_end_key(r.get("CurFYEn"))
                if fy_end_8:
                    q2_by_end[fy_end_8] = r

        # H1 期間で確定した EDINET 値を H2 計算に引き継ぐ
        h1_edinet_by_fy: dict[str, tuple[float | None, float | None, float | None, float | None, float | None]] = {}

        for period in base_periods:
            fy_end_8 = _fy_end_key(period.get("fy_end"))
            half = period["half"]
            data = period["data"]
            edinet_q2 = half_edinet.get(fy_end_8)

            if half == "H1":
                if edinet_q2 is not None:
                    h1_edinet_by_fy[fy_end_8] = _apply_h1_edinet_data(data, edinet_q2, q2_by_end.get(fy_end_8, {}))
            elif half == "H2":
                _apply_h2_edinet_data(
                    data,
                    fy_by_end.get(fy_end_8, {}),
                    h1_edinet_by_fy.get(fy_end_8, (None, None, None, None, None)),
                    fy_gp_by_end.get(fy_end_8),
                    ibd_by_year,
                    fy_end_8,
                    fy_tax_by_year=fy_tax_by_year,
                    fy_bs_by_year=fy_bs_by_year,
                )
            else:
                _apply_fy_only_edinet_data(
                    data,
                    fy_gp_by_end.get(fy_end_8),
                    fy_by_end.get(fy_end_8, {}),
                    ibd_by_year,
                    fy_end_8,
                    fy_tax_by_year=fy_tax_by_year,
                    fy_bs_by_year=fy_bs_by_year,
                )

        apply_operating_profit_change_to_periods_from_xbrl(
            base_periods,
            half_gp_by_end,
            half_op_by_end,
            fy_gp_by_end,
            fy_op_by_end,
        )
        apply_operating_profit_change_to_periods(base_periods)
        apply_roic_waterfall_to_periods(base_periods)
        self.cache_manager.set(cache_key, {
            "_cache_version": _CACHE_VERSION,
            "periods": base_periods,
        })
        trimmed = _trim_half_year_periods(base_periods, years)
        return serialize_half_year_periods(trimmed, include_debug_fields=include_debug_fields)
