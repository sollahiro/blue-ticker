// 設備投資マトリクス（axis=`capex`）。行は既存 row_kind（セグメント / 調整額 /
// 財務諸表計上額=EntityTotal）。セルは segment_assets / flow / Overview。
// フローは書類単位で capital_expenditures があればそれ、無ければ
// noncurrent_asset_additions。混ぜず足さない。各セルの分母は連結の無 dimension
// 総額タグ（EntityTotal）。加算した segment+reconciling は分母にしない。
// PPE と Summary capex は触らない。Overview HTML 表は正本（合計行が総額）。
// HTML ラベルと XBRL member は初期は結合しない。

import Foundation

enum CapexNormalizer {
    /// 公開軸 `capex` のスナップショット。3 指標がすべて空なら nil（not_found）。
    static func normalize(
        facts: [BreakdownFact], labelsByTag: [String: String] = [:],
        memberParents: [String: String] = [:],
        capitalExpendituresPresent: Bool, noncurrentAssetAdditionsPresent: Bool,
        overviewHTML: BreakdownSnapshot? = nil,
        overviewCompanyTotal: (value: Double, tag: String)? = nil,
        flowCompanyTotal: (value: Double, tag: String)? = nil,
        prebuiltAssets: BreakdownSnapshot? = nil,
        prebuiltOverviewFacts: BreakdownSnapshot? = nil,
        differenceTableDir: URL? = nil
    ) -> BreakdownSnapshotPayload? {
        let assets = prebuiltAssets ?? BreakdownNormalizer.normalizeSegmentAssets(
            facts: facts, labelsByTag: labelsByTag, memberParents: memberParents)
        var flowMetric: String?
        var flowSnapshot: BreakdownSnapshot?
        if capitalExpendituresPresent {
            flowMetric = capexFlowMetricCapitalExpenditures
            flowSnapshot = withCompanyTotalDenominator(
                BreakdownNormalizer.normalizeCapitalExpenditures(
                    facts: facts, labelsByTag: labelsByTag, memberParents: memberParents),
                companyTotal: flowCompanyTotal, warningPrefix: "capital_expenditures")
                ?? companyTotalSnapshot(
                    axis: breakdownAxisCapitalExpenditures, total: flowCompanyTotal,
                    warningPrefix: "capital_expenditures")
        } else if noncurrentAssetAdditionsPresent {
            flowMetric = capexFlowMetricNoncurrentAssetAdditions
            flowSnapshot = withCompanyTotalDenominator(
                BreakdownNormalizer.normalizeNoncurrentAssetAdditions(
                    facts: facts, labelsByTag: labelsByTag, memberParents: memberParents),
                companyTotal: flowCompanyTotal, warningPrefix: "noncurrent_asset_additions")
                ?? companyTotalSnapshot(
                    axis: breakdownAxisNoncurrentAssetAdditions, total: flowCompanyTotal,
                    warningPrefix: "noncurrent_asset_additions")
        } else {
            flowMetric = nil
            flowSnapshot = nil
        }
        if let differenceTableDir {
            let enriched = BreakdownNormalizer.enrichFlowWithDifferenceTable(
                snapshot: flowSnapshot, xbrlDir: differenceTableDir)
            if flowSnapshot == nil, enriched != nil, flowMetric == nil {
                flowMetric = capexFlowMetricCapitalExpenditures
            }
            flowSnapshot = enriched ?? flowSnapshot
        }

        let overviewFacts = prebuiltOverviewFacts
            ?? BreakdownNormalizer.normalizeCapitalExpendituresOverview(
                facts: facts, labelsByTag: labelsByTag, memberParents: memberParents)
        let overview = mergeOverview(
            facts: overviewFacts, html: overviewHTML, companyTotal: overviewCompanyTotal)

        var assembled = assemble(
            assets: assets, flow: flowSnapshot, flowMetric: flowMetric, overview: overview)
        assembled = assembled.map(materializeEntityTotalRows)
        assembled = assembled.map(fillZeroSegmentFlowWhenReconcilingCoversTotal)
        return assembled
    }

    /// facts に無い Overview HTML 行を、残差を閉じるときだけ足す。ラベルでは結合しない。
    static func mergeOverview(
        facts: BreakdownSnapshot?, html: BreakdownSnapshot?,
        companyTotal: (value: Double, tag: String)?
    ) -> BreakdownSnapshot? {
        if let facts {
            var base = withCompanyTotalDenominator(
                facts, companyTotal: companyTotal,
                warningPrefix: "capital_expenditures_overview") ?? facts
            guard let html else { return base }
            let extras = unmatchedAdditiveRows(in: html, versus: base)
            guard !extras.isEmpty else { return base }
            let residual = additiveResidual(of: base)
            let extraSum = extras.map(\.amount).reduce(0, +)
            if !closesResidual(residual: residual, extraSum: extraSum, denominator: base.denominator) {
                return base
            }
            for row in extras {
                base.rows.append(row)
            }
            if base.denominator > 0 {
                let stillFar = abs(additiveResidual(of: base)) / base.denominator > 0.05
                if !stillFar {
                    base.warnings.removeAll { $0.hasSuffix("_segment_sum_far_from_total") }
                    base.needsReview = !base.warnings.isEmpty
                }
            }
            return base
        }
        if let html {
            return withCompanyTotalDenominator(
                html, companyTotal: companyTotal,
                warningPrefix: "capital_expenditures_overview")
        }
        if let companyTotal, companyTotal.value > 0 {
            return BreakdownNormalizer.normalizeCapitalExpendituresOverview(
                facts: [], total: companyTotal.value, totalTag: companyTotal.tag)
        }
        return nil
    }

    private static func unmatchedAdditiveRows(
        in html: BreakdownSnapshot, versus facts: BreakdownSnapshot
    ) -> [BreakdownRow] {
        let factAmounts = facts.rows
            .filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount)
        let factLabels = Set(facts.rows.map { compactLabel($0.label ?? $0.labelRaw) })
        return html.rows.filter { row in
            guard row.rowKind == "segment" || row.rowKind == "reconciling" else { return false }
            if factLabels.contains(compactLabel(row.label ?? row.labelRaw)) { return false }
            return !factAmounts.contains { abs($0 - row.amount) < 0.5 }
        }
    }

    private static func additiveResidual(of snapshot: BreakdownSnapshot) -> Double {
        let additive = snapshot.rows
            .filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount).reduce(0, +)
        guard snapshot.denominator > 0 else { return 0 }
        return snapshot.denominator - additive
    }

    /// 残差と追加行の和が分母の 5% 以内、または 1 百万円の丸め以内。
    private static func closesResidual(residual: Double, extraSum: Double, denominator: Double) -> Bool {
        let leftover = residual - extraSum
        if abs(leftover) <= 1_000_000 { return true }
        let scale = max(1.0, abs(denominator), abs(residual), abs(extraSum))
        return abs(leftover) / scale <= 0.05
    }

    private static func compactLabel(_ text: String) -> String {
        text.filter { !$0.isWhitespace && $0 != "　" }
    }

    /// 書類の当期 fact に当該タグがあるか（セグメント dimension の有無は問わない）。
    static func filingHasCurrentTags(in xbrlDir: URL, tags: [String]) -> Bool {
        let all = XBRLUtils.collectAllNumericFacts(in: xbrlDir, nilAsZero: false)
        let wanted = Set(tags)
        for tag in wanted {
            guard let ctxMap = all[tag] else { continue }
            if ctxMap.keys.contains(where: { BreakdownNormalizer.isCurrentPeriodContext($0) }) {
                return true
            }
        }
        return false
    }

    /// 事実配列だけから書類単位のフロー選択をする（単体テスト用）。
    static func flowMetric(
        capitalExpendituresPresent: Bool, noncurrentAssetAdditionsPresent: Bool
    ) -> String? {
        if capitalExpendituresPresent { return capexFlowMetricCapitalExpenditures }
        if noncurrentAssetAdditionsPresent { return capexFlowMetricNoncurrentAssetAdditions }
        return nil
    }

    static func assemble(
        assets: BreakdownSnapshot?, flow: BreakdownSnapshot?, flowMetric: String?,
        overview: BreakdownSnapshot?
    ) -> BreakdownSnapshotPayload? {
        guard assets != nil || flow != nil || overview != nil else { return nil }

        var rows: [BreakdownRowPayload] = []
        var index: [String: Int] = [:]

        func append(from snapshot: BreakdownSnapshot?, cell: CapexCell) {
            guard let snapshot else { return }
            for source in snapshot.rows {
                let kind = remappedRowKind(source)
                if let existing = index[source.labelRaw], rows.indices.contains(existing) {
                    write(cell, amount: source.amount, into: &rows[existing])
                    if rows[existing].description == nil {
                        rows[existing].description = source.description
                    }
                    if kind == breakdownRowKindEntityTotal {
                        rows[existing].rowKind = breakdownRowKindEntityTotal
                    }
                    continue
                }
                var row = BreakdownRowPayload(
                    labelRaw: source.labelRaw, label: source.label ?? source.labelRaw,
                    amount: 0, profit: nil, rowKind: kind, description: source.description)
                write(cell, amount: source.amount, into: &row)
                index[source.labelRaw] = rows.count
                rows.append(row)
            }
        }

        append(from: assets, cell: .segmentAssets)
        append(from: flow, cell: .flow)
        append(from: overview, cell: .overview)

        var warnings: [String] = []
        for snapshot in [assets, flow, overview].compactMap({ $0 }) {
            for warning in snapshot.warnings where !warnings.contains(warning) {
                warnings.append(warning)
            }
        }
        let needsReview = [assets, flow, overview].compactMap { $0 }.contains { $0.needsReview }
        let sourceKind = combinedSourceKind(assets: assets, flow: flow, overview: overview)
        return BreakdownSnapshotPayload(
            axis: breakdownAxisCapex, denominator: 0, denominatorTag: flowMetric ?? "",
            rows: rows, sourceKind: sourceKind, needsReview: needsReview, warnings: warnings,
            flowMetric: flowMetric,
            segmentAssets: metricTotals(assets),
            flow: metricTotals(flow),
            capitalExpendituresOverview: metricTotals(overview))
    }

    private enum CapexCell {
        case segmentAssets, flow, overview
    }

    private static func write(_ cell: CapexCell, amount: Double, into row: inout BreakdownRowPayload) {
        switch cell {
        case .segmentAssets: row.segmentAssets = amount
        case .flow: row.flow = amount
        case .overview: row.capitalExpendituresOverview = amount
        }
    }

    private static func remappedRowKind(_ row: BreakdownRow) -> String {
        if row.labelRaw == Xbrl.entityTotalMemberName { return breakdownRowKindEntityTotal }
        let label = (row.label ?? row.labelRaw)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        if label.contains("連結合計") || label.contains("会社合計")
            || label.contains("連結財務諸表計上額")
        {
            return breakdownRowKindEntityTotal
        }
        return row.rowKind
    }

    /// 分母だけあるセルに EntityTotal 行を載せる（3524 / 7985 / 7435）。加算には入れない。
    static func materializeEntityTotalRows(
        _ payload: BreakdownSnapshotPayload
    ) -> BreakdownSnapshotPayload {
        var filled = payload
        func ensure(totals: CapexMetricTotalsPayload?, write: (inout BreakdownRowPayload, Double) -> Void) {
            guard let totals, totals.denominator > 0 else { return }
            if let index = filled.rows.firstIndex(where: {
                $0.rowKind == breakdownRowKindEntityTotal || $0.labelRaw == Xbrl.entityTotalMemberName
            }) {
                write(&filled.rows[index], totals.denominator)
                filled.rows[index].rowKind = breakdownRowKindEntityTotal
                return
            }
            var row = BreakdownRowPayload(
                labelRaw: Xbrl.entityTotalMemberName,
                label: Xbrl.codeSideStandardMemberLabels[Xbrl.entityTotalMemberName]
                    ?? "連結合計又は会社合計",
                amount: 0, profit: nil, rowKind: breakdownRowKindEntityTotal)
            write(&row, totals.denominator)
            filled.rows.append(row)
        }
        ensure(totals: payload.segmentAssets) { $0.segmentAssets = $1 }
        ensure(totals: payload.flow) { $0.flow = $1 }
        ensure(totals: payload.capitalExpendituresOverview) { $0.capitalExpendituresOverview = $1 }
        return filled
    }

    /// 調整額がフロー分母を覆うとき、セグメントの「－」は 0（5079 / 9444）。値は作らない。
    static func fillZeroSegmentFlowWhenReconcilingCoversTotal(
        _ payload: BreakdownSnapshotPayload
    ) -> BreakdownSnapshotPayload {
        guard let totals = payload.flow, totals.denominator > 0 else { return payload }
        let reconciling = payload.rows.filter { $0.rowKind == "reconciling" }.compactMap(\.flow)
        guard !reconciling.isEmpty else { return payload }
        let reconcilingSum = reconciling.reduce(0, +)
        if abs(reconcilingSum - totals.denominator) / totals.denominator > 0.05 { return payload }
        let segmentFlows = payload.rows.filter { $0.rowKind == "segment" }.compactMap(\.flow)
        if segmentFlows.contains(where: { $0 != 0 }) { return payload }
        var filled = payload
        for index in filled.rows.indices where filled.rows[index].rowKind == "segment" {
            if filled.rows[index].flow == nil { filled.rows[index].flow = 0 }
        }
        return filled
    }

    private static func metricTotals(_ snapshot: BreakdownSnapshot?) -> CapexMetricTotalsPayload? {
        guard let snapshot, snapshot.denominator > 0 else { return nil }
        return CapexMetricTotalsPayload(
            denominator: snapshot.denominator, denominatorTag: snapshot.denominatorTag)
    }

    private static func combinedSourceKind(
        assets: BreakdownSnapshot?, flow: BreakdownSnapshot?, overview: BreakdownSnapshot?
    ) -> String {
        let kinds = [assets, flow, overview].compactMap { $0?.sourceKind }
        if kinds.contains(breakdownSourceXbrlFacts) { return breakdownSourceXbrlFacts }
        if kinds.contains("html_table") { return "html_table" }
        if kinds.contains(breakdownSourceCapexProse) { return breakdownSourceCapexProse }
        return kinds.first ?? breakdownSourceXbrlFacts
    }

    /// 連結の無 dimension 総額タグを分母にする。既に EntityTotal 分母があるときはそのまま。
    /// 加算合計を 100% 分母にはしない。
    static func withCompanyTotalDenominator(
        _ snapshot: BreakdownSnapshot?, companyTotal: (value: Double, tag: String)?,
        warningPrefix: String
    ) -> BreakdownSnapshot? {
        guard var snapshot else { return nil }
        if snapshot.denominator > 0 { return snapshot }
        guard let companyTotal, companyTotal.value > 0 else { return snapshot }
        let additive = snapshot.rows
            .filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount).reduce(0, +)
        var warnings = snapshot.warnings.filter {
            $0 != "\(warningPrefix)_denominator_derived_from_segment_sum"
                && $0 != "\(warningPrefix)_entity_total_differs_from_table_total"
        }
        if additive > 0, abs(additive - companyTotal.value) / companyTotal.value > 0.05 {
            let warning = "\(warningPrefix)_segment_sum_far_from_total"
            if !warnings.contains(warning) { warnings.append(warning) }
        }
        snapshot.denominator = companyTotal.value
        snapshot.denominatorTag = companyTotal.tag
        snapshot.rows = snapshot.rows.map { row in
            var copy = row
            copy.share = row.amount / companyTotal.value
            return copy
        }
        snapshot.warnings = warnings
        snapshot.needsReview = !warnings.isEmpty
        return snapshot
    }

    private static func companyTotalSnapshot(
        axis: String, total: (value: Double, tag: String)?, warningPrefix: String
    ) -> BreakdownSnapshot? {
        guard let total, total.value > 0 else { return nil }
        _ = warningPrefix
        return BreakdownSnapshot(
            axis: axis, denominator: total.value, denominatorTag: total.tag,
            rows: [], sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
    }
}
