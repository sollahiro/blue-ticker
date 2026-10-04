// 収益分解表の行・列構造。Jev 列選択の前に 4 段で決める。
// 1 ラベル域は 1 または 2 列（rowspan/colspan 展開後）
// 2 各行は category_group か category（金額なし見出し・2列目の外側は group）
// 3 各行は subtotal（〜計 / 外部顧客への売上高・収益 / 合計 / 小計 …）か segment
// 4 全てのブロックが表全体合計と同じ小計で閉じる → 並行次元。加算せず事業次元だけ。
// docs/breakdown.md

import Foundation

enum RevenueRecognitionTableStructure {
    enum DimensionKind: Equatable {
        case geography
        case productOrBusiness
        case unknown
    }

    /// 表全体の分解軸。Jev 列選択の前に、製品・事業表を顧客別／時点表より優先する。
    enum TableAxis: Equatable {
        case productOrBusiness
        case customer
        case timing
        case unknown
    }

    enum AxisConstraint: Equatable {
        case unconstrained
        case productOnly
        case customerOrTimingOnly
    }

    enum LabelKind: Equatable {
        case categoryGroup
        case category
    }

    enum AmountKind: Equatable {
        case subtotal
        case segment
    }

    struct LabelArea: Equatable {
        var columnCount: Int
        var headerRowCount: Int
    }

    struct ClassifiedRow: Equatable {
        var index: Int
        var labelKind: LabelKind?
        var categoryGroup: String?
        var category: String?
        var amountKind: AmountKind?
        var hasAmount: Bool
    }

    struct Block: Equatable {
        var heading: String?
        var headingRow: Int?
        var itemRows: [Int]
        var closingTotalRow: Int?
        var kind: DimensionKind
    }

    struct Result: Equatable {
        var labelArea: LabelArea
        var rows: [ClassifiedRow]
        var blocks: [Block]
        var labelColumnCount: Int { labelArea.columnCount }
        var headerRowCount: Int { labelArea.headerRowCount }
    }

    static let undetermined = Result(
        labelArea: LabelArea(columnCount: 1, headerRowCount: 0), rows: [], blocks: [])

    static func inspect(grid: [[String]]) -> Result {
        let rows = padded(grid)
        let area = stage1LabelArea(rows)
        let labeled = stage2ClassifyLabels(rows, area: area)
        let classified = stage3ClassifyAmounts(rows, labeled: labeled)
        return Result(
            labelArea: area, rows: classified, blocks: blocks(from: classified))
    }

    static func padded(_ grid: [[String]]) -> [[String]] {
        let ncol = grid.map(\.count).max() ?? 0
        return grid.map { $0 + Array(repeating: "", count: max(0, ncol - $0.count)) }
    }

    /// (1) ラベル域は 1 または 2 列。rowspan/colspan は expand 済みの grid を前提にする。
    static func stage1LabelArea(_ rows: [[String]]) -> LabelArea {
        let headerRowCount = RevenueRecognitionCandidates.dataStartRow(rows)
        let raw = labelAreaWidth(rows: rows, from: headerRowCount)
        return LabelArea(columnCount: min(max(raw, 1), 2), headerRowCount: headerRowCount)
    }

    /// (2) 各行は category_group か category。金額なし見出しと 2 列ラベル域の外側は group。
    static func stage2ClassifyLabels(
        _ rows: [[String]], area: LabelArea
    ) -> [ClassifiedRow] {
        var classified: [ClassifiedRow] = []
        var currentGroup = ""
        for index in area.headerRowCount..<rows.count {
            let row = rows[index]
            let labelCells = Array(row.prefix(area.columnCount)).map {
                RevenueRecognitionCandidates.compactCell($0)
            }
            let parts = RevenueRecognitionCandidates.distinctLabelParts(labelCells)
                .map(RevenueRecognitionCandidates.stripNoteMarker).filter { !$0.isEmpty }
            if parts.isEmpty { continue }
            if parts.contains(where: RevenueRecognitionCandidates.isPeriodHeadingLabel) {
                continue
            }
            let hasAmount = row.dropFirst(area.columnCount).contains {
                RevenueRecognitionCandidates.isAmountCell($0)
            }
            if parts.count >= 2 {
                let outer = parts[0]
                let inner = parts[1]
                if RevenueRecognitionCandidates.isStubAxisHeader(outer) {
                    classified.append(ClassifiedRow(
                        index: index, labelKind: .category, categoryGroup: nil, category: inner,
                        amountKind: nil, hasAmount: hasAmount))
                    continue
                }
                currentGroup = outer
                classified.append(ClassifiedRow(
                    index: index, labelKind: .category, categoryGroup: outer, category: inner,
                    amountKind: nil, hasAmount: hasAmount))
                continue
            }
            let token = parts[0]
            let outerBlank = area.columnCount >= 2 && labelCells.first.map { $0.isEmpty } == true
            let colspan = area.columnCount >= 2 && labelCells.count >= 2
                && !labelCells[0].isEmpty && labelCells[0] == labelCells[1]
            if !hasAmount {
                currentGroup = token
                classified.append(ClassifiedRow(
                    index: index, labelKind: .categoryGroup, categoryGroup: token, category: nil,
                    amountKind: nil, hasAmount: false))
                continue
            }
            if outerBlank {
                classified.append(ClassifiedRow(
                    index: index, labelKind: .category, categoryGroup: nil, category: token,
                    amountKind: nil, hasAmount: true))
                continue
            }
            if colspan {
                classified.append(ClassifiedRow(
                    index: index, labelKind: .categoryGroup, categoryGroup: token, category: nil,
                    amountKind: nil, hasAmount: true))
                continue
            }
            classified.append(ClassifiedRow(
                index: index, labelKind: .category,
                categoryGroup: currentGroup.isEmpty ? nil : currentGroup, category: token,
                amountKind: nil, hasAmount: true))
        }
        return classified
    }

    /// (3) 各行は subtotal か segment。〜計 / 外部顧客への売上高・収益 / 合計 / 小計。
    static func stage3ClassifyAmounts(
        _ rows: [[String]], labeled: [ClassifiedRow]
    ) -> [ClassifiedRow] {
        labeled.map { row in
            var copy = row
            let display = row.category ?? row.categoryGroup ?? ""
            if isSubtotalLabel(display) {
                copy.amountKind = .subtotal
            } else if row.hasAmount {
                copy.amountKind = .segment
            }
            return copy
        }
    }

    static func isSubtotalLabel(_ label: String) -> Bool {
        RevenueRecognitionCandidates.isTotalLabel(label)
            || RevenueRecognitionCandidates.isGroupSubtotalLabel(label)
    }

    static func isGeographyHeading(_ label: String) -> Bool {
        let token = RevenueRecognitionCandidates.compactCell(label)
        if token.isEmpty { return false }
        if token.contains("地理的区分") || token.contains("所在地") { return true }
        if token.contains("地域別") || token.contains("地域") { return true }
        return false
    }

    static func isProductOrBusinessHeading(_ label: String) -> Bool {
        let token = RevenueRecognitionCandidates.compactCell(label)
        if token.isEmpty || isGeographyHeading(token) { return false }
        if isTimingAxisLabel(token) { return false }
        return token.contains("製品") || token.contains("サービス") || token.contains("事業")
            || token.contains("品種") || token.contains("品目")
    }

    /// 表レベルの製品・事業軸。`事業` 単体は顧客行（市販・非車載事業）にも出るので使わない。
    /// 時点ラベル（一時点で移転される財又はサービス）はサービス / 財より先に時点へ倒す。
    static func isProductAxisLabel(_ label: String) -> Bool {
        let token = RevenueRecognitionCandidates.compactCell(label)
        if token.isEmpty || isGeographyHeading(token) { return false }
        if isTimingAxisLabel(token) { return false }
        if token.contains("品種別") || token.contains("品目別") || token.contains("製品別")
            || token.contains("事業別") || token.contains("サービス別")
        {
            return true
        }
        if token.contains("製品") || token.contains("分野") { return true }
        if token.contains("財又はサービス") || token.contains("財・サービス")
            || token.contains("製品及びサービス")
        {
            return true
        }
        return token.contains("サービス")
    }

    static func isCustomerAxisLabel(_ label: String) -> Bool {
        let token = RevenueRecognitionCandidates.compactCell(label)
        if token.isEmpty || RevenueRecognitionCandidates.isTotalLabel(token) { return false }
        if token.contains("外部顧客") { return false }
        if token.contains("顧客別") || token.contains("主要な顧客") || token.contains("主要顧客") {
            return true
        }
        if token.contains("販売経路") || token.contains("販売チャネル") || token.contains("販売先") {
            return true
        }
        if token.contains("グループ向け") { return true }
        if token.contains("向け") {
            if token.contains("サービス") || token.contains("製品") || token.contains("保証") {
                return false
            }
            return true
        }
        return false
    }

    static func isTimingAxisLabel(_ label: String) -> Bool {
        let token = RevenueRecognitionCandidates.compactCell(label)
        if token.isEmpty || RevenueRecognitionCandidates.isTotalLabel(token) { return false }
        return token.contains("一時点") || token.contains("一定の期間") || token.contains("一定期間")
    }

    /// 行ラベルの地域。見出しの「地域別」ではなく、日本 / 海外 などの値そのもの。
    static func isRegionAxisLabel(_ label: String) -> Bool {
        let token = RevenueRecognitionCandidates.compactCell(label)
        if token.isEmpty || RevenueRecognitionCandidates.isTotalLabel(token) { return false }
        if isTimingAxisLabel(token) { return false }
        if isGeographyHeading(token) { return true }
        let regions = [
            "日本", "海外", "国内", "国外", "本邦", "北米", "米州", "中南米", "欧州",
            "アジア", "オセアニア", "中国", "韓国", "台湾", "米国", "アメリカ", "その他の地域",
        ]
        return regions.contains(token)
    }

    static func tableAxis(of table: RevenueRecognitionCandidates.ParsedTable) -> TableAxis {
        var product = false
        var customer = false
        var timing = false
        func consume(_ raw: String) {
            let token = RevenueRecognitionCandidates.compactCell(raw)
            guard !token.isEmpty else { return }
            if RevenueRecognitionCandidates.isTotalLabel(token) { return }
            if isTimingAxisLabel(token) {
                timing = true
                return
            }
            if isCustomerAxisLabel(token) { customer = true }
            if isProductAxisLabel(token) { product = true }
        }
        if let caption = table.precedingCaption { consume(caption) }
        for header in table.columnHeaders.values { consume(header) }
        for row in table.structure.rows {
            if let group = row.categoryGroup { consume(group) }
            if let category = row.category { consume(category) }
        }
        if product { return .productOrBusiness }
        if customer { return .customer }
        if timing { return .timing }
        return .unknown
    }

    static func axisConstraint(
        tables: [RevenueRecognitionCandidates.ParsedTable]
    ) -> AxisConstraint {
        let axes = tables.map(tableAxis(of:))
        let hasProduct = axes.contains(.productOrBusiness)
        let hasCustomerOrTiming = axes.contains(.customer) || axes.contains(.timing)
        if hasProduct && hasCustomerOrTiming { return .productOnly }
        if hasCustomerOrTiming && !hasProduct && !axes.contains(.unknown) {
            return .customerOrTimingOnly
        }
        return .unconstrained
    }

    static func kind(of heading: String?) -> DimensionKind {
        guard let heading, !heading.isEmpty else { return .unknown }
        if isGeographyHeading(heading) || isRegionAxisLabel(heading) { return .geography }
        if isTimingAxisLabel(heading) { return .unknown }
        if isProductOrBusinessHeading(heading) { return .productOrBusiness }
        return .unknown
    }

    static func blocks(from rows: [ClassifiedRow]) -> [Block] {
        var blocks: [Block] = []
        var open: Block?
        func flushClosed() {
            guard let block = open, block.closingTotalRow != nil, !block.itemRows.isEmpty else {
                return
            }
            blocks.append(block)
        }
        for row in rows {
            if row.labelKind == .categoryGroup, row.amountKind == nil {
                if let block = open, block.closingTotalRow == nil, !block.itemRows.isEmpty {
                    continue
                }
                flushClosed()
                open = Block(
                    heading: row.categoryGroup, headingRow: row.index, itemRows: [],
                    closingTotalRow: nil, kind: kind(of: row.categoryGroup))
                continue
            }
            if row.amountKind == .subtotal {
                if var block = open, !block.itemRows.isEmpty {
                    block.closingTotalRow = row.index
                    open = block
                    flushClosed()
                }
                open = nil
                continue
            }
            if row.amountKind == .segment {
                if open == nil {
                    open = Block(
                        heading: nil, headingRow: nil, itemRows: [], closingTotalRow: nil,
                        kind: .unknown)
                }
                open?.itemRows.append(row.index)
            }
        }
        flushClosed()
        return blocks
    }

    /// (4) 複数ブロックが表全体合計と同じ小計で閉じる → 並行次元。加算しない。
    static func stage4ParallelDimensions(
        in structure: Result, grid: [[String]], column: Int, tableTotal: Double?
    ) -> [Block] {
        parallelDimensionBlocks(
            in: structure, grid: grid, column: column, tableTotal: tableTotal)
    }

    static func parallelDimensionBlocks(
        in structure: Result, grid: [[String]], column: Int, tableTotal: Double?
    ) -> [Block] {
        guard let tableTotal else { return [] }
        // 全行が「－」/0/空、または明細が無いブロックは次元ではない（2467 S100YMA4 の
        // その他収益）。顧客契約 / その他収益 / 外部顧客の調整末尾もここに落ちる。
        let blocks = structure.blocks.filter { block in
            !isEmptyOrDashBlock(block, grid: grid, column: column)
        }
        guard blocks.count >= 2 else { return [] }
        let matching = blocks.filter { block in
            guard let row = block.closingTotalRow, row < grid.count, column < grid[row].count,
                  let amount = RevenueRecognitionCandidates.parseAmount(grid[row][column])
            else { return false }
            return RevenueRecognitionCandidates.sumMatches(amount, subtotal: tableTotal, itemCount: 1)
        }
        // 一部のブロックだけが全社合計と一致しても並行次元にしない。残ったブロックの
        // 全てが表合計と同じ小計で閉じるときだけ。
        guard matching.count == blocks.count else { return [] }
        return matching
    }

    /// 並行ブロックは見出しに加え行ラベルで分類する。時点・地域だけのブロックは製品ではない。
    /// 残りがちょうど1つならそれを残す（6287 S100YE10 の見出し無し製品ブロック）。
    static func businessBlock(
        in parallel: [Block], rows: [ClassifiedRow] = []
    ) -> Block? {
        let remaining = parallel.filter { !isTimingOrRegionBlock($0, rows: rows) }
        if remaining.count == 1 { return remaining[0] }
        let business = remaining.filter { classifiedKind(of: $0, rows: rows) == .productOrBusiness }
        if business.count == 1 { return business[0] }
        return nil
    }

    static func isEmptyOrDashBlock(
        _ block: Block, grid: [[String]], column: Int
    ) -> Bool {
        if block.itemRows.isEmpty { return true }
        return block.itemRows.allSatisfy { row in
            guard row < grid.count, column < grid[row].count else { return true }
            let cell = RevenueRecognitionCandidates.compactCell(grid[row][column])
            if cell.isEmpty { return true }
            guard let amount = RevenueRecognitionCandidates.parseAmount(cell) else { return true }
            return amount == 0
        }
    }

    static func isTimingOrRegionBlock(_ block: Block, rows: [ClassifiedRow]) -> Bool {
        if classifiedKind(of: block, rows: rows) == .geography { return true }
        if let heading = block.heading, isTimingAxisLabel(heading) { return true }
        let labels = itemLabels(of: block, rows: rows)
        if block.itemRows.isEmpty { return true }
        if labels.isEmpty { return false }
        return labels.allSatisfy {
            isTimingAxisLabel($0) || isRegionAxisLabel($0) || isGeographyHeading($0)
        }
    }

    static func classifiedKind(of block: Block, rows: [ClassifiedRow]) -> DimensionKind {
        if let heading = block.heading, !heading.isEmpty {
            let fromHeading = kind(of: heading)
            if fromHeading != .unknown { return fromHeading }
        }
        let labels = itemLabels(of: block, rows: rows)
        if labels.isEmpty { return block.kind }
        if labels.allSatisfy(isTimingAxisLabel) { return .unknown }
        if labels.allSatisfy({ isRegionAxisLabel($0) || isGeographyHeading($0) }) {
            return .geography
        }
        if labels.contains(where: isProductAxisLabel) { return .productOrBusiness }
        return block.kind
    }

    static func itemLabels(of block: Block, rows: [ClassifiedRow]) -> [String] {
        let byIndex = Dictionary(uniqueKeysWithValues: rows.map { ($0.index, $0) })
        return block.itemRows.compactMap { index in
            guard let row = byIndex[index] else { return nil }
            let token = row.category ?? row.categoryGroup ?? ""
            return token.isEmpty ? nil : token
        }
    }

    static func labelAreaWidth(rows: [[String]], from firstData: Int) -> Int {
        var counts: [Int: Int] = [:]
        for row in rows.dropFirst(firstData) {
            let hasAmount = row.contains { RevenueRecognitionCandidates.isAmountCell($0) }
            guard hasAmount else { continue }
            let width = RevenueRecognitionCandidates.leadingLabelCells(row).count
            guard width > 0 else { continue }
            counts[width, default: 0] += 1
        }
        return counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key })?.key
            ?? 1
    }
}
