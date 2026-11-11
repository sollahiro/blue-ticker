// 設備投資等の概要ブロック。セグメント行とは別。カテゴリは正規化後のラベル一致でのみ
// セグメントへ紐付ける。全社（共通）は調整行に載せない。その他は member または金額が
// 一致するときだけ。結合バケツ「その他及び全社」は未割当。

import Foundation

enum SegmentOverviewAssign {
    struct Assignment {
        var total: BreakdownMetricCellPayload?
        var categories: [SegmentOverviewCategoryPayload]
        var warnings: [String]
        var needsReview: Bool
    }

    static func assign(
        overview: BreakdownSnapshot?,
        overviewTotal: BreakdownMetricCellPayload?,
        segmentRows: [BreakdownRowPayload],
        edinetCode: String
    ) -> Assignment {
        var warnings: [String] = []
        var needsReview = false
        var total = overviewTotal
        if total == nil, let overview, overview.denominator > 0 {
            total = BreakdownMetricCellPayload(
                value: overview.denominator, basis: overview.sourceKind,
                source: overview.denominatorTag)
        }

        let rows = overview?.rows ?? []
        let operatingOverview = rows.filter { $0.rowKind == "segment" }
        let shared = rows.first { $0.labelRaw == "CorporateSharedMember" }

        if let sharedAmount = shared?.amount, let proposed = total?.value,
            SegmentCompanyTotal.rejectSharedAsTotalIfOperatingLarger(
                proposed: proposed, sharedAmount: sharedAmount,
                operatingSum: operatingOverview.map(\.amount).reduce(0, +))
        {
            total = nil
            needsReview = true
            warnings.append("overview_corporate_shared_not_company_total")
        }

        let sole = rows.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
        if sole.count == 1, let only = sole.first,
            SegmentCompanyTotal.isTotalOnlySoleMember(only.labelRaw)
        {
            if total == nil {
                total = BreakdownMetricCellPayload(
                    value: only.amount, basis: overview?.sourceKind ?? breakdownSourceXbrlFacts,
                    source: only.labelRaw)
            }
            return Assignment(total: total, categories: [], warnings: warnings, needsReview: needsReview)
        }

        var categories: [SegmentOverviewCategoryPayload] = []
        for row in rows where row.rowKind == "segment" || row.rowKind == "reconciling" {
            if SegmentCompanyTotal.isTotalOnlySoleMember(row.labelRaw),
                operatingOverview.contains(where: { $0.labelRaw != row.labelRaw })
            {
                continue
            }
            let label = row.label ?? row.labelRaw
            var assignedKey: String?
            var unassigned = false
            if SegmentLabelMatch.isCombinedOtherAndCorporate(label) {
                unassigned = true
            } else if row.labelRaw == "CorporateSharedMember"
                || SegmentLabelMatch.isOverviewCorporateShared(label)
            {
                if let totalValue = total?.value, abs(row.amount - totalValue) <= max(1, abs(totalValue) * 1e-9),
                    !operatingOverview.isEmpty
                {
                    continue
                }
                unassigned = true
            } else {
                assignedKey = matchingSegmentKey(
                    overviewLabel: label, amount: row.amount, segmentRows: segmentRows,
                    edinetCode: edinetCode)
                if assignedKey == nil { unassigned = true }
            }
            let basis = overview?.sourceKind ?? breakdownSourceXbrlFacts
            categories.append(
                SegmentOverviewCategoryPayload(
                    label: label,
                    segmentKey: assignedKey,
                    unassigned: unassigned,
                    amount: BreakdownMetricCellPayload(
                        value: row.amount, basis: basis, source: row.labelRaw)))
        }

        return Assignment(
            total: total, categories: categories, warnings: warnings, needsReview: needsReview)
    }

    private static func matchingSegmentKey(
        overviewLabel: String, amount: Double, segmentRows: [BreakdownRowPayload],
        edinetCode: String
    ) -> String? {
        let compact = SegmentLabelMatch.compact(overviewLabel)
        if compact == "その他" {
            let others = segmentRows.filter {
                $0.rowKind == "segment"
                    && (SegmentLabelMatch.compact($0.label) == "その他"
                        || $0.labelRaw.contains("Other"))
            }
            if others.count == 1 { return others[0].segmentKey }
            if let exact = others.first(where: {
                abs(($0.capitalExpenditures?.value ?? $0.amount) - amount) < 1
            }) {
                return exact.segmentKey
            }
            return nil
        }
        let matches = segmentRows.filter {
            $0.rowKind == "segment" && SegmentLabelMatch.matches(overviewLabel, segmentLabel: $0.label)
        }
        if matches.count == 1 { return matches[0].segmentKey }
        return nil
    }
}
