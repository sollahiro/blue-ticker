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
                return BreakdownItemInput(
                    key: key, label: segment.label, value: value, link: link,
                    mergedFrom: index == 0 ? [] : mergedFrom(key: key, link: link, year: year))
            }
            return BreakdownColumnInput(
                label: columnLabel(year), items: items, groups: index == 0 ? [] : groups(year))
        }
    }

    /// API の `reorgs[]`（merge / split / replace / regroup）を、旧区分と新区分のキーの組にする。
    private static func groups(_ year: SegmentWaterfallResponse.Year) -> [BreakdownReorgGroup] {
        (year.reorgs ?? []).compactMap { reorg in
            let from = (reorg.from ?? []).compactMap(\.segmentKey)
            let to = (reorg.to ?? []).compactMap(\.segmentKey)
            guard !from.isEmpty, !to.isEmpty else { return nil }
            return BreakdownReorgGroup(fromKeys: from, toKeys: to)
        }
    }

    /// API が merge（旧 2 以上・新 1）と示した組のうち、この行が新区分側にあるときの旧区分のキー。
    private static func mergedFrom(
        key: String, link: BreakdownLink, year: SegmentWaterfallResponse.Year
    ) -> [String] {
        guard link == .reorg else { return [] }
        for reorg in year.reorgs ?? [] where reorg.kind == "merge" {
            guard reorg.to?.contains(where: { $0.segmentKey == key }) == true else { continue }
            let keys = (reorg.from ?? []).compactMap(\.segmentKey)
            if keys.count >= 2 { return keys }
        }
        return []
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

    /// 再編で複数の旧区分が 1 つの新区分に統合されたとき、過去の年の旧区分を 1 本に合算する。
    /// 統合元は、API が merge と示したときはそのキー。示さないとき（古いサーバー）は
    /// 「その年の組替の行が 1 つ」かつ「前年に、どの行ともつながっていない行が 2 つ以上ある」なら、それらを統合元とみなす。
    /// さらに前の年も、統合元につながる系列が複数あれば同じ要領でまとめる（他の行が使っている系列は触らない）。
    /// 1 つの旧区分が分割された場合は、行き先が分からないので何もしない。
    static func collapsingReorgs(_ columns: [BreakdownColumnInput]) -> [BreakdownColumnInput] {
        var cols = columns
        guard cols.count > 1 else { return cols }
        for k in stride(from: cols.count - 1, through: 1, by: -1) {
            let reorgItems = cols[k].items.filter { $0.link == .reorg }
            let previousKeys = Set(cols[k - 1].items.map(\.key))
            let referenced = Set(cols[k].items.compactMap { connectSource($0.link) })
            for target in reorgItems {
                var sources = Set(target.mergedFrom).intersection(previousKeys)
                if sources.isEmpty, reorgItems.count == 1 {
                    sources = previousKeys.subtracting(referenced)
                }
                guard sources.count >= 2 else { continue }
                collapse(&cols, sources: sources, into: target, at: k)
                // 1 つに集約した組は、帯の組としては出さない。
                cols[k].groups.removeAll { $0.toKeys == [target.key] }
            }
        }
        return cols
    }

    /// `column - 1` の `sources` を 1 行にし、`target`（`column` の行）からつなぐ。前の年も辿る。
    private static func collapse(
        _ cols: inout [BreakdownColumnInput], sources: Set<String>, into target: BreakdownItemInput, at column: Int
    ) {
        var group = sources
        var level = column - 1
        var label = target.label
        var upperKey = target.key
        var upperLevel = column
        while true {
            let members = cols[level].items.filter { group.contains($0.key) }
            guard !members.isEmpty else { return }
            let mergedKey = "merged|\(level)|\(target.key)"
            var link: BreakdownLink = .none
            var continues = false
            if level > 0 {
                let previousKeys = Set(cols[level - 1].items.map(\.key))
                let predecessors = Set(members.compactMap { connectSource($0.link) }).intersection(previousKeys)
                // 同じ前年の行を、統合元以外が使っていなければまとめて辿れる。
                let usedElsewhere = cols[level].items.contains { item in
                    guard !group.contains(item.key), let from = connectSource(item.link) else { return false }
                    return predecessors.contains(from)
                }
                if predecessors.count > 1, !usedElsewhere {
                    link = .connect("merged|\(level - 1)|\(target.key)")
                    continues = true
                } else if predecessors.count == 1, let only = predecessors.first {
                    link = .connect(only)
                }
                if continues { group = predecessors }
            }
            let merged = BreakdownItemInput(
                key: mergedKey, label: label, value: members.reduce(0) { $0 + $1.value }, link: link)
            let memberKeys = Set(members.map(\.key))
            cols[level].items.removeAll { memberKeys.contains($0.key) }
            cols[level].items.append(merged)
            // 1 つ新しい列の行から、できた行へつなぎ直す。
            for index in cols[upperLevel].items.indices where cols[upperLevel].items[index].key == upperKey {
                cols[upperLevel].items[index].link = .connect(mergedKey)
            }
            guard continues else { return }
            label = members.max(by: { $0.value < $1.value })?.label ?? label
            upperKey = mergedKey
            upperLevel = level
            level -= 1
        }
    }

    private static func connectSource(_ link: BreakdownLink) -> String? {
        if case .connect(let from) = link { return from }
        return nil
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
