// 地域別売上（geography 軸）の年次推移。スナップショットは当期だけを持つので、
// 格納済みの複数年を並べ、地域ラベルを `GeographyRegion` で正規化する。
// 年ごとに地域の切り方が変わる会社（トヨタ FY2026 など）は、成分をつなぎ直して
// 比べられる年の塊（comparable_group）に分け、塊の境目で line_cut を立てる。
// 値は円そのもの。未取り込みの年は作らない。

import Foundation

public enum GeographyWaterfall {
    /// これ以上は粗くしない（`GeographyRegion.liftTables` の最大の段）。
    static let maxLiftLevel = 2

    struct Region {
        var label: String
        var region: String?
        var components: [String]
        var value: Double
    }

    struct Block {
        var key: String
        var members: [String]
        var value: Double
    }

    public static func jsonObject(
        code: String,
        years: [(fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)],
        fiscalYear: String? = nil,
        limit: Int = Api.financialsYearsDefault
    ) -> [String: Any] {
        let usable = years
            .filter { !regions(of: $0.payload).isEmpty }
            .sorted { $0.fyEnd > $1.fyEnd }
        var selected = usable
        if let fiscalYear {
            selected = selected.filter {
                SegmentWaterfall.matchesFiscalYear($0.fyEnd, query: fiscalYear)
            }
        } else {
            selected = Array(selected.prefix(max(1, limit)))
        }
        // 比べられる塊は、選んだ年の外の年を見ずに新しい方から決める。
        let runs = comparableRuns(selected.map { (fyEnd: $0.fyEnd, regions: regions(of: $0.payload)) })
        var objects: [[String: Any]] = []
        for (group, run) in runs.enumerated() {
            let groupComponents = components(
                of: run.indices.map { regions(of: selected[$0].payload) }, level: run.level)
            for (offset, index) in run.indices.enumerated() {
                let year = selected[index]
                let list = regions(of: year.payload)
                var object: [String: Any] = [
                    "fy_end": year.fyEnd,
                    "doc_id": year.docID,
                    segmentWaterfallLineCutKey: offset == run.indices.count - 1
                        && group < runs.count - 1,
                    "comparable_group": group,
                    "regions": list.map(regionJSON),
                    "comparable_regions": blocks(of: list, components: groupComponents, level: run.level).map(blockJSON),
                    "comparable_level": run.level,
                ]
                if let fy = SegmentWaterfall.fiscalYear(fyEnd: year.fyEnd) {
                    object["fiscal_year"] = fy
                }
                objects.append(object)
            }
        }
        return ["code": code, "axis": breakdownAxisGeography, "years": objects]
    }

    // MARK: - 行の取り出し

    static func regions(of payload: BreakdownSnapshotPayload) -> [Region] {
        var merged: [String: Region] = [:]
        var order: [String] = []
        for row in payload.rows where row.rowKind == "segment" {
            let normalized = GeographyRegion.normalize(label: row.label)
            let id = normalized.region ?? "raw:\(row.label)"
            if var existing = merged[id] {
                existing.value += row.amount
                merged[id] = existing
            } else {
                order.append(id)
                merged[id] = Region(
                    label: row.label, region: normalized.region,
                    components: normalized.components, value: row.amount)
            }
        }
        return order.compactMap { merged[$0] }
    }

    private static func regionJSON(_ region: Region) -> [String: Any] {
        var object: [String: Any] = [
            "label": region.label,
            "value": breakdownJSONAmount(region.value),
        ]
        object["region"] = region.region ?? NSNull()
        if region.components.count > 1 { object["components"] = region.components }
        return object
    }

    private static func blockJSON(_ block: Block) -> [String: Any] {
        ["region": block.key, "members": block.members, "value": breakdownJSONAmount(block.value)]
    }

    // MARK: - 比べられる塊

    struct Run {
        var indices: [Int]
        var level: Int
    }

    /// 新しい年から順に、隣り合う年（決算期が 1 年差）で、地域の切り方が同じ（または
    /// 持ち上げて同じにできる）間だけを 1 つの塊にする。塊は新しい方から返す。
    static func comparableRuns(
        _ years: [(fyEnd: String, regions: [Region])]
    ) -> [Run] {
        var runs: [Run] = []
        var index = 0
        while index < years.count {
            var indices = [index]
            var level = unifiableLevel([years[index].regions]) ?? 0
            var next = index + 1
            while next < years.count,
                SegmentWaterfall.isAdjacentYear(
                    newer: years[indices.last!].fyEnd, older: years[next].fyEnd),
                let found = unifiableLevel(indices.map { years[$0].regions } + [years[next].regions])
            {
                indices.append(next)
                level = found
                next += 1
            }
            runs.append(Run(indices: indices, level: level))
            index = next
        }
        return runs
    }

    /// 全年の地域を `level` 段だけ持ち上げた成分で、同じ成分の集合かつ同じ塊分けになる最小の段。
    /// 辞書に無いラベルがある年は、ラベルそのものが全年に同じようにあるときだけ揃う。
    static func unifiableLevel(_ years: [[Region]]) -> Int? {
        for level in 0...maxLiftLevel {
            let partitions = years.map { partition($0, level: level) }
            guard let first = partitions.first else { return nil }
            if partitions.allSatisfy({ $0 == first }) { return level }
            // 年ごとの分け方は違っても、全年を通した成分のつなぎで塊が揃うなら揃っている。
            let universes = years.map { Set($0.flatMap { atoms($0, level: level) }) }
            if let universe = universes.first, universes.allSatisfy({ $0 == universe }),
                !universe.isEmpty
            {
                return level
            }
        }
        return nil
    }

    private static func atoms(_ region: Region, level: Int) -> [String] {
        guard region.region != nil else { return ["raw:\(region.label)"] }
        return region.components.map { GeographyRegion.lift($0, level: level) }
    }

    private static func partition(_ regions: [Region], level: Int) -> Set<Set<String>> {
        Set(regions.map { Set(atoms($0, level: level)) })
    }

    /// 塊（成分の連結成分）。成分が重なる地域を全年でまとめて、年をまたいで同じ塊キーにする。
    static func components(of years: [[Region]], level: Int) -> [Set<String>] {
        var groups: [Set<String>] = []
        for region in years.flatMap({ $0 }) {
            var atomSet = Set(atoms(region, level: level))
            var remaining: [Set<String>] = []
            for group in groups {
                if group.isDisjoint(with: atomSet) {
                    remaining.append(group)
                } else {
                    atomSet.formUnion(group)
                }
            }
            remaining.append(atomSet)
            groups = remaining
        }
        return groups.sorted { rank(key($0)) < rank(key($1)) }
    }

    private static func key(_ atoms: Set<String>) -> String {
        atoms.sorted { rank($0) < rank($1) }.joined(separator: "+")
    }

    /// 1 年分の地域を塊ごとに足す。塊に入る地域が無い年の塊は出さない。
    static func blocks(of regions: [Region], components: [Set<String>], level: Int) -> [Block] {
        components.compactMap { component in
            let members = regions.filter { Set(atoms($0, level: level)).isSubset(of: component) }
            guard !members.isEmpty else { return nil }
            return Block(
                key: key(component), members: members.map { $0.region ?? $0.label }.sorted(),
                value: members.reduce(0) { $0 + $1.value })
        }
    }

    private static func rank(_ key: String) -> Int {
        let head = key.split(separator: "+").first.map(String.init) ?? key
        return GeographyRegion.order.firstIndex(of: head) ?? GeographyRegion.order.count
    }
}
