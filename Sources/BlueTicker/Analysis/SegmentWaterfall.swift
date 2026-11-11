// 報告セグメントの年次ウォーターフォール。スナップショットは当期だけを持ち、
// ここで複数年の格納行を指標ごとに並べる。丸め幅の差額は差額行に出さない。

import Foundation

public enum SegmentWaterfall {
    public static func jsonObject(
        code: String,
        metric: String,
        years: [(fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)],
        key: String?
    ) -> [String: Any] {
        [
            "code": code,
            "metric": metric,
            "years": years.map { year in
                yearObject(
                    fyEnd: year.fyEnd, docID: year.docID, payload: year.payload,
                    metric: metric, key: key)
            },
        ]
    }

    public static func yearObject(
        fyEnd: String, docID: String, payload: BreakdownSnapshotPayload,
        metric: String, key: String?
    ) -> [String: Any] {
        var object: [String: Any] = [
            "fy_end": fyEnd,
            "doc_id": docID,
            "rows": payload.rows.compactMap { row -> [String: Any]? in
                if let key, row.segmentKey != key { return nil }
                guard let cell = cell(row, metric: metric) else { return nil }
                var item: [String: Any] = [
                    "label": row.label,
                    "row_kind": row.rowKind,
                    "value": breakdownJSONAmount(cell.value),
                ]
                if let segmentKey = row.segmentKey { item[breakdownRowSegmentKeyKey] = segmentKey }
                if let decimals = cell.decimals { item["decimals"] = decimals }
                if let source = optionalSource(cell) { item["source"] = source }
                if let basis = optionalBasis(cell) { item["basis"] = basis }
                return item
            },
        ]
        if let salesBasis = payload.salesBasis { object[segmentSalesBasisKey] = salesBasis }
        if let gap = payload.roundingGaps?[metric] {
            object[segmentRoundingGapsKey] = [metric: breakdownJSONAmount(gap)]
        }
        return object
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
