"""
smoke/check.py — smoke_expected/*.json と実際の抽出値を比較し、差分を検出する。

本番ロジックを変更した後に実行し、意図しない値の変化がないかを確認する。
差分がある場合は exit(1)。

フィクスチャを直接編集するとチェックサム検証で弾かれる。
更新は update_fixtures.py --ticker XXXX で行う。

実行方法:
    poetry run python smoke/check.py           # 通常チェック
    poetry run python smoke/check.py --verbose  # 差分発生時にコンポーネント詳細を表示
"""
import argparse
import asyncio
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent.parent))

from _common import (
    FIXTURE_DIR,
    edinet_cache_dir,
    extract_actuals,
    has_any_expected_value,
    load_fixtures,
)

_CHECKSUM_FILE = FIXTURE_DIR / ".checksums.json"

_FLOAT_REL_TOL = 1e-4


def _verify_checksums() -> list[str]:
    """フィクスチャファイルの SHA-256 を .checksums.json と照合する。

    改ざん（直接編集）を検出したファイル名のリストを返す。
    .checksums.json が存在しない場合はエラーとして扱う。
    """
    if not _CHECKSUM_FILE.exists():
        return [".checksums.json が見つかりません — smoke/smoke_expected/.checksums.json を生成してください"]

    recorded: dict[str, str] = json.loads(_CHECKSUM_FILE.read_text(encoding="utf-8"))
    violations: list[str] = []

    for fixture_path in sorted(f for f in FIXTURE_DIR.glob("*.json") if not f.name.startswith(".")):
        expected_hash = recorded.get(fixture_path.name)
        if expected_hash is None:
            violations.append(f"{fixture_path.name}: チェックサム未登録（update_fixtures.py --ticker で追加してください）")
            continue
        actual_hash = hashlib.sha256(fixture_path.read_bytes()).hexdigest()
        if actual_hash != expected_hash:
            violations.append(f"{fixture_path.name}: チェックサム不一致（直接編集されています）")

    return violations


def _check_field(label: str, actual: Any, expected: Any) -> str | None:
    if expected is None:
        return None
    if isinstance(expected, float):
        if actual is None:
            return f"{label}: expected {expected:,.0f}, got None"
        rel = abs(actual - expected) / abs(expected) if expected != 0 else abs(actual)
        if rel > _FLOAT_REL_TOL:
            return f"{label}: expected {expected:,.0f}, got {actual:,.0f}  (rel {rel:.2e})"
    elif actual != expected:
        return f"{label}: expected {expected!r}, got {actual!r}"
    return None


def _compare(fixture: dict[str, Any], actuals: dict[str, Any]) -> list[str]:
    diffs: list[str] = []

    def chk(label: str, actual: Any, expected: Any) -> None:
        msg = _check_field(label, actual, expected)
        if msg:
            diffs.append(msg)

    exp_is = fixture.get("income_statement") or {}
    act_is = actuals.get("income_statement") or {}
    chk("income_statement.sales",                act_is.get("sales"),                exp_is.get("sales"))
    chk("income_statement.operating_profit",     act_is.get("operating_profit"),     exp_is.get("operating_profit"))
    chk("income_statement.net_profit",           act_is.get("net_profit"),           exp_is.get("net_profit"))
    chk("income_statement.accounting_standard",  act_is.get("accounting_standard"),  exp_is.get("accounting_standard"))

    exp_gp = fixture.get("gross_profit") or {}
    act_gp = actuals.get("gross_profit") or {}
    chk("gross_profit.gross_profit", act_gp.get("gross_profit"), exp_gp.get("gross_profit"))
    chk("gross_profit.method",       act_gp.get("method"),       exp_gp.get("method"))

    exp_sga = fixture.get("sga") or {}
    act_sga = actuals.get("sga") or {}
    chk("sga.current", act_sga.get("current"), exp_sga.get("current"))

    exp_bs = fixture.get("balance_sheet") or {}
    act_bs = actuals.get("balance_sheet") or {}
    chk("balance_sheet.total_assets",            act_bs.get("total_assets"),            exp_bs.get("total_assets"))
    chk("balance_sheet.current_assets",          act_bs.get("current_assets"),          exp_bs.get("current_assets"))
    chk("balance_sheet.non_current_assets",      act_bs.get("non_current_assets"),      exp_bs.get("non_current_assets"))
    chk("balance_sheet.current_liabilities",     act_bs.get("current_liabilities"),     exp_bs.get("current_liabilities"))
    chk("balance_sheet.non_current_liabilities", act_bs.get("non_current_liabilities"), exp_bs.get("non_current_liabilities"))
    chk("balance_sheet.net_assets",              act_bs.get("net_assets"),              exp_bs.get("net_assets"))
    chk("balance_sheet.accounting_standard",     act_bs.get("accounting_standard"),     exp_bs.get("accounting_standard"))

    exp_ibd = fixture.get("interest_bearing_debt") or {}
    act_ibd = actuals.get("interest_bearing_debt") or {}
    chk("interest_bearing_debt.total",  act_ibd.get("total"),  exp_ibd.get("total"))
    chk("interest_bearing_debt.method", act_ibd.get("method"), exp_ibd.get("method"))

    exp_cf = fixture.get("cash_flow") or {}
    act_cf = actuals.get("cash_flow") or {}
    chk("cash_flow.cfo", act_cf.get("cfo"), exp_cf.get("cfo"))
    chk("cash_flow.cfi", act_cf.get("cfi"), exp_cf.get("cfi"))

    exp_dep = fixture.get("depreciation") or {}
    act_dep = actuals.get("depreciation") or {}
    chk("depreciation.current", act_dep.get("current"), exp_dep.get("current"))

    exp_ie = fixture.get("interest_expense") or {}
    act_ie = actuals.get("interest_expense") or {}
    chk("interest_expense.current", act_ie.get("current"), exp_ie.get("current"))

    exp_emp = fixture.get("employees") or {}
    act_emp = actuals.get("employees") or {}
    chk("employees.current", act_emp.get("current"), exp_emp.get("current"))
    chk("employees.method",  act_emp.get("method"),  exp_emp.get("method"))

    exp_tax = fixture.get("tax_expense") or {}
    act_tax = actuals.get("tax_expense") or {}
    chk("tax_expense.pretax_income",      act_tax.get("pretax_income"),      exp_tax.get("pretax_income"))
    chk("tax_expense.income_tax",         act_tax.get("income_tax"),         exp_tax.get("income_tax"))
    chk("tax_expense.effective_tax_rate", act_tax.get("effective_tax_rate"), exp_tax.get("effective_tax_rate"))

    exp_ppe = fixture.get("tangible_fixed_assets") or {}
    act_ppe = actuals.get("tangible_fixed_assets") or {}
    chk("tangible_fixed_assets.total", act_ppe.get("total"), exp_ppe.get("total"))

    exp_ob = fixture.get("order_book") or {}
    act_ob = actuals.get("order_book") or {}
    chk("order_book.order_intake",  act_ob.get("order_intake"),  exp_ob.get("order_intake"))
    chk("order_book.order_backlog", act_ob.get("order_backlog"), exp_ob.get("order_backlog"))

    exp_bank = fixture.get("bank_financials") or {}
    act_bank = actuals.get("bank_financials") or {}
    chk("bank_financials.deposits",           act_bank.get("deposits"),           exp_bank.get("deposits"))
    chk("bank_financials.loans",              act_bank.get("loans"),              exp_bank.get("loans"))
    chk("bank_financials.cash_due_from_banks",act_bank.get("cash_due_from_banks"),exp_bank.get("cash_due_from_banks"))
    chk("bank_financials.negotiable_cds",     act_bank.get("negotiable_cds"),     exp_bank.get("negotiable_cds"))

    exp_cash_eq = fixture.get("cash_eq") or {}
    act_cash_eq = actuals.get("cash_eq") or {}
    chk("cash_eq.current", act_cash_eq.get("current"), exp_cash_eq.get("current"))

    exp_capex = fixture.get("capital_expenditure") or {}
    act_capex = actuals.get("capital_expenditure") or {}
    chk("capital_expenditure.current", act_capex.get("current"), exp_capex.get("current"))

    exp_rd = fixture.get("research_development") or {}
    act_rd = actuals.get("research_development") or {}
    chk("research_development.current", act_rd.get("current"), exp_rd.get("current"))

    exp_buyback = fixture.get("share_buyback") or {}
    act_buyback = actuals.get("share_buyback") or {}
    chk("share_buyback.current", act_buyback.get("current"), exp_buyback.get("current"))

    return diffs


def _fmt_component(label: str, tag: str | None, current: float | None) -> str:
    val = f"{current:,.0f}" if current is not None else "—"
    tag_str = f" [{tag}]" if tag else ""
    return f"    {label}{tag_str}: {val}"


def _print_ibd_debug(debug: dict[str, Any]) -> None:
    ibd_debug = debug.get("ibd") or {}
    method = ibd_debug.get("method") or "—"
    components: list[dict[str, Any]] = ibd_debug.get("components") or []
    print(f"  [IBD method: {method}]")
    for comp in components:
        line = _fmt_component(
            comp.get("label") or "?",
            comp.get("tag"),
            comp.get("current"),
        )
        print(line)


def _print_ppe_debug(debug: dict[str, Any]) -> None:
    ppe_debug = debug.get("ppe") or {}
    method = ppe_debug.get("method") or "—"
    others = ppe_debug.get("others")
    print(f"  [PPE method: {method}]")
    if others is not None:
        print(f"    その他 (合計−内訳): {others:,.0f}")


async def _main() -> int:
    parser = argparse.ArgumentParser(description="smoke check")
    parser.add_argument("--verbose", "-v", action="store_true", help="差分発生時にコンポーネント詳細を表示")
    args = parser.parse_args()

    violations = _verify_checksums()
    if violations:
        print("ERROR: フィクスチャの整合性チェック失敗", file=sys.stderr)
        for v in violations:
            print(f"  {v}", file=sys.stderr)
        print("  → フィクスチャの更新は update_fixtures.py --ticker XXXX で行ってください", file=sys.stderr)
        return 1

    cache_dir = edinet_cache_dir()
    if not cache_dir.is_dir():
        print(f"ERROR: XBRLキャッシュが見つかりません: {cache_dir}", file=sys.stderr)
        return 1

    fixtures = load_fixtures()
    if not fixtures:
        print("smoke_expected/ にフィクスチャファイルがありません", file=sys.stderr)
        return 1

    total_diffs = 0
    total_compared = 0
    for fixture_id, fixture in fixtures:
        if not has_any_expected_value(fixture):
            print(f"SKIP  {fixture_id}: 全フィールドが null")
            continue

        code: str = fixture["code"]
        fy_end: str = fixture["fy_end"]
        name: str = fixture.get("name", code)

        actuals = await extract_actuals(code, fy_end, cache_dir)
        if actuals is None:
            print(f"SKIP  {fixture_id}: キャッシュなし")
            continue

        total_compared += 1
        diffs = _compare(fixture, actuals)
        if diffs:
            print(f"\nDIFF  {name} ({fy_end})")
            for diff in diffs:
                print(f"  {diff}")
            if args.verbose:
                debug = actuals.get("_debug") or {}
                has_ibd_diff = any("interest_bearing_debt" in d for d in diffs)
                has_ppe_diff = any("tangible_fixed_assets" in d for d in diffs)
                if has_ibd_diff:
                    _print_ibd_debug(debug)
                if has_ppe_diff:
                    _print_ppe_debug(debug)
            total_diffs += len(diffs)
        else:
            print(f"OK    {name} ({fy_end})")

    if total_compared == 0:
        print("\nERROR: 比較できたフィクスチャが0件です。XBRLキャッシュを確認してください。", file=sys.stderr)
        return 1
    if total_diffs > 0:
        print(f"\n{total_diffs} 件の差分があります。意図的な変更なら update_fixtures.py を実行してください。")
        return 1
    print("\n全フィクスチャ一致。")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(_main()))
