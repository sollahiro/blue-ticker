"""財務レコード組立ヘルパー。"""

from collections.abc import Callable
from datetime import timedelta
from pathlib import Path
from typing import Any, TypedDict, cast

from blue_ticker.analysis.context_helpers import has_nonconsolidated_contexts
from blue_ticker.analysis.balance_sheet import extract_balance_sheet
from blue_ticker.analysis.bank_financials import extract_bank_financials
from blue_ticker.analysis.capital_expenditure import extract_capital_expenditure
from blue_ticker.analysis.cash_flow import extract_cash_flow
from blue_ticker.analysis.employees import extract_employees
from blue_ticker.analysis.gross_profit import extract_gross_profit
from blue_ticker.analysis.income_statement import extract_income_statement
from blue_ticker.analysis.interest_bearing_debt import extract_interest_bearing_debt
from blue_ticker.analysis.interest_expense import extract_interest_expense
from blue_ticker.analysis.net_revenue import extract_net_revenue
from blue_ticker.analysis.operating_profit import extract_operating_profit
from blue_ticker.analysis.research_development import extract_research_development
from blue_ticker.analysis.share_buyback import extract_share_buyback
from blue_ticker.analysis.tax_expense import extract_tax_expense
from blue_ticker.analysis.sections import (
    BalanceSheetSection,
    CashFlowSection,
    EmployeeSection,
    IncomeStatementSection,
    detect_accounting_standard,
)
from blue_ticker.analysis.shareholder_metrics import ShareholderMetrics, extract_shareholder_metrics
from blue_ticker.analysis.tangible_fixed_assets import extract_tangible_fixed_assets
from blue_ticker.utils.fiscal_year import parse_date_string
from blue_ticker.utils.xbrl_result_types import XbrlTagElements
from blue_ticker.services._xbrl_parse_cache import (
    _PreParsedEntry,
    _extract_with_statement_scope,
    _preparsed_for_statement,
    _result_has_signal,
)


def _infer_fy_start(fy_end: str) -> str:
    """会計期末日から期首日を推測する（前年同日の翌日）。"""
    try:
        end_dt = parse_date_string(fy_end)
        if end_dt is None:
            return ""
        start_dt = end_dt.replace(year=end_dt.year - 1) + timedelta(days=1)
        return start_dt.strftime("%Y-%m-%d")
    except (ValueError, OverflowError):
        return ""


def _infer_fy_end_from_period_start(period_start: str) -> str:
    """期首日から会計期末日を推測する（翌年同日の前日）。"""
    try:
        start_dt = parse_date_string(period_start)
        if start_dt is None:
            return ""
        end_dt = start_dt.replace(year=start_dt.year + 1) - timedelta(days=1)
        return end_dt.strftime("%Y-%m-%d")
    except (ValueError, OverflowError):
        return ""


def _docs_from_xbrl_records(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """EDINET由来レコードに残した _docID から検索済み書類形式を復元する。"""
    docs: list[dict[str, Any]] = []
    seen: set[str] = set()
    for record in records:
        doc_id = record.get("_docID")
        fy_end = record.get("CurFYEn")
        if not isinstance(doc_id, str) or not doc_id or not isinstance(fy_end, str):
            continue
        if doc_id in seen:
            continue
        seen.add(doc_id)
        doc: dict[str, Any] = {
            "docID": doc_id,
            "edinet_fy_end": fy_end,
            "period_type": record.get("CurPerType"),
            "submitDateTime": record.get("DiscDate", ""),
        }
        if isinstance(record.get("CurPerSt"), str):
            doc["edinet_period_start"] = record["CurPerSt"]
            doc["periodStart"] = record["CurPerSt"]
        if isinstance(record.get("CurPerEn"), str):
            doc["edinet_period_end"] = record["CurPerEn"]
            doc["periodEnd"] = record["CurPerEn"]
        docs.append(doc)
    return docs


def _make_section_wrapper(
    section_class: type, extract_fn: Callable
) -> Callable:
    """Section-aware 抽出関数を旧 (xbrl_path, *, pre_parsed=None) シグネチャへ変換する。"""
    def _wrapper(
        xbrl_path: Path,
        *,
        pre_parsed: XbrlTagElements | None = None,
    ) -> dict[str, Any]:
        if pre_parsed is not None:
            std = detect_accounting_standard(pre_parsed)
            section = section_class.from_pre_parsed(pre_parsed, std, xbrl_path)
        else:
            section = section_class.from_xbrl(xbrl_path)
        return extract_fn(section)  # type: ignore[arg-type]
    return _wrapper


def _employees_compat(
    xbrl_path: Path,
    *,
    pre_parsed: XbrlTagElements | None = None,
) -> dict[str, Any]:
    """EmployeeSection（xbrl_dir なし）向けラッパー。"""
    if pre_parsed is not None:
        std = detect_accounting_standard(pre_parsed)
        section = EmployeeSection.from_pre_parsed(pre_parsed, std)
    else:
        section = EmployeeSection.from_xbrl(xbrl_path)
    return cast(dict[str, Any], extract_employees(section))


_extract_is_compat = _make_section_wrapper(IncomeStatementSection, extract_income_statement)
_extract_gp_compat = _make_section_wrapper(IncomeStatementSection, extract_gross_profit)
_extract_op_compat = _make_section_wrapper(IncomeStatementSection, extract_operating_profit)
_extract_ie_compat = _make_section_wrapper(IncomeStatementSection, extract_interest_expense)
_extract_tax_compat = _make_section_wrapper(IncomeStatementSection, extract_tax_expense)
_extract_nr_compat = _make_section_wrapper(IncomeStatementSection, extract_net_revenue)
_extract_cf_compat = _make_section_wrapper(CashFlowSection, extract_cash_flow)
_extract_capex_compat = _make_section_wrapper(CashFlowSection, extract_capital_expenditure)
_extract_buyback_compat = _make_section_wrapper(CashFlowSection, extract_share_buyback)
_extract_rd_compat = _make_section_wrapper(IncomeStatementSection, extract_research_development)
_extract_bs_compat = _make_section_wrapper(BalanceSheetSection, extract_balance_sheet)
_extract_ibd_compat = _make_section_wrapper(BalanceSheetSection, extract_interest_bearing_debt)
_extract_ppe_compat = _make_section_wrapper(BalanceSheetSection, extract_tangible_fixed_assets)
_extract_bank_compat = _make_section_wrapper(BalanceSheetSection, extract_bank_financials)

_SHAREHOLDER_CALCULATION_FIELDS: tuple[str, ...] = (
    # extract_shareholder_metrics() が返す検証・注記fallback由来の値を
    # 年次レコードへ渡す。新しい株主計算フィールドを追加したらここも更新する。
    "AverageShares",
    "TreasuryShares",
    "SharesForBPS",
    "ParentEquity",
    "StockSplitRatio",
    "CumulativeStockSplitRatio",
    "StockSplitEvents",
    "CalculatedEPS",
    "CalculatedBPS",
    "EPSDirectDiff",
    "BPSDirectDiff",
)


class _XbrlFinancials(TypedDict):
    sales: float | None
    sales_label: str | None
    operating_profit: float | None
    operating_profit_label: str | None
    net_profit: float | None
    accounting_standard: str | None
    net_assets: float | None
    cfo: float | None
    cfi: float | None
    capex: float | None
    buyback: float | None
    rd: float | None
    sh: ShareholderMetrics
    consolidation_scope: str  # "consolidated" | "nonconsolidated"


def _extract_xbrl_financials(entry: _PreParsedEntry) -> _XbrlFinancials:
    """XBRL entry から財務数値を抽出する（IS/GP/OP フォールバック連鎖 + BS + CF + 株主指標）。"""
    xbrl_path = entry[0]
    balance_pre_parsed = _preparsed_for_statement(entry, "bs")
    cash_flow_pre_parsed = _preparsed_for_statement(entry, "da")
    all_pre_parsed = entry[1]

    # IS は全セクションを対象にする: セクション絞り込みだと IFRS/US-GAAP セクションが漏れる
    is_result = _extract_is_compat(xbrl_path, pre_parsed=all_pre_parsed)
    sales: float | None = is_result.get("sales")
    operating_profit: float | None = is_result.get("operating_profit")
    operating_profit_label: str | None = None
    sales_label: str | None = is_result.get("sales_label", "売上高") if sales is not None else None
    if sales is None:
        gp_for_sales = _extract_gp_compat(xbrl_path, pre_parsed=all_pre_parsed)
        sales = gp_for_sales.get("current_sales")
        if sales is not None:
            sales_label = "経常収益"
        if sales is None:
            op_for_sales = _extract_op_compat(xbrl_path, pre_parsed=all_pre_parsed)
            sales = op_for_sales.get("current_sales")
            if sales is not None:
                sales_label = "経常収益"
    if operating_profit is None:
        op_result = _extract_op_compat(xbrl_path, pre_parsed=all_pre_parsed)
        operating_profit = op_result.get("current")
        operating_profit_label = op_result.get("label")
    bs_result = _extract_bs_compat(xbrl_path, pre_parsed=balance_pre_parsed)
    if not _result_has_signal(bs_result):
        bs_result = _extract_bs_compat(xbrl_path, pre_parsed=all_pre_parsed)
    cf_result = _extract_cf_compat(xbrl_path, pre_parsed=cash_flow_pre_parsed)
    if not _result_has_signal(cf_result):
        cf_result = _extract_cf_compat(xbrl_path, pre_parsed=all_pre_parsed)
    capex_result = _extract_capex_compat(xbrl_path, pre_parsed=all_pre_parsed)
    buyback_result = _extract_buyback_compat(xbrl_path, pre_parsed=cash_flow_pre_parsed)
    if not _result_has_signal(buyback_result):
        buyback_result = _extract_buyback_compat(xbrl_path, pre_parsed=all_pre_parsed)
    rd_result = _extract_rd_compat(xbrl_path, pre_parsed=all_pre_parsed)
    sh_result = extract_shareholder_metrics(
        xbrl_path,
        pre_parsed=all_pre_parsed,
        net_profit=is_result.get("net_profit"),
    )
    return _XbrlFinancials(
        sales=sales,
        sales_label=sales_label,
        operating_profit=operating_profit,
        operating_profit_label=operating_profit_label,
        net_profit=is_result.get("net_profit"),
        accounting_standard=is_result.get("accounting_standard"),
        net_assets=bs_result.get("net_assets"),
        cfo=cf_result["cfo"].get("current"),
        cfi=cf_result["cfi"].get("current"),
        capex=capex_result.get("current"),
        buyback=buyback_result.get("current"),
        rd=rd_result.get("current"),
        sh=sh_result,
        consolidation_scope="consolidated" if has_nonconsolidated_contexts(all_pre_parsed) else "nonconsolidated",
    )


def _build_xbrl_record(
    fin: _XbrlFinancials,
    code: str,
    doc_id: str | None,
    fy_end: str,
    fy_st: str,
    submit_date: str,
    period_type: str,
    *,
    period_start: str | None = None,
    period_end: str | None = None,
) -> dict[str, Any]:
    """財務抽出結果から XBRL 財務レコードを組み立てる。"""
    sh = fin["sh"]
    record: dict[str, Any] = {
        "Code": code,
        "CurFYEn": fy_end,
        "CurFYSt": fy_st,
        "CurPerType": period_type,
        "DiscDate": submit_date,
        "Sales": fin["sales"],
        "SalesLabel": fin["sales_label"],
        "OP": None if fin["operating_profit_label"] == "経常利益" else fin["operating_profit"],
        "NP": fin["net_profit"],
        "NetAssets": fin["net_assets"],
        "CFO": fin["cfo"],
        "CFI": fin["cfi"],
        "Capex": None if period_type == "2Q" else fin["capex"],
        "Buyback": None if period_type == "2Q" else fin["buyback"],
        "RD": None if period_type == "2Q" else fin["rd"],
        "EPS": sh.get("EPS"),
        "BPS": sh.get("BPS"),
        "ShOutFY": sh.get("ShOutFY"),
        "DivTotalAnn": sh.get("DivTotalAnn"),
        "PayoutRatioAnn": sh.get("PayoutRatioAnn"),
        "CashEq": sh.get("CashEq"),
        "DivAnn": sh.get("DivAnn"),
        "Div2Q": sh.get("Div2Q"),
        "_xbrl_source": True,
        "_accounting_standard": fin["accounting_standard"],
        "_consolidation_scope": fin["consolidation_scope"],
        "_docID": doc_id,
    }
    if period_start is not None:
        record["CurPerSt"] = period_start
    if period_end is not None:
        record["CurPerEn"] = period_end
    shareholder_metric_sources = sh.get("MetricSources")
    if isinstance(shareholder_metric_sources, dict) and shareholder_metric_sources:
        record["ShareholderMetricSources"] = shareholder_metric_sources
    for key in _SHAREHOLDER_CALCULATION_FIELDS:
        value = sh.get(key)
        if value is not None and value != []:
            record[key] = value
    return record
