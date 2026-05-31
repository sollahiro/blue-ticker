"""
有形固定資産（PPE）XBRL抽出モジュール

BalanceSheetSection（FieldSet を内包）から帳簿価額を抽出する。

抽出項目:
  建物及び構築物 / 土地 / 機械装置及び運搬具 / 工具器具及び備品 / 建設仮勘定 / 合計
  その他 = 合計 − 抽出5項目の合計（少なくとも1項目が取得できた場合のみ算出）

帳簿価額の取得方法（優先順）:
  1. 直接タグ（*IFRS / *Net サフィックス）
  2. 取得原価タグ − 累計減価償却・減損タグ（IFRS 直接タグが存在しない場合のフォールバック）
  3. 賃貸用車両タグ（IFRS tools のみ）

会計基準別タグ優先順:
  IFRS  : *IFRS サフィックス付きタグ → cost-dep 差引 → leased vehicles（tools のみ）
  J-GAAP: *Net サフィックス付きタグ（帳簿価額）。土地・建設仮勘定は Net なし
  US-GAAP: 合計のみ（個別内訳はタグ不足のため None）
"""

from blue_ticker.analysis.sections import BalanceSheetSection
from blue_ticker.constants.xbrl import (
    PPE_BUILDINGS_COST_TAGS,
    PPE_BUILDINGS_DEP_TAGS,
    PPE_BUILDINGS_IFRS_DIRECT,
    PPE_BUILDINGS_JGAAP_DIRECT,
    PPE_BUILDINGS_ONLY_JGAAP_TAGS,
    PPE_CONSTRUCTION_COST_TAGS,
    PPE_CONSTRUCTION_DEP_TAGS,
    PPE_CONSTRUCTION_IFRS_DIRECT,
    PPE_CONSTRUCTION_JGAAP_DIRECT,
    PPE_LAND_COST_TAGS,
    PPE_LAND_DEP_TAGS,
    PPE_LAND_IFRS_DIRECT,
    PPE_LAND_JGAAP_DIRECT,
    PPE_LEASED_VEHICLES_COST_TAGS,
    PPE_LEASED_VEHICLES_DEP_TAGS,
    PPE_MACHINERY_COST_TAGS,
    PPE_MACHINERY_DEP_TAGS,
    PPE_MACHINERY_IFRS_DIRECT,
    PPE_MACHINERY_JGAAP_DIRECT,
    PPE_STRUCTURES_JGAAP_TAGS,
    PPE_TAGS_USGAAP_TOTAL,
    PPE_TOOLS_IFRS_DIRECT,
    PPE_TOOLS_JGAAP_DIRECT,
    PPE_TOTAL_COST_TAGS,
    PPE_TOTAL_DEP_TAGS,
    PPE_TOTAL_IFRS_DIRECT,
    PPE_TOTAL_JGAAP_DIRECT,
)
from blue_ticker.utils.xbrl_result_types import TangibleFixedAssetsResult


def _net_value(
    section: BalanceSheetSection,
    cost_tags: list[str],
    dep_tags: list[str],
) -> float | None:
    """取得原価タグと累計減価償却・減損タグから帳簿価額を計算する。"""
    cost = section.resolve(cost_tags)["current"]
    if cost is None:
        return None
    dep = section.resolve(dep_tags)["current"]
    return cost + (dep if dep is not None else 0.0)


def _resolve_ppe_item(section: BalanceSheetSection, tags: list[str]) -> float | None:
    """PPE 内訳タグを解決する。0.0 は nil 起源の可能性が高いため None として扱う。"""
    val = section.resolve(tags)["current"]
    return None if val == 0.0 else val


def extract_tangible_fixed_assets(section: BalanceSheetSection) -> TangibleFixedAssetsResult:
    """貸借対照表セクションから有形固定資産の帳簿価額を抽出する。"""
    accounting_standard = section.accounting_standard

    if accounting_standard == "IFRS":
        total = section.resolve(PPE_TOTAL_IFRS_DIRECT)["current"]
        if total is None:
            total = _net_value(section, PPE_TOTAL_COST_TAGS, PPE_TOTAL_DEP_TAGS)
    elif accounting_standard == "J-GAAP":
        total = section.resolve(PPE_TOTAL_JGAAP_DIRECT)["current"]
    else:
        total = section.resolve(PPE_TAGS_USGAAP_TOTAL)["current"]

    if total is None:
        return {
            "buildings": None,
            "land": None,
            "machinery": None,
            "tools": None,
            "construction_in_progress": None,
            "others": None,
            "total": None,
            "method": "not_found",
            "accounting_standard": accounting_standard,
            "reason": "有形固定資産タグが見つからない",
        }

    if accounting_standard == "IFRS":
        buildings = section.resolve(PPE_BUILDINGS_IFRS_DIRECT)["current"]
        if buildings is None:
            buildings = _net_value(section, PPE_BUILDINGS_COST_TAGS, PPE_BUILDINGS_DEP_TAGS)

        land = section.resolve(PPE_LAND_IFRS_DIRECT)["current"]
        if land is None:
            land = _net_value(section, PPE_LAND_COST_TAGS, PPE_LAND_DEP_TAGS)

        machinery = section.resolve(PPE_MACHINERY_IFRS_DIRECT)["current"]
        if machinery is None:
            machinery = _net_value(section, PPE_MACHINERY_COST_TAGS, PPE_MACHINERY_DEP_TAGS)

        tools = section.resolve(PPE_TOOLS_IFRS_DIRECT)["current"]
        if tools is None:
            tools = _net_value(section, PPE_LEASED_VEHICLES_COST_TAGS, PPE_LEASED_VEHICLES_DEP_TAGS)

        construction = section.resolve(PPE_CONSTRUCTION_IFRS_DIRECT)["current"]
        if construction is None:
            construction = _net_value(section, PPE_CONSTRUCTION_COST_TAGS, PPE_CONSTRUCTION_DEP_TAGS)

    elif accounting_standard == "J-GAAP":
        buildings = _resolve_ppe_item(section, PPE_BUILDINGS_JGAAP_DIRECT)
        if buildings is None:
            # 建物・構築物が個別タグで報告されている場合は合算する
            b = _resolve_ppe_item(section, PPE_BUILDINGS_ONLY_JGAAP_TAGS)
            s = _resolve_ppe_item(section, PPE_STRUCTURES_JGAAP_TAGS)
            if b is not None or s is not None:
                buildings = (b or 0.0) + (s or 0.0)
        land = _resolve_ppe_item(section, PPE_LAND_JGAAP_DIRECT)
        machinery = _resolve_ppe_item(section, PPE_MACHINERY_JGAAP_DIRECT)
        tools = _resolve_ppe_item(section, PPE_TOOLS_JGAAP_DIRECT)
        construction = _resolve_ppe_item(section, PPE_CONSTRUCTION_JGAAP_DIRECT)

    else:  # US-GAAP
        # 建物・機械は取得原価（gross）で開示。減価償却累計額は合計のみ開示のため per-item 純額不明
        # 土地・建設仮勘定は非償却資産のため取得原価 = 帳簿価額
        buildings = section.resolve(["USGAAP_HTML_BuildingsGross"])["current"]
        land = section.resolve(["USGAAP_HTML_Land"])["current"]
        machinery = section.resolve(["USGAAP_HTML_MachineryGross"])["current"]
        tools = None
        construction = section.resolve(["USGAAP_HTML_ConstructionInProgress"])["current"]

    known = [v for v in (buildings, land, machinery, tools, construction) if v is not None]
    if accounting_standard == "US-GAAP":
        # US-GAAP の buildings/machinery は取得原価（gross）のため、net 合計との差引は無意味
        others: float | None = None
    else:
        others = total - sum(known) if known else None

    return {
        "buildings": buildings,
        "land": land,
        "machinery": machinery,
        "tools": tools,
        "construction_in_progress": construction,
        "others": others,
        "total": total,
        "method": "field_parser",
        "accounting_standard": accounting_standard,
    }
