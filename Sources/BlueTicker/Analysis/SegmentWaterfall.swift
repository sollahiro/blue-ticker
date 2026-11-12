// 報告セグメントの年次ウォーターフォール。スナップショットは当期だけを持ち、
// ここで複数年の格納行を指標ごとに並べる。つなぎは年次応答に載せる（別ルートにしない）。
// 丸め幅の差額は差額行に出さない。未取り込みの年は作らない。

import Foundation

public enum SegmentWaterfall {
    public static func jsonObject(
        code: String,
        metric: String,
        years: [(fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)],
        transitions: [SegmentTransitionDraft] = [],
        key: String? = nil,
        fiscalYear: String? = nil,
        limit: Int = Api.financialsYearsDefault
    ) -> [String: Any] {
        let newestFirst = years.sorted { $0.fyEnd > $1.fyEnd }
        let selected = selectYears(
            newestFirst, key: key, fiscalYear: fiscalYear, limit: limit, transitions: transitions)
        let previousByFyEnd = previousYearIndex(newestFirst)
        return [
            "code": code,
            "metric": metric,
            "years": selected.map { year in
                yearObject(
                    fyEnd: year.fyEnd, docID: year.docID, payload: year.payload,
                    metric: metric, key: key,
                    previous: previousByFyEnd[year.fyEnd].flatMap { fy in
                        newestFirst.first { $0.fyEnd == fy }
                    },
                    yearTransitions: transitions.filter { $0.fyEnd == year.fyEnd },
                    allTransitions: transitions)
            },
        ]
    }

    public static func yearObject(
        fyEnd: String, docID: String, payload: BreakdownSnapshotPayload,
        metric: String, key: String?,
        previous: (fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)? = nil,
        yearTransitions: [SegmentTransitionDraft] = [],
        allTransitions: [SegmentTransitionDraft] = []
    ) -> [String: Any] {
        let seriesKeys = key.map {
            series(seed: $0, transitions: allTransitions.isEmpty ? yearTransitions : allTransitions)
        }
        let items = payload.rows.compactMap { row -> (row: BreakdownRowPayload, item: [String: Any])? in
            if let seriesKeys, let rowKey = row.segmentKey, !seriesKeys.contains(rowKey) {
                return nil
            }
            if seriesKeys != nil, row.rowKind != "segment" { return nil }
            guard var item = metricItem(row, metric: metric) else { return nil }
            if row.rowKind == "segment",
                let prior = priorLink(row: row, previous: previous, transitions: yearTransitions)
            {
                item[segmentWaterfallPriorKey] = prior
            }
            return (row, item)
        }

        var object: [String: Any] = [
            "fy_end": fyEnd,
            "doc_id": docID,
            segmentWaterfallLineCutKey: lineCut(
                fyEnd: fyEnd, previous: previous, payload: payload, transitions: yearTransitions,
                seriesKeys: seriesKeys),
        ]
        if let fiscalYear = fiscalYear(fyEnd: fyEnd) { object["fiscal_year"] = fiscalYear }
        if let salesBasis = payload.salesBasis { object[segmentSalesBasisKey] = salesBasis }
        object[segmentWaterfallSegmentsKey] = items.filter { $0.row.rowKind == "segment" }.map(\.item)

        if seriesKeys == nil {
            let adjustments = items.filter { $0.row.rowKind == "reconciling" }.map(\.item)
            if adjustments.count == 1 {
                object[segmentWaterfallAdjustmentKey] = adjustments[0]
            } else if adjustments.count > 1 {
                object[segmentWaterfallAdjustmentsKey] = adjustments
            }
            if let consolidated = items.first(where: {
                $0.row.rowKind == breakdownRowKindEntityTotal
            })?.item {
                object[segmentWaterfallConsolidatedKey] = consolidated
            }
            if let difference = items.first(where: {
                $0.row.rowKind == breakdownRowKindDifference
            })?.item {
                object[breakdownRowKindDifference] = difference
            }
            if let gap = payload.roundingGaps?[metric] {
                object[segmentRoundingGapsKey] = [metric: breakdownJSONAmount(gap)]
            }
        }
        return object
    }

    public static func publicDecision(
        stored: String, oldKey: String?, newKey: String?
    ) -> String {
        switch stored {
        case segmentTransitionDecisionConnect:
            if let oldKey, let newKey, oldKey != newKey { return segmentWaterfallDecisionRename }
            return segmentTransitionDecisionConnect
        case segmentTransitionDecisionNeedsReview:
            return segmentWaterfallDecisionReorg
        case segmentTransitionDecisionBreak:
            if oldKey != nil, newKey != nil { return segmentWaterfallDecisionReorg }
            return segmentTransitionDecisionBreak
        default:
            return stored
        }
    }

    public static func matchesFiscalYear(_ fyEnd: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 10 { return fyEnd.hasPrefix(String(trimmed.prefix(10))) }
        if let year = Int(trimmed) { return fiscalYear(fyEnd: fyEnd) == year }
        return fyEnd == trimmed
    }

    public static func fiscalYear(fyEnd: String) -> Int? {
        Int(fyEnd.prefix(4))
    }

    public static func isAdjacentYear(newer: String, older: String) -> Bool {
        guard let n = fiscalYear(fyEnd: newer), let o = fiscalYear(fyEnd: older) else {
            return false
        }
        return n - o == 1
    }

    static func cutsLine(_ decision: String) -> Bool {
        decision == segmentWaterfallDecisionReorg || decision == segmentTransitionDecisionBreak
    }

    private static func selectYears(
        _ newestFirst: [(fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)],
        key: String?, fiscalYear: String?, limit: Int, transitions: [SegmentTransitionDraft]
    ) -> [(fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)] {
        var selected = newestFirst
        if let fiscalYear {
            selected = selected.filter { matchesFiscalYear($0.fyEnd, query: fiscalYear) }
        } else {
            selected = Array(selected.prefix(max(1, limit)))
        }
        guard let key else { return selected }
        let chain = series(seed: key, transitions: transitions)
        return selected.filter { year in
            year.payload.rows.contains { row in
                guard let rowKey = row.segmentKey else { return false }
                return chain.contains(rowKey)
            }
        }
    }

    private static func previousYearIndex(
        _ newestFirst: [(fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)]
    ) -> [String: String] {
        let oldestFirst = newestFirst.sorted { $0.fyEnd < $1.fyEnd }
        var map: [String: String] = [:]
        for index in oldestFirst.indices where index > 0 {
            map[oldestFirst[index].fyEnd] = oldestFirst[index - 1].fyEnd
        }
        return map
    }

    static func series(seed: String, transitions: [SegmentTransitionDraft]) -> Set<String> {
        var keys: Set<String> = [seed]
        var changed = true
        while changed {
            changed = false
            for draft in transitions {
                let decision = publicDecision(
                    stored: draft.decision, oldKey: draft.oldKey, newKey: draft.newKey)
                guard decision == segmentTransitionDecisionConnect
                    || decision == segmentWaterfallDecisionRename
                else { continue }
                if let oldKey = draft.oldKey, let newKey = draft.newKey {
                    if keys.contains(oldKey), keys.insert(newKey).inserted { changed = true }
                    if keys.contains(newKey), keys.insert(oldKey).inserted { changed = true }
                }
            }
        }
        return keys
    }

    private static func priorLink(
        row: BreakdownRowPayload,
        previous: (fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)?,
        transitions: [SegmentTransitionDraft]
    ) -> [String: Any]? {
        guard let currentKey = row.segmentKey else { return nil }
        if let draft = transitions.first(where: { $0.newKey == currentKey }) {
            var object: [String: Any] = [
                "decision": publicDecision(
                    stored: draft.decision, oldKey: draft.oldKey, newKey: draft.newKey),
                "basis": draft.basis,
            ]
            if let oldKey = draft.oldKey { object[breakdownRowSegmentKeyKey] = oldKey }
            return object
        }
        guard let previous,
            previous.payload.rows.contains(where: { $0.segmentKey == currentKey })
        else { return nil }
        return [
            breakdownRowSegmentKeyKey: currentKey,
            "decision": segmentTransitionDecisionConnect,
            "basis": segmentTransitionMatchedSameKey,
        ]
    }

    private static func lineCut(
        fyEnd: String,
        previous: (fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)?,
        payload: BreakdownSnapshotPayload,
        transitions: [SegmentTransitionDraft],
        seriesKeys: Set<String>?
    ) -> Bool {
        guard let previous else { return false }
        if !isAdjacentYear(newer: fyEnd, older: previous.fyEnd) { return true }
        let relevant = transitions.filter { draft in
            guard let seriesKeys else { return true }
            return [draft.oldKey, draft.newKey].compactMap { $0 }.contains {
                seriesKeys.contains($0)
            }
        }
        if relevant.contains(where: {
            cutsLine(publicDecision(stored: $0.decision, oldKey: $0.oldKey, newKey: $0.newKey))
        }) {
            return true
        }
        let renamedFrom = Set(
            relevant.compactMap { draft -> String? in
                let decision = publicDecision(
                    stored: draft.decision, oldKey: draft.oldKey, newKey: draft.newKey)
                guard decision == segmentTransitionDecisionConnect
                    || decision == segmentWaterfallDecisionRename
                else { return nil }
                return draft.oldKey
            })
        let previousKeys = segmentKeys(previous.payload, seriesKeys: seriesKeys)
        let currentKeys = segmentKeys(payload, seriesKeys: seriesKeys)
        return !previousKeys.subtracting(currentKeys).subtracting(renamedFrom).isEmpty
    }

    private static func segmentKeys(
        _ payload: BreakdownSnapshotPayload, seriesKeys: Set<String>?
    ) -> Set<String> {
        Set(
            payload.rows.compactMap { row -> String? in
                guard row.rowKind == "segment", let key = row.segmentKey else { return nil }
                if let seriesKeys { return seriesKeys.contains(key) ? key : nil }
                return key
            })
    }

    private static func metricItem(_ row: BreakdownRowPayload, metric: String) -> [String: Any]? {
        guard let cell = cell(row, metric: metric) else { return nil }
        var item: [String: Any] = [
            "label": row.label,
            "value": breakdownJSONAmount(cell.value),
        ]
        if let segmentKey = row.segmentKey { item[breakdownRowSegmentKeyKey] = segmentKey }
        if let decimals = cell.decimals { item["decimals"] = decimals }
        if let source = optionalSource(cell) { item["source"] = source }
        if let basis = optionalBasis(cell) { item["basis"] = basis }
        return item
    }

    private static func cell(_ row: BreakdownRowPayload, metric: String) -> BreakdownMetricCellPayload?
    {
        switch metric {
        case segmentWaterfallMetricExternalSales: return row.externalSales
        case segmentWaterfallMetricProfit: return row.profitCell
        case segmentWaterfallMetricSegmentAssets: return row.segmentAssetsCell
        case segmentWaterfallMetricCapitalExpenditures: return row.capitalExpenditures
        case segmentWaterfallMetricNoncurrentAssetAdditions: return row.noncurrentAssetAdditions
        default: return nil
        }
    }

    private static func optionalSource(_ cell: BreakdownMetricCellPayload) -> String? {
        cell.source.isEmpty ? nil : cell.source
    }

    private static func optionalBasis(_ cell: BreakdownMetricCellPayload) -> String? {
        cell.basis.isEmpty ? nil : cell.basis
    }
}
