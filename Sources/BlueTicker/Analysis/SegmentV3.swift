// segment-v3 スナップショット組立。売上・利益・資産・CE・NAA を member 和集合の
// 1 行骨格に載せ、設備投資概要は別ブロック、連結は無 dimension タグ。
// 丸め幅の差額は差額行に出さず rounding_gaps に生値だけ残す。値自体は丸めない。

import Foundation

enum SegmentV3 {
    static let warningDifference = "segment_metric_differs_from_consolidated"
    static let warningSharedNotTotal = "corporate_shared_not_company_total"

    static func assemble(
        segment: BreakdownSnapshotPayload,
        assets: BreakdownSnapshot?,
        capitalExpenditures: BreakdownSnapshot?,
        noncurrentAssetAdditions: BreakdownSnapshot?,
        overview: BreakdownSnapshot?,
        overviewTotal: BreakdownMetricCellPayload?,
        equityMethod: BreakdownSnapshot?,
        external: BreakdownSnapshot?,
        externalSalesBasis: String? = nil,
        edinetCode: String,
        memberPrefixes: [String: String],
        labelsByTag: [String: String]
    ) -> BreakdownSnapshotPayload {
        var index: [String: Int] = [:]
        var rows: [BreakdownRowPayload] = []

        func ensureRow(localName: String, label: String, rowKind: String) -> Int {
            if let existing = index[localName] { return existing }
            let prefix = memberPrefixes[localName]
            let keyPrefix: String?
            if localName == Xbrl.entityTotalMemberName {
                keyPrefix = prefix ?? "jpcrp_cor"
            } else {
                keyPrefix = prefix
            }
            var row = BreakdownRowPayload(
                labelRaw: localName, label: label, amount: 0, profit: nil,
                rowKind: rowKind)
            row.segmentKey = SegmentKey.make(
                edinetCode: edinetCode, localName: localName, prefix: keyPrefix).description
            row.prefix = prefix
            index[localName] = rows.count
            rows.append(row)
            return rows.count - 1
        }

        let salesBasis: String
        if let externalSalesBasis, let external, !external.rows.isEmpty {
            salesBasis = externalSalesBasis
        } else {
            salesBasis = Self.salesBasis(of: segment, external: external)
        }
        let externalSource = external ?? (
            salesBasis == segmentSalesBasisExternal ? snapshotFromPayload(segment) : nil)

        for source in segment.rows {
            let kind = SegmentMemberKind.classify(localName: source.labelRaw, label: source.label)
            let position = ensureRow(
                localName: source.labelRaw, label: source.label,
                rowKind: SegmentMemberKind.rowKind(kind))
            rows[position].amount = source.amount
            rows[position].profit = source.profit
            rows[position].segmentBasis = source.segmentBasis
            rows[position].disclosureBasis = source.disclosureBasis
            if let profit = source.profit {
                rows[position].profitCell = cell(
                    value: profit, basis: segment.sourceKind, source: "profit",
                    decimals: source.profitCell?.decimals)
            }
        }

        if let externalSource {
            mergeMetric(
                externalSource, into: &rows, index: &index, edinetCode: edinetCode,
                memberPrefixes: memberPrefixes, labelsByTag: labelsByTag
            ) { row, amount, basis, source, decimals in
                row.externalSales = cell(
                    value: amount, basis: basis, source: source, decimals: decimals)
                if row.amount == 0 { row.amount = amount }
            }
        }

        mergeMetric(
            assets, into: &rows, index: &index, edinetCode: edinetCode,
            memberPrefixes: memberPrefixes, labelsByTag: labelsByTag
        ) { row, amount, basis, source, decimals in
            row.segmentAssets = amount
            row.segmentAssetsCell = cell(
                value: amount, basis: basis, source: source, decimals: decimals)
        }
        mergeMetric(
            capitalExpenditures, into: &rows, index: &index, edinetCode: edinetCode,
            memberPrefixes: memberPrefixes, labelsByTag: labelsByTag
        ) { row, amount, basis, source, decimals in
            row.capitalExpenditures = cell(
                value: amount, basis: basis, source: source, decimals: decimals)
        }
        mergeMetric(
            noncurrentAssetAdditions, into: &rows, index: &index, edinetCode: edinetCode,
            memberPrefixes: memberPrefixes, labelsByTag: labelsByTag
        ) { row, amount, basis, source, decimals in
            row.noncurrentAssetAdditions = cell(
                value: amount, basis: basis, source: source, decimals: decimals)
        }
        if let equityMethod {
            mergeMetric(
                equityMethod, into: &rows, index: &index, edinetCode: edinetCode,
                memberPrefixes: memberPrefixes, labelsByTag: labelsByTag
            ) { row, amount, basis, source, decimals in
                row.equityMethodInvestments = amount
                _ = basis
                _ = source
                _ = decimals
            }
        }

        if capitalExpenditures == nil, let overview {
            let operatingOverview = overview.rows.filter { $0.rowKind == "segment" }
            if !operatingOverview.isEmpty {
                mergeMetric(
                    overview, into: &rows, index: &index, edinetCode: edinetCode,
                    memberPrefixes: memberPrefixes, labelsByTag: labelsByTag,
                    skipCorporateShared: true
                ) { row, amount, basis, source, decimals in
                    if row.capitalExpenditures == nil {
                        row.capitalExpenditures = cell(
                            value: amount, basis: basis, source: source, decimals: decimals)
                    }
                }
            }
        }

        applyExplicitZeros(&rows)
        let differenced = addDifferenceRows(
            rows, edinetCode: edinetCode,
            metrics: differenceMetrics(
                assets: assets, capitalExpenditures: capitalExpenditures,
                noncurrentAssetAdditions: noncurrentAssetAdditions,
                external: externalSource, segment: segment))
        rows = differenced.rows

        let assignment = SegmentOverviewAssign.assign(
            overview: overview, overviewTotal: overviewTotal, segmentRows: rows,
            edinetCode: edinetCode)

        var warnings = segment.warnings
        for snapshot in [assets, capitalExpenditures, noncurrentAssetAdditions, overview, external]
            .compactMap({ $0 })
        {
            for warning in snapshot.warnings where !warnings.contains(warning) {
                warnings.append(warning)
            }
        }
        for warning in assignment.warnings where !warnings.contains(warning) {
            warnings.append(warning)
        }
        if !differenced.beyondTolerance.isEmpty, !warnings.contains(warningDifference) {
            warnings.append(warningDifference)
        }
        let needsReview = segment.needsReview
            || [assets, capitalExpenditures, noncurrentAssetAdditions, overview]
                .compactMap { $0 }.contains { $0.needsReview }
            || assignment.needsReview

        var out = segment
        out.rows = rows
        out.warnings = warnings
        out.needsReview = needsReview
        out.flow = nil
        out.flowMetric = nil
        out.salesBasis = salesBasis
        out.roundingGaps = differenced.roundingGaps.isEmpty ? nil : differenced.roundingGaps
        out.segmentAssets = totals(assets)
        out.capitalExpendituresTotals = totals(capitalExpenditures)
        out.noncurrentAssetAdditionsTotals = totals(noncurrentAssetAdditions)
        if let equityMethod {
            out.equityMethodInvestments = CapexMetricTotalsPayload(
                denominator: equityMethod.denominator, denominatorTag: equityMethod.denominatorTag,
                decimals: equityMethod.rows.first { $0.labelRaw == Xbrl.entityTotalMemberName }?
                    .decimals)
        }
        out.overview = SegmentOverviewPayload(
            total: assignment.total, categories: assignment.categories)
        out.capitalExpendituresOverview = nil
        return out
    }

    /// 設備投資等の概要の出どころ。HTML 表にカテゴリ行があるときだけ HTML、無ければタグ付き fact。
    /// HTML が総額 1 行だけのとき（5283 / 4680 / 3199）に fact のカテゴリ行を捨てない。
    static func pickOverview(html: BreakdownSnapshot?, facts: BreakdownSnapshot?) -> BreakdownSnapshot? {
        func hasCategories(_ snapshot: BreakdownSnapshot?) -> Bool {
            snapshot?.rows.contains { $0.rowKind == "segment" || $0.rowKind == "reconciling" } ?? false
        }
        if hasCategories(html) { return html }
        return facts ?? html
    }

    static func salesBasis(of segment: BreakdownSnapshotPayload, external: BreakdownSnapshot?)
        -> String
    {
        if let external, !external.rows.isEmpty { return segmentSalesBasisExternal }
        let tag = segment.denominatorTag
        if Xbrl.segmentIntersegmentInclusiveRevenueTags.contains(tag) {
            return segmentSalesBasisIntersegmentInclusive
        }
        if Xbrl.segmentBankGrossProfitTags.contains(tag) { return segmentSalesBasisBank }
        if Xbrl.segmentInsuranceRevenueTags.contains(tag) { return segmentSalesBasisInsurance }
        if Xbrl.segmentTrueExternalRevenueTags.contains(tag) { return segmentSalesBasisExternal }
        return segmentSalesBasisExternal
    }

    private static func snapshotFromPayload(_ payload: BreakdownSnapshotPayload) -> BreakdownSnapshot {
        BreakdownSnapshot(
            axis: payload.axis, denominator: payload.denominator,
            denominatorTag: payload.denominatorTag,
            rows: payload.rows.map {
                BreakdownRow(
                    labelRaw: $0.labelRaw, label: $0.label, amount: $0.amount, share: nil,
                    profit: $0.profit, rowKind: $0.rowKind, decimals: $0.externalSales?.decimals)
            },
            sourceKind: payload.sourceKind, needsReview: payload.needsReview,
            warnings: payload.warnings)
    }

    private static func cell(
        value: Double, basis: String, source: String, decimals: Int? = nil
    ) -> BreakdownMetricCellPayload {
        BreakdownMetricCellPayload(value: value, basis: basis, source: source, decimals: decimals)
    }

    private static func totals(_ snapshot: BreakdownSnapshot?) -> CapexMetricTotalsPayload? {
        guard let snapshot, snapshot.denominator != 0 else { return nil }
        let decimals = snapshot.rows.first { $0.labelRaw == Xbrl.entityTotalMemberName }?.decimals
        return CapexMetricTotalsPayload(
            denominator: snapshot.denominator, denominatorTag: snapshot.denominatorTag,
            decimals: decimals)
    }

    private static func mergeMetric(
        _ snapshot: BreakdownSnapshot?,
        into rows: inout [BreakdownRowPayload],
        index: inout [String: Int],
        edinetCode: String,
        memberPrefixes: [String: String],
        labelsByTag: [String: String],
        skipCorporateShared: Bool = false,
        write: (inout BreakdownRowPayload, Double, String, String, Int?) -> Void
    ) {
        guard let snapshot else { return }
        for source in snapshot.rows {
            if skipCorporateShared, source.labelRaw == "CorporateSharedMember" { continue }
            if skipCorporateShared, SegmentLabelMatch.isOverviewCorporateShared(source.label ?? "") {
                continue
            }
            let kind = SegmentMemberKind.classify(
                localName: source.labelRaw, label: source.label ?? labelsByTag[source.labelRaw])
            let label = source.label ?? labelsByTag[source.labelRaw] ?? source.labelRaw
            let position: Int
            if let existing = index[source.labelRaw] {
                position = existing
            } else if let matched = rows.firstIndex(where: { row in
                // 骨格が本文・Jev 由来（labelRaw が日本語ラベル）のとき、同じ表示名の member を
                // 別の行にしない（3909: 同じセグメントが 2 行になり、和が連結の 2 倍近くになる）。
                row.prefix == nil && row.rowKind == SegmentMemberKind.rowKind(kind)
                    && SegmentLabelMatch.compact(row.label) == SegmentLabelMatch.compact(label)
                    && !SegmentLabelMatch.compact(label).isEmpty
            }) {
                position = matched
                index[source.labelRaw] = matched
                if let prefix = memberPrefixes[source.labelRaw] {
                    rows[matched].prefix = prefix
                    rows[matched].segmentKey = SegmentKey.make(
                        edinetCode: edinetCode, localName: source.labelRaw, prefix: prefix
                    ).description
                }
            } else {
                let prefix = memberPrefixes[source.labelRaw]
                var row = BreakdownRowPayload(
                    labelRaw: source.labelRaw, label: label, amount: 0, profit: nil,
                    rowKind: SegmentMemberKind.rowKind(kind))
                row.segmentKey = SegmentKey.make(
                    edinetCode: edinetCode, localName: source.labelRaw, prefix: prefix).description
                row.prefix = prefix
                position = rows.count
                index[source.labelRaw] = position
                rows.append(row)
            }
            write(
                &rows[position], source.amount, snapshot.sourceKind, snapshot.denominatorTag,
                source.decimals)
        }
    }

    private static func applyExplicitZeros(_ rows: inout [BreakdownRowPayload]) {
        for index in rows.indices {
            if let sales = rows[index].externalSales, sales.value == 0 {
                rows[index].externalSales?.basis = breakdownMetricCellBasisExplicitZero
            }
            if let assets = rows[index].segmentAssetsCell, assets.value == 0 {
                rows[index].segmentAssetsCell?.basis = breakdownMetricCellBasisExplicitZero
            }
            if let ce = rows[index].capitalExpenditures, ce.value == 0 {
                rows[index].capitalExpenditures?.basis = breakdownMetricCellBasisExplicitZero
            }
            if let naa = rows[index].noncurrentAssetAdditions, naa.value == 0 {
                rows[index].noncurrentAssetAdditions?.basis = breakdownMetricCellBasisExplicitZero
            }
        }
    }

    private struct DifferenceSpec {
        var key: String
        var read: (BreakdownRowPayload) -> Double?
        var decimals: (BreakdownRowPayload) -> Int?
        var write: (inout BreakdownRowPayload, BreakdownMetricCellPayload) -> Void
        var consolidated: Double?
        var consolidatedDecimals: Int?
        var source: String
    }

    struct DifferenceResult {
        var rows: [BreakdownRowPayload]
        var roundingGaps: [String: Double]
        var beyondTolerance: [String]
    }

    private static func differenceMetrics(
        assets: BreakdownSnapshot?, capitalExpenditures: BreakdownSnapshot?,
        noncurrentAssetAdditions: BreakdownSnapshot?, external: BreakdownSnapshot?,
        segment: BreakdownSnapshotPayload
    ) -> [DifferenceSpec] {
        [
            DifferenceSpec(
                key: segmentCellExternalSales,
                read: { $0.externalSales?.value },
                decimals: { $0.externalSales?.decimals },
                write: { $0.externalSales = $1 },
                consolidated: entityAmount(external?.rows.map(payloadRow) ?? [])
                    ?? nonzero(external?.denominator)
                    ?? (external == nil && Xbrl.segmentTrueExternalRevenueTags.contains(
                        segment.denominatorTag)
                        ? entityAmount(segment.rows) ?? nonzero(segment.denominator) : nil),
                consolidatedDecimals: entityDecimals(external?.rows ?? []),
                source: external?.denominatorTag ?? segment.denominatorTag),
            DifferenceSpec(
                key: capexCellSegmentAssets,
                read: { $0.segmentAssetsCell?.value ?? $0.segmentAssets },
                decimals: { $0.segmentAssetsCell?.decimals },
                write: { $0.segmentAssetsCell = $1; $0.segmentAssets = $1.value },
                consolidated: entityAmount(assets?.rows.map(payloadRow) ?? [])
                    ?? nonzero(assets?.denominator),
                consolidatedDecimals: entityDecimals(assets?.rows ?? []),
                source: assets?.denominatorTag ?? capexCellSegmentAssets),
            DifferenceSpec(
                key: segmentCellCapitalExpenditures,
                read: { $0.capitalExpenditures?.value },
                decimals: { $0.capitalExpenditures?.decimals },
                write: { $0.capitalExpenditures = $1 },
                consolidated: entityAmount(capitalExpenditures?.rows.map(payloadRow) ?? [])
                    ?? nonzero(capitalExpenditures?.denominator),
                consolidatedDecimals: entityDecimals(capitalExpenditures?.rows ?? []),
                source: capitalExpenditures?.denominatorTag ?? segmentCellCapitalExpenditures),
            DifferenceSpec(
                key: segmentCellNoncurrentAssetAdditions,
                read: { $0.noncurrentAssetAdditions?.value },
                decimals: { $0.noncurrentAssetAdditions?.decimals },
                write: { $0.noncurrentAssetAdditions = $1 },
                consolidated: entityAmount(noncurrentAssetAdditions?.rows.map(payloadRow) ?? [])
                    ?? nonzero(noncurrentAssetAdditions?.denominator),
                consolidatedDecimals: entityDecimals(noncurrentAssetAdditions?.rows ?? []),
                source: noncurrentAssetAdditions?.denominatorTag
                    ?? segmentCellNoncurrentAssetAdditions),
            DifferenceSpec(
                key: segmentWaterfallMetricProfit,
                read: { $0.profitCell?.value ?? $0.profit },
                decimals: { $0.profitCell?.decimals },
                write: { $0.profitCell = $1; $0.profit = $1.value },
                consolidated: entityProfit(segment.rows),
                consolidatedDecimals: nil,
                source: "profit"),
        ]
    }

    private static func payloadRow(_ row: BreakdownRow) -> BreakdownRowPayload {
        var payload = BreakdownRowPayload(
            labelRaw: row.labelRaw, label: row.label ?? row.labelRaw, amount: row.amount,
            profit: row.profit, rowKind: row.rowKind)
        payload.segmentAssetsCell = cell(
            value: row.amount, basis: breakdownSourceXbrlFacts, source: row.labelRaw,
            decimals: row.decimals)
        return payload
    }

    private static func entityAmount(_ rows: [BreakdownRowPayload]) -> Double? {
        rows.first {
            $0.labelRaw == Xbrl.entityTotalMemberName || $0.rowKind == breakdownRowKindEntityTotal
        }?.amount
    }

    private static func entityProfit(_ rows: [BreakdownRowPayload]) -> Double? {
        rows.first {
            $0.labelRaw == Xbrl.entityTotalMemberName || $0.rowKind == breakdownRowKindEntityTotal
        }?.profit
    }

    private static func nonzero(_ value: Double?) -> Double? {
        guard let value, value != 0 else { return nil }
        return value
    }

    private static func entityDecimals(_ rows: [BreakdownRow]) -> Int? {
        rows.first {
            $0.labelRaw == Xbrl.entityTotalMemberName || $0.rowKind == breakdownRowKindEntityTotal
        }?.decimals
    }

    private static func addDifferenceRows(
        _ rows: [BreakdownRowPayload], edinetCode: String, metrics: [DifferenceSpec]
    ) -> DifferenceResult {
        var out = rows
        var difference = BreakdownRowPayload(
            labelRaw: "差額", label: "差額", amount: 0, profit: nil,
            rowKind: breakdownRowKindDifference)
        difference.segmentKey = SegmentKey.text(edinetCode: edinetCode, label: "差額").description
        var anyVisible = false
        var roundingGaps: [String: Double] = [:]
        var beyond: [String] = []
        for metric in metrics {
            guard let consolidated = metric.consolidated else { continue }
            let additiveRows = out.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            let parts = additiveRows.compactMap(metric.read)
            guard !parts.isEmpty else { continue }
            let additive = parts.reduce(0, +)
            let gap = consolidated - additive
            if gap == 0 { continue }
            let decimals = metric.consolidatedDecimals
                ?? additiveRows.compactMap(metric.decimals).min()
            if isSegmentRoundingGap(
                gap: gap, decimals: decimals, summedRowCount: parts.count)
            {
                roundingGaps[metric.key] = gap
                continue
            }
            anyVisible = true
            beyond.append(metric.key)
            metric.write(
                &difference,
                BreakdownMetricCellPayload(
                    value: gap, basis: breakdownSourceXbrlFacts, source: metric.source,
                    decimals: decimals))
        }
        if anyVisible { out.append(difference) }
        return DifferenceResult(rows: out, roundingGaps: roundingGaps, beyondTolerance: beyond)
    }
}
