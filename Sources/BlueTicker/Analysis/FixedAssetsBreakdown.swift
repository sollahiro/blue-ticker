// fixed_assets 軸: 固定資産の種類別（正味帳簿価額）。有形固定資産と無形固定資産（のれんを含む）を
// 行の `asset_class` で分けて1つの payload にする。旧 property_plant_equipment / goodwill_and_intangibles の統合。
//
// - IFRS: 連結の注記（`AssetCategoryBreakdown`）。区分の注記が無い書類は、その区分を null にする。
// - 日本基準: 連結 BS の `PropertyPlantAndEquipment` / `IntangibleAssets` の計算リンクの内訳科目。
//   内訳は正味（建物及び構築物（純額）等）なので、取得原価と減価償却累計額は行にしない。
//   内訳科目がさらに加算だけの合計なら、1段だけ小計として開く（その他の無形固定資産の内訳等）。
// - 米国基準と、どちらも取れない書類は nil（呼び出し側は not_found）。
//
// 百万円・千円の丸めで区分行の和が合計と行数単位までずれる開示は合っているとみなす（`AssetCategoryBreakdown` と同じ）。

import Foundation

enum FixedAssetsBreakdown {
    /// 日本基準 BS の区分合計の科目。
    static let balanceSheetClassTags: [(assetClass: String, tag: String)] = [
        (breakdownAssetClassPropertyPlantEquipment, "PropertyPlantAndEquipment"),
        (breakdownAssetClassIntangibleAssets, "IntangibleAssets"),
    ]

    /// 書類1件分を解決する。IFRS の注記が無ければ日本基準の BS を読む。
    static func resolve(xbrlDir: URL) -> BreakdownSnapshotPayload? {
        let notes = [AssetCategoryBreakdown.propertyPlantEquipment, AssetCategoryBreakdown.goodwillAndIntangibles]
            .compactMap { spec in
                AssetCategoryBreakdown.resolve(xbrlDir: xbrlDir, spec: spec).map {
                    classPart($0, assetClass: spec.assetClass)
                }
            }
        if !notes.isEmpty { return combine(notes) }
        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir, docID: nil, statementTypes: [.balanceSheet])
        else { return nil }
        return fromBalanceSheet(year.balanceSheet)
    }

    /// 区分1つ分の payload に、その区分の合計（分母と同じ値）を載せる。
    static func classPart(_ payload: BreakdownSnapshotPayload, assetClass: String) -> BreakdownSnapshotPayload {
        var part = payload
        let totals = CapexMetricTotalsPayload(denominator: payload.denominator, denominatorTag: payload.denominatorTag)
        if assetClass == breakdownAssetClassPropertyPlantEquipment {
            part.propertyPlantEquipment = totals
        } else {
            part.intangibleAssets = totals
        }
        return part
    }

    /// 区分ごとの payload（`classPart` 済み）を1つにする。分母は区分合計の和。
    static func combine(_ parts: [BreakdownSnapshotPayload]) -> BreakdownSnapshotPayload? {
        guard !parts.isEmpty else { return nil }
        var totals: [String: CapexMetricTotalsPayload] = [:]
        var rows: [BreakdownRowPayload] = []
        var warnings: [String] = []
        for part in parts {
            if let ppe = part.propertyPlantEquipment { totals[breakdownAssetClassPropertyPlantEquipment] = ppe }
            if let intangible = part.intangibleAssets { totals[breakdownAssetClassIntangibleAssets] = intangible }
            rows += part.rows
            for warning in part.warnings where !warnings.contains(warning) { warnings.append(warning) }
        }
        let ordered = [breakdownAssetClassPropertyPlantEquipment, breakdownAssetClassIntangibleAssets]
            .compactMap { totals[$0] }
        guard !ordered.isEmpty else { return nil }
        return BreakdownSnapshotPayload(
            axis: breakdownAxisFixedAssets,
            denominator: ordered.reduce(0) { $0 + $1.denominator },
            denominatorTag: ordered.map(\.denominatorTag).joined(separator: "+"),
            rows: rows, sourceKind: breakdownSourceXbrlFacts,
            needsReview: parts.contains(where: \.needsReview), warnings: warnings,
            propertyPlantEquipment: totals[breakdownAssetClassPropertyPlantEquipment],
            intangibleAssets: totals[breakdownAssetClassIntangibleAssets])
    }

    /// 日本基準の連結 BS から組み立てる（XBRL を読まない純関数）。区分合計の科目が1つも無ければ nil。
    static func fromBalanceSheet(_ lines: [StatementLineItem]) -> BreakdownSnapshotPayload? {
        var byTag: [String: StatementLineItem] = [:]
        for line in lines where byTag[line.tag] == nil { byTag[line.tag] = line }
        let parts = balanceSheetClassTags.compactMap { entry -> BreakdownSnapshotPayload? in
            guard let total = byTag[entry.tag] else { return nil }
            return balanceSheetClass(total: total, assetClass: entry.assetClass, byTag: byTag)
        }
        return combine(parts)
    }

    /// 区分1つ分。内訳科目が無い BS（無形固定資産を1行で載せる会社）は区分合計の1行だけ。
    static func balanceSheetClass(
        total: StatementLineItem, assetClass: String, byTag: [String: StatementLineItem]
    ) -> BreakdownSnapshotPayload {
        func row(_ item: StatementLineItem, amount: Double, kind: String, group: String?, category: String?)
            -> BreakdownRowPayload
        {
            let label = item.label ?? item.tag
            return BreakdownRowPayload(
                labelRaw: label, label: label, amount: amount, profit: nil, rowKind: kind,
                categoryGroup: group, category: category, sourceTag: item.tag, assetClass: assetClass)
        }
        func classTotals(_ rows: [BreakdownRowPayload], needsReview: Bool, warnings: [String])
            -> BreakdownSnapshotPayload
        {
            classPart(
                BreakdownSnapshotPayload(
                    axis: breakdownAxisFixedAssets, denominator: total.value, denominatorTag: total.tag,
                    rows: rows, sourceKind: breakdownSourceXbrlFacts, needsReview: needsReview,
                    warnings: warnings),
                assetClass: assetClass)
        }

        // 計算リンクの順は表示順と違う（ダイキンは土地が先頭）ので、BS の表示順に並べ替える。
        let components = (total.components ?? []).enumerated().sorted { lhs, rhs in
            switch (byTag[lhs.element.tag]?.order, byTag[rhs.element.tag]?.order) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
        guard !components.isEmpty else {
            let rows = total.value == 0 ? [] : [row(total, amount: total.value, kind: "segment", group: nil, category: nil)]
            return classTotals(rows, needsReview: false, warnings: [])
        }

        var rows: [BreakdownRowPayload] = []
        var sum = 0.0
        var values: [Double] = [total.value]
        var missing = false
        for component in components {
            guard let line = byTag[component.tag] else {
                missing = true
                continue
            }
            let amount = Double(component.weight) * line.value
            sum += amount
            values.append(line.value)
            // 加算だけの合計で、内訳が BS にそろっていれば1段だけ小計として開く。
            // 純額科目（取得原価 − 減価償却累計額）は控除があるので開かない。
            let children = (line.components ?? []).compactMap { child in
                child.weight == 1 ? byTag[child.tag] : nil
            }
            let label = line.label ?? line.tag
            if component.weight == 1, line.isTotal, let childComponents = line.components,
                !childComponents.isEmpty, children.count == childComponents.count
            {
                rows.append(row(line, amount: amount, kind: "subtotal", group: label, category: nil))
                for child in children {
                    rows.append(row(child, amount: child.value, kind: "segment", group: label, category: child.label ?? child.tag))
                }
            } else {
                rows.append(row(line, amount: amount, kind: "segment", group: nil, category: nil))
            }
        }
        let unit = AssetCategoryBreakdown.displayUnit(values)
        let unmatched = missing || abs(sum - total.value) > Double(components.count) * unit
        return classTotals(
            rows, needsReview: unmatched,
            warnings: unmatched ? [breakdownWarningAssetCategoryTotalUnmatched] : [])
    }
}
