// segment 軸の行へ、報告セグメント表の他の列（セグメント資産・固定資産の増加額・持分法投資）を
// セルとして載せる。行は報告セグメント member のローカル名（labelRaw）で突き合わせる。
// 値は capex 軸・旧 equity_method_investments 軸と同じ決定論の正規化から取る（Jev は使わない）。
// segment に無い member の値は捨て、warnings に `segment_metric_rows_unmatched` を残す。

import Foundation

enum SegmentMetricCells {
    static let warningUnmatchedRows = "segment_metric_rows_unmatched"

    /// segment / reconciling 行だけを突き合わせる（EntityTotal・小計は分母側にある）。
    private static func isMatchable(_ rowKind: String) -> Bool {
        rowKind == "segment" || rowKind == "reconciling"
    }

    /// `capex` は `CapexNormalizer.normalize` の結果（`segment_assets` / `flow` セルだけ使う。Overview は使わない）。
    /// `equityMethod` は持分法投資のスナップショット（行の `amount` が値）。
    static func merge(
        segment: BreakdownSnapshotPayload,
        capex: BreakdownSnapshotPayload?,
        equityMethod: BreakdownSnapshotPayload?
    ) -> BreakdownSnapshotPayload {
        var out = segment
        var index: [String: Int] = [:]
        for (position, row) in out.rows.enumerated()
        where isMatchable(row.rowKind) && index[row.labelRaw] == nil {
            index[row.labelRaw] = position
        }
        var unmatched = false

        if let capex {
            var anyAssets = false
            var anyFlow = false
            for row in capex.rows where isMatchable(row.rowKind) {
                guard row.segmentAssets != nil || row.flow != nil else { continue }
                guard let position = index[row.labelRaw] else {
                    unmatched = true
                    continue
                }
                if let value = row.segmentAssets {
                    out.rows[position].segmentAssets = value
                    anyAssets = true
                }
                if let value = row.flow {
                    out.rows[position].flow = value
                    anyFlow = true
                }
            }
            if anyAssets {
                out.segmentAssets = capex.segmentAssets
            }
            if anyFlow {
                out.flow = capex.flow
                out.flowMetric = capex.flowMetric
            }
        }

        if let equityMethod {
            var any = false
            for row in equityMethod.rows where isMatchable(row.rowKind) {
                guard let position = index[row.labelRaw] else {
                    unmatched = true
                    continue
                }
                out.rows[position].equityMethodInvestments = row.amount
                any = true
            }
            if any {
                out.equityMethodInvestments = CapexMetricTotalsPayload(
                    denominator: equityMethod.denominator,
                    denominatorTag: equityMethod.denominatorTag)
            }
        }

        if unmatched, !out.warnings.contains(warningUnmatchedRows) {
            out.warnings.append(warningUnmatchedRows)
        }
        return out
    }
}
