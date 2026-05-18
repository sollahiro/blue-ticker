"""
貸借対照表（BS）XBRL抽出モジュール

BalanceSheetSection（FieldSet を内包）からの3ステージ抽出:
  Stage 1: XBRL XML → FieldSet  (Section 構築時に実施)
  Stage 2: HTML 補完            (Section 構築時に US-GAAP 企業のみ実施)
  Stage 3: FieldSet → 財務項目値 (resolve / resolve_aggregate / derive_subtraction)
"""

from blue_ticker.analysis.sections import BalanceSheetSection
from blue_ticker.constants.xbrl import ALL_STANDARD_BS_ITEMS, USGAAP_HTML_NCA_COMPONENTS, USGAAP_XBRL_NCA_COMPONENTS
from blue_ticker.utils.xbrl_result_types import BalanceSheetResult, MetricComponent


def extract_balance_sheet(section: BalanceSheetSection) -> BalanceSheetResult:
    """貸借対照表セクションから主要な貸借対照表項目を抽出する。"""
    accounting_standard = section.accounting_standard

    components: list[MetricComponent] = []
    label_to_value: dict[str, float | None] = {}

    for item_def in ALL_STANDARD_BS_ITEMS:
        resolved = section.resolve(item_def["tags"])
        if resolved["tag"] is None and "derive" in item_def:
            d = item_def["derive"]
            resolved = section.derive_subtraction(d["minuend_tags"], d["subtrahend_tags"])
        if item_def["field"] == "NonCurrentAssets" and resolved["current"] is None:
            resolved = section.resolve_aggregate(USGAAP_HTML_NCA_COMPONENTS)
        if item_def["field"] == "NonCurrentAssets" and resolved["current"] is None:
            resolved = section.resolve_aggregate(USGAAP_XBRL_NCA_COMPONENTS)

        components.append({
            "label": item_def["label"],
            "tag": resolved["tag"],
            "current": resolved["current"],
            "prior": resolved["prior"],
        })
        label_to_value[item_def["label"]] = resolved["current"]

    total_assets = label_to_value.get("資産合計")
    current_assets = label_to_value.get("流動資産")
    non_current_assets = label_to_value.get("非流動資産")
    current_liabilities = label_to_value.get("流動負債")
    non_current_liabilities = label_to_value.get("非流動負債")
    net_assets = label_to_value.get("純資産/資本合計")

    prior_net_assets: float | None = next(
        (c["prior"] for c in components if c["label"] == "純資産/資本合計" and c["prior"] is not None),
        None,
    )

    has_any = any(
        v is not None
        for v in [total_assets, current_assets, non_current_assets,
                  current_liabilities, non_current_liabilities, net_assets]
    )

    result: BalanceSheetResult = {
        "total_assets": total_assets,
        "current_assets": current_assets,
        "non_current_assets": non_current_assets,
        "current_liabilities": current_liabilities,
        "non_current_liabilities": non_current_liabilities,
        "net_assets": net_assets,
        "accounting_standard": accounting_standard,
        "method": "field_parser" if has_any else "not_found",
        "components": components,
        "prior_net_assets": prior_net_assets,
    }
    if not has_any:
        result["reason"] = "貸借対照表タグが見つからない"
    return result
