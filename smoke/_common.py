"""check.py / update_fixtures.py 共通の抽出ロジック。"""
import asyncio
import json
import os
from pathlib import Path
from typing import Any

from blue_ticker.analysis.balance_sheet import extract_balance_sheet
from blue_ticker.analysis.bank_financials import extract_bank_financials
from blue_ticker.analysis.cash_flow import extract_cash_flow
from blue_ticker.analysis.depreciation import extract_depreciation
from blue_ticker.analysis.employees import extract_employees
from blue_ticker.analysis.gross_profit import extract_gross_profit
from blue_ticker.analysis.income_statement import extract_income_statement
from blue_ticker.analysis.interest_bearing_debt import extract_interest_bearing_debt
from blue_ticker.analysis.interest_expense import extract_interest_expense
from blue_ticker.analysis.order_book import extract_order_book
from blue_ticker.analysis.sections import (
    BalanceSheetSection,
    CashFlowSection,
    EmployeeSection,
    IncomeStatementSection,
    detect_accounting_standard,
)
from blue_ticker.analysis.tangible_fixed_assets import extract_tangible_fixed_assets
from blue_ticker.analysis.tax_expense import extract_tax_expense
from blue_ticker.services.edinet_fetcher import EdinetFetcher
from blue_ticker.utils.fiscal_year import normalize_date_format

FIXTURE_DIR = Path(__file__).parent / "smoke_expected"
_DEFAULT_CACHE_DIR = Path("tmp_cache") / "edinet"


def edinet_cache_dir() -> Path:
    return Path(
        os.environ.get("BLUE_TICKER_EDINET_SMOKE_CACHE_DIR")
        or os.environ.get("MEBUKI_EDINET_SMOKE_CACHE_DIR")
        or str(_DEFAULT_CACHE_DIR)
    )


def load_fixtures() -> list[tuple[str, dict[str, Any]]]:
    if not FIXTURE_DIR.is_dir():
        return []
    return [
        (path.stem, json.loads(path.read_text(encoding="utf-8")))
        for path in sorted(FIXTURE_DIR.glob("*.json"))
    ]


def has_any_expected_value(fixture: dict[str, Any]) -> bool:
    for key, val in fixture.items():
        if key.startswith("_") or key in ("code", "name", "fy_end"):
            continue
        if isinstance(val, dict):
            if any(v is not None for v in val.values()):
                return True
        elif val is not None:
            return True
    return False


class _CachedXbrlClient:
    api_key = "cached-smoke"

    def __init__(self, cache_dir: Path) -> None:
        self.edinet_cache_dir = cache_dir

    async def download_document(self, doc_id: str, doc_type: int = 1) -> str | None:
        xbrl_dir = self.edinet_cache_dir / f"{doc_id}_xbrl"
        return str(xbrl_dir) if xbrl_dir.is_dir() else None


def _load_search_cache_docs(cache_dir: Path) -> list[dict[str, Any]]:
    docs: list[dict[str, Any]] = []
    for path in sorted(cache_dir.glob("search_*.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(payload, list):
            docs.extend(doc for doc in payload if isinstance(doc, dict))
    return docs


def find_cached_doc(code: str, fy_end: str, cache_dir: Path) -> dict[str, Any] | None:
    sec_code = f"{code}0"
    for doc in _load_search_cache_docs(cache_dir):
        if doc.get("secCode") != sec_code:
            continue
        if doc.get("docTypeCode") != "120":
            continue
        doc_id = doc.get("docID")
        period_end = doc.get("periodEnd")
        if not isinstance(doc_id, str) or not isinstance(period_end, str):
            continue
        if (normalize_date_format(period_end) or period_end) != fy_end:
            continue
        if not (cache_dir / f"{doc_id}_xbrl").is_dir():
            continue
        result = doc.copy()
        result["edinet_fy_end"] = normalize_date_format(period_end) or period_end
        return result
    return None


async def extract_actuals(code: str, fy_end: str, cache_dir: Path) -> dict[str, Any] | None:
    doc = find_cached_doc(code, fy_end, cache_dir)
    if doc is None:
        return None

    client = _CachedXbrlClient(cache_dir)
    fetcher = EdinetFetcher(edinet_client=client)  # type: ignore[arg-type]
    financial_record = {
        "CurPerType": "FY",
        "CurFYEn": fy_end,
        "DiscDate": normalize_date_format(str(doc.get("submitDateTime") or "")) or "",
        "_docID": doc["docID"],
    }
    pre_parsed_map = await fetcher.predownload_and_parse(code, [financial_record], max_years=1)
    fy_key = fy_end.replace("-", "")
    if fy_key not in pre_parsed_map:
        return None

    xbrl_dir_str, pre_parsed, facts = pre_parsed_map[fy_key]
    xbrl_dir = Path(xbrl_dir_str) if xbrl_dir_str else None

    std = detect_accounting_standard(pre_parsed)
    is_section = IncomeStatementSection.from_pre_parsed(pre_parsed, std, xbrl_dir)
    bs_section = BalanceSheetSection.from_pre_parsed(pre_parsed, std, xbrl_dir)
    cf_section = CashFlowSection.from_pre_parsed(pre_parsed, std, xbrl_dir)
    emp_section = EmployeeSection.from_pre_parsed(pre_parsed, std)

    income = extract_income_statement(is_section)
    gp = extract_gross_profit(is_section)
    bs = extract_balance_sheet(bs_section)
    bank = extract_bank_financials(bs_section)
    ibd = extract_interest_bearing_debt(bs_section)
    cf = extract_cash_flow(cf_section)
    dep = extract_depreciation(cf_section)
    ie = extract_interest_expense(is_section)
    emp = extract_employees(emp_section)
    tax = extract_tax_expense(is_section)
    ppe = extract_tangible_fixed_assets(bs_section)
    ob = extract_order_book(xbrl_dir or Path(), pre_parsed=pre_parsed)

    return {
        "income_statement": {
            "sales": income.get("sales"),
            "operating_profit": income.get("operating_profit"),
            "net_profit": income.get("net_profit"),
            "accounting_standard": income.get("accounting_standard"),
        },
        "gross_profit": {
            "gross_profit": gp.get("current"),
            "method": gp.get("method"),
        },
        "balance_sheet": {
            "total_assets": bs.get("total_assets"),
            "current_assets": bs.get("current_assets"),
            "non_current_assets": bs.get("non_current_assets"),
            "current_liabilities": bs.get("current_liabilities"),
            "non_current_liabilities": bs.get("non_current_liabilities"),
            "net_assets": bs.get("net_assets"),
            "accounting_standard": bs.get("accounting_standard"),
        },
        "interest_bearing_debt": {
            "total": ibd.get("current"),
            "method": ibd.get("method"),
        },
        "cash_flow": {
            "cfo": cf.get("cfo", {}).get("current"),
            "cfi": cf.get("cfi", {}).get("current"),
        },
        "depreciation": {
            "current": dep.get("current"),
        },
        "interest_expense": {
            "current": ie.get("current"),
        },
        "employees": {
            "current": emp.get("current"),
            "method": emp.get("method"),
        },
        "tax_expense": {
            "pretax_income": tax.get("pretax_income"),
            "income_tax": tax.get("income_tax"),
            "effective_tax_rate": tax.get("effective_tax_rate"),
        },
        "tangible_fixed_assets": {
            "total": ppe.get("total"),
            "buildings": ppe.get("buildings"),
            "land": ppe.get("land"),
            "machinery": ppe.get("machinery"),
            "tools": ppe.get("tools"),
            "construction_in_progress": ppe.get("construction_in_progress"),
        },
        "order_book": {
            "order_intake": ob.get("order_intake"),
            "order_backlog": ob.get("order_backlog"),
        },
        "bank_financials": {
            "deposits": bank.get("deposits"),
            "loans": bank.get("loans"),
            "cash_due_from_banks": bank.get("cash_due_from_banks"),
            "negotiable_cds": bank.get("negotiable_cds"),
        },
        "_debug": {
            "ibd": {
                "method": ibd.get("method"),
                "components": ibd.get("components", []),
            },
            "ppe": {
                "method": ppe.get("method"),
                "accounting_standard": ppe.get("accounting_standard"),
                "others": ppe.get("others"),
            },
        },
    }


def fmt(v: object) -> str:
    if v is None:
        return "—"
    if isinstance(v, float):
        return f"{v:,.0f}"
    if isinstance(v, int):
        return f"{v:,}"
    return str(v)


def print_table(name: str, fy_end: str, a: dict[str, Any]) -> None:
    is_ = a["income_statement"]
    gp = a["gross_profit"]
    bs = a["balance_sheet"]
    bank = a.get("bank_financials") or {}
    ibd = a["interest_bearing_debt"]
    cf = a["cash_flow"]
    dep = a["depreciation"]
    ie = a["interest_expense"]
    emp = a["employees"]
    tax = a["tax_expense"]
    ppe = a["tangible_fixed_assets"]
    ob = a["order_book"]
    std = is_.get("accounting_standard", "—")
    print(f"\n{'='*60}")
    print(f"  {name}  ({fy_end})  [{std}]")
    print(f"{'='*60}")
    rows = [
        ("売上高",               fmt(is_.get("sales"))),
        ("営業利益",             fmt(is_.get("operating_profit"))),
        ("純利益",               fmt(is_.get("net_profit"))),
        ("売上総利益",           f"{fmt(gp.get('gross_profit'))}  [{gp.get('method','—')}]"),
        ("総資産",               fmt(bs.get("total_assets"))),
        ("流動資産",             fmt(bs.get("current_assets"))),
        ("固定資産",             fmt(bs.get("non_current_assets"))),
        ("流動負債",             fmt(bs.get("current_liabilities"))),
        ("固定負債",             fmt(bs.get("non_current_liabilities"))),
        ("純資産",               fmt(bs.get("net_assets"))),
        ("有利子負債",           f"{fmt(ibd.get('total'))}  [{ibd.get('method','—')}]"),
        ("営業CF",               fmt(cf.get("cfo"))),
        ("投資CF",               fmt(cf.get("cfi"))),
        ("減価償却費",           fmt(dep.get("current"))),
        ("支払利息",             fmt(ie.get("current"))),
        ("従業員数",             f"{fmt(emp.get('current'))}  [{emp.get('method','—')}]"),
        ("税引前利益",           fmt(tax.get("pretax_income"))),
        ("法人税等",             fmt(tax.get("income_tax"))),
        ("実効税率(比率)",       f"{tax.get('effective_tax_rate'):.4f}" if tax.get("effective_tax_rate") is not None else "—"),
        ("有形固定資産 合計",     fmt(ppe.get("total"))),
        ("　建物及び構築物",     fmt(ppe.get("buildings"))),
        ("　土地",               fmt(ppe.get("land"))),
        ("　機械装置及び運搬具", fmt(ppe.get("machinery"))),
        ("　工具器具及び備品",   fmt(ppe.get("tools"))),
        ("　建設仮勘定",         fmt(ppe.get("construction_in_progress"))),
        ("受注高",               fmt(ob.get("order_intake"))),
        ("受注残高",             fmt(ob.get("order_backlog"))),
        ("預金",                 fmt(bank.get("deposits"))),
        ("貸出金",               fmt(bank.get("loans"))),
        ("現金預け金",           fmt(bank.get("cash_due_from_banks"))),
        ("譲渡性預金",           fmt(bank.get("negotiable_cds"))),
    ]
    for label, val in rows:
        print(f"  {label:<18}  {val}")
