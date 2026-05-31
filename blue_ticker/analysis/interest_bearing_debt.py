"""
有利子負債（IBD）XBRL抽出モジュール

BalanceSheetSection（FieldSet を内包）からの3ステージ抽出:
  Stage 1: XBRL XML → FieldSet  (Section 構築時に実施)
  Stage 2: HTML 補完            (Section 構築時に US-GAAP 企業のみ実施)
  Stage 3: FieldSet → IBD値     (resolve_ibd: 直接法 → IFRS集約 → コンポーネント積み上げ → HTML仮想タグ)

有利子負債の定義:
  短期借入金 + CP + 短期社債 + 1年内社債 + 1年内長期借入金 + 社債 + 長期借入金 + リース負債（IFRS 16）
"""

from blue_ticker.analysis.field_parser import ResolvedItem
from blue_ticker.analysis.sections import BalanceSheetSection
from blue_ticker.analysis.xbrl_utils import extract_ifrs_textblock_table, find_xbrl_files
from blue_ticker.constants.financial import MILLION_YEN
from blue_ticker.constants.xbrl import (
    COMPONENT_DEFINITIONS,
    IBD_CURRENT_COMPONENTS,
    IBD_IFRS_CL_TAGS,
    IBD_IFRS_NCL_TAGS,
    IBD_NON_CURRENT_COMPONENTS,
)
from blue_ticker.utils.xbrl_result_types import InterestBearingDebtResult, MetricComponent

# XBRL タグ名 → 人間可読ラベル（コンポーネント表示・テスト互換性のため）
_TAG_TO_LABEL: dict[str, str] = {
    tag: comp["label"]
    for comp in COMPONENT_DEFINITIONS
    for tag in comp["tags"]
}

_IFRS_BS_TEXTBLOCK_TAG = "ConsolidatedStatementOfFinancialPositionIFRSTextBlock"
_IFRS_LEASE_TEXTBLOCK_TAG = "NotesLeasesConsolidatedFinancialStatementsIFRSTextBlock"

# IFRS連結財政状態計算書 TextBlock から集計する有利子負債コンポーネント定義
# (HTMLラベル, 表示ラベル) のリスト。HTMLの表示順（流動→非流動）で定義する。
_IFRS_TEXTBLOCK_IBD_LABELS: list[tuple[str, str]] = [
    ("短期借入金",               "短期借入金"),
    ("コマーシャル・ペーパー",   "コマーシャル・ペーパー"),
    ("１年内償還予定の社債",     "1年内償還予定の社債"),
    ("１年内返済予定の長期借入金", "1年内返済予定の長期借入金"),
    ("社債",                    "社債"),
    ("長期借入金",               "長期借入金"),
]


def _extract_ifrs_ibd_from_textblock(section: BalanceSheetSection) -> InterestBearingDebtResult | None:
    """IFRS連結財政状態計算書TextBlockから有利子負債を積み上げ抽出する。"""
    if section.xbrl_dir is None:
        return None
    table = extract_ifrs_textblock_table(section.xbrl_dir, _IFRS_BS_TEXTBLOCK_TAG)
    if not table:
        return None

    components: list[MetricComponent] = []
    current_total = prior_total = 0.0
    has_current = has_prior = False

    for html_label, display_label in _IFRS_TEXTBLOCK_IBD_LABELS:
        vals = table.get(html_label)
        if vals is None:
            continue
        c_m, p_m = vals
        c_yen = c_m * MILLION_YEN if c_m is not None else None
        p_yen = p_m * MILLION_YEN if p_m is not None else None
        if c_m is not None:
            current_total += c_m
            has_current = True
        if p_m is not None:
            prior_total += p_m
            has_prior = True
        components.append({
            "label": display_label,
            "tag": f"IFRS_HTML_{html_label}",
            "current": c_yen,
            "prior": p_yen,
        })

    if not has_current and not has_prior:
        return None

    return {
        "current": current_total * MILLION_YEN if has_current else None,
        "prior": prior_total * MILLION_YEN if has_prior else None,
        "method": "ifrs_textblock",
        "accounting_standard": "IFRS",
        "components": components,
    }


def _extract_ifrs_lease_liabilities(
    section: BalanceSheetSection,
) -> tuple[float | None, float | None, list[MetricComponent]]:
    """IFRS リース注記TextBlockからリース負債残高を抽出する。

    パターンA（支払期日が1年以内 / 1年超）: 流動・非流動を個別取得して積み上げ。
    パターンB（帳簿価額）: 合計のみ取得。

    Returns:
        (current_yen, prior_yen, components)。取得できない場合は (None, None, [])。
    """
    if section.xbrl_dir is None:
        return None, None, []
    table = extract_ifrs_textblock_table(section.xbrl_dir, _IFRS_LEASE_TEXTBLOCK_TAG)
    if not table:
        return None, None, []

    # パターンA: 「支払期日が1年以内」「支払期日が1年超」
    cl_vals = table.get("支払期日が1年以内")
    ncl_vals = table.get("支払期日が1年超")
    if cl_vals is not None or ncl_vals is not None:
        components: list[MetricComponent] = []
        c_total = p_total = 0.0
        has_c = has_p = False
        for vals, label in [(cl_vals, "リース負債（流動）"), (ncl_vals, "リース負債（非流動）")]:
            if vals is None:
                continue
            c_m, p_m = vals
            if c_m is not None:
                c_total += c_m
                has_c = True
            if p_m is not None:
                p_total += p_m
                has_p = True
            components.append({
                "label": label,
                "tag": None,
                "current": c_m * MILLION_YEN if c_m is not None else None,
                "prior": p_m * MILLION_YEN if p_m is not None else None,
            })
        return (
            c_total * MILLION_YEN if has_c else None,
            p_total * MILLION_YEN if has_p else None,
            components,
        )

    # パターンB: 「帳簿価額」（スズキ型: 合計のみ）
    bv_vals = table.get("帳簿価額")
    if bv_vals is not None:
        c_m, p_m = bv_vals
        return (
            c_m * MILLION_YEN if c_m is not None else None,
            p_m * MILLION_YEN if p_m is not None else None,
            [{
                "label": "リース負債",
                "tag": None,
                "current": c_m * MILLION_YEN if c_m is not None else None,
                "prior": p_m * MILLION_YEN if p_m is not None else None,
            }],
        )

    # パターンC: 「リース負債の現在価値」（クボタ型: 割引後現在価値合計）
    pv_vals = table.get("リース負債の現在価値")
    if pv_vals is not None:
        c_m, p_m = pv_vals
        return (
            c_m * MILLION_YEN if c_m is not None else None,
            p_m * MILLION_YEN if p_m is not None else None,
            [{
                "label": "リース負債",
                "tag": None,
                "current": c_m * MILLION_YEN if c_m is not None else None,
                "prior": p_m * MILLION_YEN if p_m is not None else None,
            }],
        )

    return None, None, []


def _extract_usgaap_lease_liabilities(
    section: BalanceSheetSection,
) -> tuple[float | None, float | None, list[MetricComponent]]:
    """US-GAAP BS HTMLからオペレーティング・リース負債残高を抽出する（ASC 842）。

    Returns:
        (current_yen, prior_yen, components)。取得できない場合は (None, None, [])。
    """
    cl_fv = section.resolve(["USGAAP_HTML_LeaseLiabilitiesCurrent"])
    ncl_fv = section.resolve(["USGAAP_HTML_LeaseLiabilitiesNonCurrent"])
    cl_c = cl_fv["current"] if cl_fv["tag"] else None
    cl_p = cl_fv["prior"] if cl_fv["tag"] else None
    ncl_c = ncl_fv["current"] if ncl_fv["tag"] else None
    ncl_p = ncl_fv["prior"] if ncl_fv["tag"] else None

    if cl_c is None and ncl_c is None:
        return None, None, []

    total_c = (cl_c or 0.0) + (ncl_c or 0.0)
    total_p = ((cl_p or 0.0) + (ncl_p or 0.0)) if (cl_p is not None or ncl_p is not None) else None
    components: list[MetricComponent] = []
    if cl_c is not None:
        components.append({"label": "リース負債（流動）", "tag": None, "current": cl_c, "prior": cl_p})
    if ncl_c is not None:
        components.append({"label": "リース負債（非流動）", "tag": None, "current": ncl_c, "prior": ncl_p})
    return total_c, total_p, components


def resolve_ibd(section: BalanceSheetSection) -> ResolvedItem:
    """貸借対照表セクションから有利子負債を解決する。

    解決順: 直接法 → IFRS集約タグ → コンポーネント積み上げ → US-GAAP HTML仮想タグ。
    scripts から直接呼び出すことを想定して公開関数とする。
    """
    direct = section.resolve(["InterestBearingDebt", "InterestBearingLiabilities"])
    if direct["tag"]:
        return direct

    ifrs_agg = section.resolve_aggregate([IBD_IFRS_CL_TAGS, IBD_IFRS_NCL_TAGS])
    if ifrs_agg["tag"]:
        return ifrs_agg

    comp = section.resolve_aggregate(IBD_CURRENT_COMPONENTS + IBD_NON_CURRENT_COMPONENTS)
    if comp["tag"]:
        return comp

    return section.resolve_aggregate([["USGAAP_HTML_IBDCurrent"], ["USGAAP_HTML_IBDNonCurrent"]])


def extract_interest_bearing_debt(section: BalanceSheetSection) -> InterestBearingDebtResult:
    """貸借対照表セクションから有利子負債を構成要素ごとに抽出する。"""
    accounting_standard = section.accounting_standard

    resolved = resolve_ibd(section)
    tag, current, prior = resolved["tag"], resolved["current"], resolved["prior"]

    if tag is None:
        # IFRS Summary型XBRLでは連結借入金タグが存在しないため、TextBlockから抽出する。
        if accounting_standard == "IFRS":
            textblock_result = _extract_ifrs_ibd_from_textblock(section)
            if textblock_result is not None:
                result = textblock_result
            else:
                # TextBlock失敗時は全会計基準共通のzero_debtフォールバックへ続行する
                if section.xbrl_dir is not None:
                    xbrl_files = find_xbrl_files(section.xbrl_dir)
                    if any(f.stat().st_size > 100_000 for f in xbrl_files):
                        result = {
                            "current": 0.0,
                            "prior": 0.0,
                            "method": "zero_debt",
                            "accounting_standard": accounting_standard,
                            "components": [],
                        }
                    else:
                        return {
                            "current": None,
                            "prior": None,
                            "method": "not_found",
                            "accounting_standard": accounting_standard,
                            "components": [],
                            "reason": "有利子負債タグが見つからない",
                        }
                else:
                    return {
                        "current": None,
                        "prior": None,
                        "method": "not_found",
                        "accounting_standard": accounting_standard,
                        "components": [],
                        "reason": "有利子負債タグが見つからない",
                    }
        else:
            if section.xbrl_dir is not None:
                xbrl_files = find_xbrl_files(section.xbrl_dir)
                if any(f.stat().st_size > 100_000 for f in xbrl_files):
                    return {
                        "current": 0.0,
                        "prior": 0.0,
                        "method": "zero_debt",
                        "accounting_standard": accounting_standard,
                        "components": [],
                    }
            return {
                "current": None,
                "prior": None,
                "method": "not_found",
                "accounting_standard": accounting_standard,
                "components": [],
                "reason": "有利子負債タグが見つからない",
            }
    else:
        def _component(t: str) -> MetricComponent:
            fv = section.field_value(t)
            return {
                "label": _TAG_TO_LABEL.get(t, t),
                "tag": t,
                "current": fv["current"] if fv is not None else None,
                "prior": fv["prior"] if fv is not None else None,
            }

        components: list[MetricComponent] = [_component(t) for t in (tag.split("+") if tag else [])]
        result = {
            "current": current,
            "prior": prior,
            "method": "field_parser",
            "accounting_standard": accounting_standard,
            "components": components,
        }

    # IFRS適用企業: リース負債を追加
    if accounting_standard == "IFRS":
        lease_c, lease_p, lease_comps = _extract_ifrs_lease_liabilities(section)
        if lease_c is not None or lease_p is not None:
            existing_c = result["current"]
            existing_p = result["prior"]
            result: InterestBearingDebtResult = {
                "current": (existing_c or 0.0) + (lease_c or 0.0),
                "prior": (existing_p or 0.0) + (lease_p or 0.0),
                "method": result["method"] + "+lease_textblock",
                "accounting_standard": accounting_standard,
                "components": result["components"] + lease_comps,
            }

    # US-GAAP適用企業: オペレーティング・リース負債を追加（ASC 842）
    if accounting_standard == "US-GAAP":
        lease_c, lease_p, lease_comps = _extract_usgaap_lease_liabilities(section)
        if lease_c is not None:
            existing_c = result["current"]
            existing_p = result["prior"]
            result = {
                "current": (existing_c or 0.0) + lease_c,
                "prior": ((existing_p or 0.0) + lease_p) if lease_p is not None else existing_p,
                "method": result["method"] + "+lease_html",
                "accounting_standard": accounting_standard,
                "components": result["components"] + lease_comps,
            }

    return result
