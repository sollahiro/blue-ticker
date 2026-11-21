import Foundation

/// 公開 JSON → 積み上げの入力と、最新期の表。
enum BreakdownBuilder {
    /// `waterfall/segment` の複数年（新しい年が先頭）を、古い順の列にする。
    /// `columnLabel` は年の見出し（例: FY2026）。
    static func segmentColumns(
        _ response: SegmentWaterfallResponse,
        columnLabel: (SegmentWaterfallResponse.Year) -> String
    ) -> [BreakdownColumnInput] {
        response.years.reversed().enumerated().map { index, year in
            let items = year.segments.compactMap { segment -> BreakdownItemInput? in
                guard let value = segment.value else { return nil }
                let key = segment.segmentKey ?? segment.label
                // 積み上げ棒は `line_cut` に関係なく、prior の判定だけでつなぐ（切るのは折れ線の都合）。
                let link: BreakdownLink = index == 0 ? .none : link(for: segment.prior)
                return BreakdownItemInput(key: key, label: segment.label, value: value, link: link)
            }
            return BreakdownColumnInput(label: columnLabel(year), items: items)
        }
    }

    private static func link(for prior: SegmentWaterfallResponse.Prior?) -> BreakdownLink {
        guard let prior else { return .none }
        switch prior.decision {
        case "connect", "rename":
            if let key = prior.segmentKey { return .connect(key) }
            return .none
        case "reorg":
            return .reorg
        default:
            return .none
        }
    }

    /// 地域別売上。行ラベルが前年と同じときだけつなぐ（API に地域のつなぎ判定は無い）。
    static func geographyColumn(
        label: String, previousLabels: Set<String>?, response: BreakdownResponse
    ) -> BreakdownColumnInput {
        let rows = (response.breakdown?.rows ?? []).filter { ($0.rowKind ?? "segment") == "segment" }
        let items = rows.compactMap { row -> BreakdownItemInput? in
            guard let amount = row.amount else { return nil }
            let link: BreakdownLink
            if let previousLabels {
                link = previousLabels.contains(row.label) ? .connect(row.label) : .none
            } else {
                link = .none
            }
            return BreakdownItemInput(key: row.label, label: row.label, value: amount, link: link)
        }
        return BreakdownColumnInput(label: label, items: items)
    }
}

/// セグメントの表の 1 行（最新期）。
struct SegmentSummaryRow: Equatable, Identifiable {
    var key: String
    var label: String
    var colorIndex: Int
    var value: Double
    /// 前年比（倍率 - 1）。前年と結べない行は nil。
    var yoy: Double?
    var profit: Double?
    /// 利益 ÷ 外部売上。
    var margin: Double?
    /// 組替などで前年と比べられない。
    var mark: BreakdownMark

    var id: String { key }
}

struct ShareSummaryRow: Equatable, Identifiable {
    var key: String
    var label: String
    var colorIndex: Int
    /// 構成比（0...1）。
    var share: Double
    /// 前年との構成比の差（ポイント）。前年に同じ区分が無いときは nil。
    var deltaPoints: Double?

    var id: String { key }
}

enum BreakdownSummary {
    /// 最新期の行。大きい順。`profitByKey` は最新期のセグメント利益（`breakdown?axis=segment`）。
    static func segmentRows(
        columns: [BreakdownColumnInput], layout: BreakdownLayout, profitByKey: [String: Double]
    ) -> [SegmentSummaryRow] {
        guard let last = columns.last, let bars = layout.bars.last else { return [] }
        let previous = columns.count > 1 ? columns[columns.count - 2] : nil
        let items = Dictionary(last.items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return bars.compactMap { bar in
            guard let item = items[bar.key] else { return nil }
            var yoy: Double?
            if case .connect(let from) = item.link,
                let source = previous?.items.first(where: { $0.key == from }), source.value > 0
            {
                yoy = item.value / source.value - 1
            }
            let profit = profitByKey[bar.key]
            return SegmentSummaryRow(
                key: bar.key, label: bar.label, colorIndex: bar.colorIndex, value: item.value, yoy: yoy,
                profit: profit, margin: profit.map { $0 / item.value }, mark: bar.mark)
        }
    }

    static func shareRows(columns: [BreakdownColumnInput], layout: BreakdownLayout) -> [ShareSummaryRow] {
        guard let last = columns.last, let bars = layout.bars.last else { return [] }
        let total = last.items.filter { $0.value > 0 }.reduce(0) { $0 + $1.value }
        guard total > 0 else { return [] }
        let previous = columns.count > 1 ? columns[columns.count - 2] : nil
        let previousTotal = previous?.items.filter { $0.value > 0 }.reduce(0) { $0 + $1.value } ?? 0
        let items = Dictionary(last.items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return bars.compactMap { bar in
            guard let item = items[bar.key] else { return nil }
            var delta: Double?
            if case .connect(let from) = item.link,
                let source = previous?.items.first(where: { $0.key == from }), previousTotal > 0
            {
                delta = (item.value / total - source.value / previousTotal) * 100
            }
            return ShareSummaryRow(
                key: bar.key, label: bar.label, colorIndex: bar.colorIndex, share: item.value / total,
                deltaPoints: delta)
        }
    }
}
