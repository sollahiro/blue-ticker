// 資産の種類別の内訳軸（property_plant_equipment / goodwill_and_intangibles）。
// 旧 notes の `property_plant_equipment_schedule` / `goodwill_and_intangibles` を Breakdown に移したもの。
// 切り口は報告セグメントではなく資産の種類。のれんのセグメント別軸 `goodwill` とは別物。
//
// 対象は IFRS 連結の注記 role（正味帳簿価額の `{資産区分}IFRS` タグ）だけ。取得原価・累計償却は載せない。
// 日本基準は BS の区分科目がそのまま statement にあるので軸にしない（not_found）。
// 行の小計（ソニーの「コンテンツ資産」等）は、表示順で直前の連続した行の和に一致する行として決める。
// 金額の丸め（百万円）で 1 単位ずれる開示があるので、和の比較は行数 × 表示単位まで許す（JT の 1 百万円差）。

import Foundation

enum AssetCategoryBreakdown {
    struct Spec: Sendable {
        let axis: String
        /// 注記 role のセクション名（`XBRLUtils.sectionNameFromRole` の値）。
        let roleName: String
        /// 区分行の外にある集約科目。小計にも合計にも当たらず行のまま残ったら要確認にする。
        let aggregateTags: Set<String>
        /// 集約科目でも、ほかに区分行が無ければ単独の行として正しい科目（のれん以外の無形資産の合計）。
        let standaloneAggregateTags: Set<String>
    }

    static let propertyPlantEquipment = Spec(
        axis: breakdownAxisPropertyPlantEquipment,
        roleName: "NotesPropertyPlantAndEquipmentConsolidatedFinancialStatementsIFRS",
        aggregateTags: ["PropertyPlantAndEquipmentIFRS"],
        standaloneAggregateTags: [])

    static let goodwillAndIntangibles = Spec(
        axis: breakdownAxisGoodwillAndIntangibles,
        roleName: "NotesGoodwillAndIntangibleAssetsConsolidatedFinancialStatementsIFRS",
        aggregateTags: [
            "GoodwillAndIntangibleAssetsIFRS", "IntangibleAssetsAndGoodwillIFRS",
            "IntangibleAssetsIFRS", "OtherIntangibleAssetsIFRS",
        ],
        standaloneAggregateTags: ["IntangibleAssetsIFRS", "OtherIntangibleAssetsIFRS"])

    /// 正味帳簿価額でないタグ（取得原価・累計償却・累計減損）。
    private static let componentKeywords = [
        "AcquisitionCost",
        "AccumulatedDepreciation",
        "AccumulatedAmortization",
        "AccumulatedImpairment",
    ]

    /// 注記 role の正味帳簿価額（連結・当期末）を表示順で返す。順序が取れないタグはタグ名順で後ろ。
    static func categoryItems(xbrlDir: URL, roleName: String) -> [StatementLineItem] {
        // 正味帳簿価額は nil を 0 にしない（`nilAsZero: false`）。ラベル走査も同じ索引を使う。
        let facts = XBRLUtils.collectAllNumericFacts(in: xbrlDir, nilAsZero: false)
        var labelsByTag: [String: String?] = [:]
        var orderByTag: [String: Int] = [:]
        for (tag, ctxMap) in facts
        where tag.hasSuffix("IFRS") && !componentKeywords.contains(where: { tag.contains($0) }) {
            for fact in ctxMap.values {
                let roles = fact.roles ?? fact.role.map { [$0] } ?? []
                if let matchedRole = roles.first(where: { XBRLUtils.sectionNameFromRole($0) == roleName }) {
                    labelsByTag[tag] = fact.label
                    if let order = fact.orderByRole?[matchedRole] { orderByTag[tag] = order }
                    break
                }
            }
        }
        guard !labelsByTag.isEmpty else { return [] }

        // 正味帳簿価額は連結 Instant コンテキスト（CurrentYearInstant、member 接尾辞なし）。
        let instantFS = fieldSetFromInstant(XBRLUtils.factIndexToNumericElements(facts))
        // 提出パッケージにラベルの無い標準科目（味の素の BuildingsAndStructuresIFRS 等）は標準タクソノミの日本語。
        let standardLabels = XBRLUtils.loadStandardTaxonomyLabels()
        var items: [StatementLineItem] = []
        for (tag, label) in labelsByTag {
            guard let value = instantFS[tag]?.current else { continue }
            items.append(
                StatementLineItem(
                    tag: tag, label: label ?? standardLabels[tag], value: value, unit: "yen",
                    order: orderByTag[tag]))
        }
        items.sort { lhs, rhs in
            switch (lhs.order, rhs.order) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.tag < rhs.tag
            }
        }
        return items
    }

    /// 書類1件分の軸を解決する。IFRS の注記が無ければ nil（呼び出し側は not_found）。
    static func resolve(xbrlDir: URL, spec: Spec) -> BreakdownSnapshotPayload? {
        build(items: categoryItems(xbrlDir: xbrlDir, roleName: spec.roleName), spec: spec)
    }

    /// 表示順の行から内訳を組み立てる（XBRL を読まない純関数。テスト用に分けてある）。
    static func build(items: [StatementLineItem], spec: Spec) -> BreakdownSnapshotPayload? {
        guard !items.isEmpty else { return nil }
        let unit = displayUnit(items.map(\.value))

        // 表示順に積み、直前の連続した未消費の行（2行以上）の和と一致する行を小計にする。
        // 一致する長さが複数あるとき（0 円の行を挟む等）は長い方を取り、0 円の行も小計の下に入れる。
        var nodes: [Node] = []
        var open: [Int] = []
        for item in items {
            var matched: Int?
            if open.count >= 2 {
                var sum = 0.0
                for length in 1...open.count {
                    sum += nodes[open[open.count - length]].item.value
                    if length >= 2, abs(sum - item.value) <= Double(length) * unit {
                        matched = length
                    }
                }
            }
            let index = nodes.count
            if let matched {
                let children = Array(open.suffix(matched))
                nodes.append(Node(item: item, children: children))
                open.removeLast(matched)
            } else {
                nodes.append(Node(item: item, children: []))
            }
            open.append(index)
        }

        var warnings: [String] = []
        var needsReview = false
        // 全行を1つにまとめた行は合計（分母）にする。行には出さない。
        let grandTotal: Int? = open.count == 1 && !nodes[open[0]].children.isEmpty ? open[0] : nil
        let topLevel = grandTotal.map { nodes[$0].children } ?? open
        // 集約科目が小計にならず行に残った（区分行の和と合わない）。合計を作り直さず公開保留。
        let leafTopLevel = topLevel.filter { nodes[$0].children.isEmpty }
        let hasCategoryRow = leafTopLevel.contains { index in
            let tag = nodes[index].item.tag
            return !spec.aggregateTags.contains(tag) && tag != "GoodwillIFRS"
        }
        let strandedAggregate = leafTopLevel.contains { index in
            let tag = nodes[index].item.tag
            guard spec.aggregateTags.contains(tag) else { return false }
            return !spec.standaloneAggregateTags.contains(tag) || hasCategoryRow
        }
        if strandedAggregate {
            needsReview = true
            warnings.append(breakdownWarningAssetCategoryTotalUnmatched)
        }

        // 小計の中の小計は category_group 1段では親を示せない（合計の数え方が二通りになる）。公開保留。
        let nestedSubtotal = topLevel.contains { index in
            nodes[index].children.contains { !nodes[$0].children.isEmpty }
        }
        if nestedSubtotal {
            needsReview = true
            warnings.append(breakdownWarningAssetCategoryNestedSubtotal)
        }

        var rows: [BreakdownRowPayload] = []
        func emit(_ index: Int, parent: String?) {
            let node = nodes[index]
            let label = node.item.label ?? node.item.tag
            let isSubtotal = !node.children.isEmpty
            rows.append(
                BreakdownRowPayload(
                    labelRaw: label, label: label, amount: node.item.value, profit: nil,
                    rowKind: isSubtotal ? "subtotal" : "segment",
                    categoryGroup: isSubtotal ? label : parent,
                    category: isSubtotal ? nil : (parent == nil ? nil : label),
                    sourceTag: node.item.tag))
            for child in node.children { emit(child, parent: label) }
        }
        for index in topLevel { emit(index, parent: nil) }

        let denominator: Double
        let denominatorTag: String
        if let grandTotal {
            denominator = nodes[grandTotal].item.value
            denominatorTag = nodes[grandTotal].item.tag
        } else {
            // 合計科目の無い注記（のれんと無形資産を別科目で載せる会社）は最上位の行の和。
            denominator = topLevel.reduce(0) { $0 + nodes[$1].item.value }
            denominatorTag = topLevel.map { nodes[$0].item.tag }.joined(separator: "+")
        }
        return BreakdownSnapshotPayload(
            axis: spec.axis, denominator: denominator, denominatorTag: denominatorTag, rows: rows,
            sourceKind: breakdownSourceXbrlFacts, needsReview: needsReview, warnings: warnings)
    }

    private struct Node {
        let item: StatementLineItem
        /// 小計なら、その和になる直前の行（nodes の添字）。区分行は空。
        let children: [Int]
    }

    /// 全行の金額を割り切る表示単位（円・千円・百万円）。和の丸め誤差の許容幅に使う。
    static func displayUnit(_ values: [Double]) -> Double {
        for unit in [1_000_000.0, 1_000.0] where values.allSatisfy({ $0.truncatingRemainder(dividingBy: unit) == 0 }) {
            return unit
        }
        return 1
    }
}
