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

struct BreakdownColumnInput: Equatable {
    var label: String
    var items: [BreakdownItemInput]
}

/// 棒の中に出す文字の元。
enum BreakdownMark: Equatable {
    case none
    /// 組替で前年と結べない（前年の行が組替の元かもしれないときの「前」側も含む）。
    case reorg
    case new
    case ended
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
}

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
        let ordered = lastSeen.values.sorted { a, b in
            if a.column != b.column { return a.column > b.column }
            if a.value != b.value { return a.value > b.value }
            return a.id < b.id
        }
        var colorIndex: [String: Int] = [:]
        var series: [BreakdownSeries] = []
        for (index, seen) in ordered.enumerated() {
            colorIndex[seen.id] = index
            series.append(BreakdownSeries(id: seen.id, label: seen.label, colorIndex: index))
        }

        // 3. 列ごとの合計と縮尺。
        let totals = items.map { $0.reduce(0) { $0 + $1.value } }
        let maxTotal = totals.max() ?? 0
        let scale = maxTotal > 0 ? (1 - headroom) / maxTotal : 0
        let barWidth = barWidthRatio / Double(n)
        let centers = (0..<n).map { (Double($0) + 0.5) / Double(n) }

        // 4. 印（再編・新規・終了）。
        var marks: [[String: BreakdownMark]] = Array(repeating: [:], count: n)
        for k in 1..<n {
            let hasReorg = items[k].contains { $0.link == .reorg }
            var referenced = Set<String>()
            for item in items[k] {
                switch item.link {
                case .connect(let from) where seriesIDs[k - 1][from] != nil:
                    referenced.insert(from)
                case .reorg:
                    marks[k][item.key] = .reorg
                default:
                    marks[k][item.key] = .new
                }
            }
            for previous in items[k - 1] where !referenced.contains(previous.key) {
                // 組替が出た年は、消えた行が組替の元かもしれない。「終了」と断定しない。
                marks[k - 1][previous.key] = hasReorg ? .reorg : .ended
            }
        }

        // 5. 棒と、つなぎ。
        var bars: [[BreakdownBar]] = []
        for k in 0..<n {
            var cumulative = 0.0
            var column: [BreakdownBar] = []
            let sorted = items[k].sorted {
                let a = colorIndex[seriesIDs[k][$0.key] ?? $0.key] ?? 0
                let b = colorIndex[seriesIDs[k][$1.key] ?? $1.key] ?? 0
                return a < b
            }
            for item in sorted {
                let height = item.value * scale
                cumulative += height
                column.append(
                    BreakdownBar(
                        column: k, key: item.key, label: item.label, value: item.value,
                        mark: marks[k][item.key] ?? .none,
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

        return BreakdownLayout(
            columnLabels: columns.map(\.label), columnTotals: totals, columnCenters: centers,
            bars: bars, ribbons: ribbons, series: series, headroom: headroom)
    }
}
