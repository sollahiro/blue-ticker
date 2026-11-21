import Foundation

/// 前年の同じ系列とのつなぎ。
enum BreakdownLink: Equatable {
    /// 前年の `key` の行とつなぐ（connect / rename）。
    case connect(String)
    /// 組替。前年のどの行から来たかは API に無いので、つながない。
    case reorg
    /// 前年に対応する行が無い、または結べない。
    case none
}

struct BreakdownItemInput: Equatable {
    var key: String
    var label: String
    var value: Double
    var link: BreakdownLink
    /// 組替のうち、前年の複数の旧区分が統合されたと API が示したときの旧区分のキー。
    var mergedFrom: [String] = []
}

/// 前年の旧区分と今年の新区分の、ひとまとまりの再編（API の `reorgs[]`）。
/// 旧区分（`fromKeys`）と新区分（`toKeys`）をそれぞれ隣り合わせに積み、塊から塊へ 1 本の帯でつなぐ。
struct BreakdownReorgGroup: Equatable {
    var fromKeys: [String]
    var toKeys: [String]
}

struct BreakdownColumnInput: Equatable {
    var label: String
    var items: [BreakdownItemInput]
    /// 前の列からこの列への再編。
    var groups: [BreakdownReorgGroup] = []
    /// この年に区分の再編があった（年ラベルの下に小さく「再編」を出す）。1 本に集約した再編も含む。
    var reorged: Bool = false
}

/// 棒の中に出す文字の元。
enum BreakdownMark: Equatable {
    case none
    /// 組替で前年と結べない（前年の行が組替の元かもしれないときの「前」側も含む）。
    case reorg
    case new
    case ended
    /// 報告セグメントが無い年（連結合計 1 本）。
    case single
}

struct BreakdownBar: Equatable, Identifiable {
    var column: Int
    var key: String
    var label: String
    var value: Double
    var mark: BreakdownMark
    /// 系列の色番号。改名してもつながっていれば同じ。
    var colorIndex: Int
    /// 0...1 に正規化した座標（原点は左上、y は下向き）。
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var id: String { "\(column)|\(key)" }
}

/// 棒と棒の間のつなぎ。4 点（左上・右上・右下・左下）。
struct BreakdownRibbon: Equatable, Identifiable {
    var fromColumn: Int
    var key: String
    /// 負のときは系列の色を持たない（再編の塊のつなぎ）。中立色で描く。
    var colorIndex: Int
    var leftTop: Double
    var leftBottom: Double
    var rightTop: Double
    var rightBottom: Double
    var leftX: Double
    var rightX: Double

    var id: String { "\(fromColumn)|\(key)" }
}

struct BreakdownSeries: Equatable, Identifiable {
    var id: String
    var label: String
    var colorIndex: Int
}

struct BreakdownLayout: Equatable {
    var columnLabels: [String]
    var columnTotals: [Double]
    /// 各列の棒の中心 x（0...1）。
    var columnCenters: [Double]
    var bars: [[BreakdownBar]]
    var ribbons: [BreakdownRibbon]
    /// 凡例の並び（積み上げの下から上）。
    var series: [BreakdownSeries]
    /// 合計の文字を置くための上端の余白（0...1）。棒はこの下に収まる。
    var headroom: Double
    /// 各列で、前の列からの再編があったか。
    var columnReorged: [Bool] = []
}

/// 報告セグメントが無い年（単一セグメント）の棒のキー。系列の色は付けない。
let singleSegmentKey = "single|total"

enum StackedLayout {
    static let barWidthRatio = 0.6
    static let headroom = 0.12

    static func make(columns: [BreakdownColumnInput]) -> BreakdownLayout {
        let n = columns.count
        guard n > 0 else {
            return BreakdownLayout(
                columnLabels: [], columnTotals: [], columnCenters: [], bars: [], ribbons: [], series: [],
                headroom: headroom)
        }
        let items = columns.map { $0.items.filter { $0.value > 0 } }

        // 1. 系列の同一性。connect でつながった行は同じ系列（名称変更でも色が変わらない）。
        var seriesIDs: [[String: String]] = []
        for (k, column) in items.enumerated() {
            var ids: [String: String] = [:]
            for item in column {
                if k > 0, case .connect(let from) = item.link, let prev = seriesIDs[k - 1][from] {
                    ids[item.key] = prev
                } else {
                    ids[item.key] = item.key
                }
            }
            seriesIDs.append(ids)
        }

        // 2. 積み上げ順。新しい年にある系列を大きい順に下から、消えた系列はその上に（最後に見えた年が新しい順）。
        struct Seen {
            var id: String
            var label: String
            var column: Int
            var value: Double
        }
        var lastSeen: [String: Seen] = [:]
        for (k, column) in items.enumerated() {
            for item in column {
                let id = seriesIDs[k][item.key] ?? item.key
                lastSeen[id] = Seen(id: id, label: item.label, column: k, value: item.value)
            }
        }
        // 再編でつながる系列（旧区分と新区分）は同じ血筋。血筋ごとに積み、年が変わっても位置を保つ。
        var parent: [String: String] = Dictionary(uniqueKeysWithValues: lastSeen.keys.map { ($0, $0) })
        func find(_ id: String) -> String {
            var root = id
            while let next = parent[root], next != root { root = next }
            return root
        }
        func union(_ a: String, _ b: String) {
            let (ra, rb) = (find(a), find(b))
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        for k in 1..<max(n, 1) {
            for group in columns[k].groups {
                let ids =
                    group.fromKeys.compactMap { seriesIDs[k - 1][$0] } + group.toKeys.compactMap { seriesIDs[k][$0] }
                for id in ids.dropFirst() { if let first = ids.first { union(first, id) } }
            }
        }
        var families: [String: [Seen]] = [:]
        for seen in lastSeen.values { families[find(seen.id), default: []].append(seen) }
        // 血筋の並び: 新しい年まで続く血筋を先に、同じなら最大の系列が大きい順。
        // 血筋の中は、新しい年にある系列を大きい順、旧区分は最後。
        func inOrder(_ a: Seen, _ b: Seen) -> Bool {
            if a.column != b.column { return a.column > b.column }
            if a.value != b.value { return a.value > b.value }
            return a.id < b.id
        }
        let sortedFamilies = families.map { (root: $0.key, members: $0.value.sorted(by: inOrder)) }
            .sorted { a, b in
                guard let x = a.members.first, let y = b.members.first else { return a.root < b.root }
                return inOrder(x, y)
            }
        let ordered = sortedFamilies.flatMap(\.members)
        // 積み上げの位置（下から）。色は後で、再編元を行き先の色に寄せる。
        var position: [String: Int] = [:]
        var palette = 0
        for seen in ordered {
            if seen.id == singleSegmentKey {
                position[seen.id] = -1
            } else {
                position[seen.id] = palette
                palette += 1
            }
        }
        var colorIndex = position
        // 再編元（旧区分）は、行き先（新区分）の色にそろえる。新しい年から順に決めて、再編が続いても最新の色になる。
        // 旧と新の組は大きい順に対応づけ、旧が多いときは最後の新区分に寄せる。
        for k in stride(from: n - 1, through: 1, by: -1) {
            for group in columns[k].groups {
                func ids(_ keys: [String], _ column: Int) -> [String] {
                    keys.compactMap { key in
                        items[column].first { $0.key == key }.flatMap { seriesIDs[column][$0.key] }
                    }
                }
                func value(_ id: String, _ column: Int) -> Double {
                    items[column].first { (seriesIDs[column][$0.key] ?? $0.key) == id }?.value ?? 0
                }
                let from = ids(group.fromKeys, k - 1).sorted { value($0, k - 1) > value($1, k - 1) }
                let to = ids(group.toKeys, k).sorted { value($0, k) > value($1, k) }
                guard !to.isEmpty else { continue }
                for (index, id) in from.enumerated() where position[id] != -1 {
                    colorIndex[id] = colorIndex[to[min(index, to.count - 1)]] ?? colorIndex[id]
                }
            }
        }
        let series = ordered.map {
            BreakdownSeries(id: $0.id, label: $0.label, colorIndex: colorIndex[$0.id] ?? 0)
        }

        // 3. 列ごとの合計と縮尺。
        let totals = items.map { $0.reduce(0) { $0 + $1.value } }
        let maxTotal = totals.max() ?? 0
        let scale = maxTotal > 0 ? (1 - headroom) / maxTotal : 0
        let barWidth = barWidthRatio / Double(n)
        let centers = (0..<n).map { (Double($0) + 0.5) / Double(n) }

        // 4. 印（再編・新規・終了）。
        // 再編の組に入る行は、塊の帯で示すので印を出さない。
        var groupedFrom: [Set<String>] = Array(repeating: [], count: n)
        var groupedTo: [Set<String>] = Array(repeating: [], count: n)
        for k in 1..<n {
            for group in columns[k].groups {
                groupedFrom[k - 1].formUnion(group.fromKeys)
                groupedTo[k].formUnion(group.toKeys)
            }
        }
        var marks: [[String: BreakdownMark]] = Array(repeating: [:], count: n)
        for k in 1..<n {
            let hasReorg = items[k].contains { $0.link == .reorg && !groupedTo[k].contains($0.key) }
            var referenced = Set<String>()
            for item in items[k] {
                switch item.link {
                case .connect(let from) where seriesIDs[k - 1][from] != nil:
                    referenced.insert(from)
                case .reorg:
                    marks[k][item.key] = groupedTo[k].contains(item.key) ? BreakdownMark.none : .reorg
                default:
                    marks[k][item.key] = groupedTo[k].contains(item.key) ? BreakdownMark.none : .new
                }
            }
            for previous in items[k - 1] where !referenced.contains(previous.key) {
                if groupedFrom[k - 1].contains(previous.key) { continue }
                // 組替が出た年は、消えた行が組替の元かもしれない。「終了」と断定しない。
                marks[k - 1][previous.key] = hasReorg ? .reorg : .ended
            }
        }

        // 5. 棒と、つなぎ。
        var bars: [[BreakdownBar]] = []
        for k in 0..<n {
            var cumulative = 0.0
            var column: [BreakdownBar] = []
            var sorted = items[k].sorted {
                let a = position[seriesIDs[k][$0.key] ?? $0.key] ?? 0
                let b = position[seriesIDs[k][$1.key] ?? $1.key] ?? 0
                return a < b
            }
            // 再編の組は、旧区分どうし・新区分どうしを隣り合わせに積む。
            var clusters = columns[k].groups.map(\.toKeys)
            if k + 1 < n { clusters += columns[k + 1].groups.map(\.fromKeys) }
            sorted = clustered(sorted, clusters: clusters)
            for item in sorted {
                let height = item.value * scale
                cumulative += height
                column.append(
                    BreakdownBar(
                        column: k, key: item.key, label: item.label, value: item.value,
                        mark: item.key == singleSegmentKey ? .single : (marks[k][item.key] ?? .none),
                        colorIndex: colorIndex[seriesIDs[k][item.key] ?? item.key] ?? 0,
                        x: centers[k] - barWidth / 2, y: 1 - cumulative,
                        width: barWidth, height: height))
            }
            bars.append(column)
        }

        var ribbons: [BreakdownRibbon] = []
        if n > 1 {
            for k in 1..<n {
                for item in items[k] {
                    guard case .connect(let from) = item.link,
                        let source = bars[k - 1].first(where: { $0.key == from }),
                        let target = bars[k].first(where: { $0.key == item.key })
                    else { continue }
                    ribbons.append(
                        BreakdownRibbon(
                            fromColumn: k - 1, key: item.key, colorIndex: target.colorIndex,
                            leftTop: source.y, leftBottom: source.y + source.height,
                            rightTop: target.y, rightBottom: target.y + target.height,
                            leftX: source.x + source.width, rightX: target.x))
                }
            }
        }

        if n > 1 {
            for k in 1..<n {
                for (index, group) in columns[k].groups.enumerated() {
                    let source = bars[k - 1].filter { group.fromKeys.contains($0.key) }
                    let target = bars[k].filter { group.toKeys.contains($0.key) }
                    guard let first = source.first, let second = target.first else { continue }
                    ribbons.append(
                        BreakdownRibbon(
                            fromColumn: k - 1, key: "group|\(k)|\(index)", colorIndex: -1,
                            leftTop: source.map(\.y).min() ?? first.y,
                            leftBottom: source.map { $0.y + $0.height }.max() ?? first.y + first.height,
                            rightTop: target.map(\.y).min() ?? second.y,
                            rightBottom: target.map { $0.y + $0.height }.max() ?? second.y + second.height,
                            leftX: first.x + first.width, rightX: second.x))
                }
            }
        }

        return BreakdownLayout(
            columnLabels: columns.map(\.label), columnTotals: totals, columnCenters: centers,
            bars: bars, ribbons: ribbons, series: series, headroom: headroom,
            columnReorged: columns.map(\.reorged))
    }

    /// `clusters` の各組を、先頭の行の位置に寄せて連続させる。
    private static func clustered(_ items: [BreakdownItemInput], clusters: [[String]]) -> [BreakdownItemInput] {
        var result = items
        for cluster in clusters {
            let keys = Set(cluster)
            guard let first = result.firstIndex(where: { keys.contains($0.key) }) else { continue }
            let members = result.filter { keys.contains($0.key) }
            guard members.count > 1 else { continue }
            result.removeAll { keys.contains($0.key) }
            result.insert(contentsOf: members, at: min(first, result.count))
        }
        return result
    }
}
