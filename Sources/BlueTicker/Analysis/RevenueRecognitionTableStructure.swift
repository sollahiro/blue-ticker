// 収益分解表の行・列構造。Jev 列選択の前に 4 段で決める。
// 1 ラベル域は 1 または 2 列（rowspan/colspan 展開後）
// 2 各行は category_group か category（金額なし見出し・2列目の外側は group）
// 3 各行は subtotal（〜計 / 外部顧客への売上高・収益 / 合計 / 小計 …）か segment
// 4 複数ブロックが表全体合計と同じ小計で閉じる → 並行次元。加算せず事業次元だけ。
// docs/breakdown.md

import Foundation

enum RevenueRecognitionTableStructure {
    enum DimensionKind: Equatable {
        case geography
        case productOrBusiness
        case unknown
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
        return token.contains("製品") || token.contains("サービス") || token.contains("事業")
    }

    static func kind(of heading: String?) -> DimensionKind {
        guard let heading, !heading.isEmpty else { return .unknown }
        if isGeographyHeading(heading) { return .geography }
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
        let matching = structure.blocks.filter { block in
            guard let row = block.closingTotalRow, row < grid.count, column < grid[row].count,
                  let amount = RevenueRecognitionCandidates.parseAmount(grid[row][column])
            else { return false }
            return RevenueRecognitionCandidates.sumMatches(amount, subtotal: tableTotal, itemCount: 1)
        }
        return matching.count >= 2 ? matching : []
    }

    static func businessBlock(in parallel: [Block]) -> Block? {
        let business = parallel.filter { $0.kind == .productOrBusiness }
        if business.count == 1 { return business[0] }
        return nil
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
