// 収益分解表の行・列構造。候補（category_group / category）を組む前に決める。
// ラベル域（rowspan/colspan 展開後の先頭非金額列）、見出しまわり、ブロックを閉じる合計行、
// 同一全社合計を持つ並行次元。docs/breakdown.md

import Foundation

enum RevenueRecognitionTableStructure {
    enum DimensionKind: Equatable {
        case geography
        case productOrBusiness
        case unknown
    }

    struct Block: Equatable {
        var heading: String?
        var headingRow: Int?
        var itemRows: [Int]
        var closingTotalRow: Int?
        var kind: DimensionKind
    }

    struct Result: Equatable {
        var labelColumnCount: Int
        var headerRowCount: Int
        var blocks: [Block]
    }

    static let undetermined = Result(labelColumnCount: 1, headerRowCount: 0, blocks: [])

    static func inspect(grid: [[String]]) -> Result {
        let ncol = grid.map(\.count).max() ?? 0
        let rows = grid.map { $0 + Array(repeating: "", count: max(0, ncol - $0.count)) }
        let headerRowCount = RevenueRecognitionCandidates.dataStartRow(rows)
        let labelColumnCount = labelAreaWidth(rows: rows, from: headerRowCount)
        let blocks = dimensionBlocks(rows: rows, from: headerRowCount)
        return Result(
            labelColumnCount: labelColumnCount, headerRowCount: headerRowCount, blocks: blocks)
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

    /// 見出しまわりがそれぞれ表全体の合計と同じ金額で閉じているブロック。加算しない。
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

    /// 事業軸は製品・サービス・事業ブロック。地理は落とす。特定できなければ nil。
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

    private static func dimensionBlocks(rows: [[String]], from firstData: Int) -> [Block] {
        var blocks: [Block] = []
        var open: Block?
        func flushClosed() {
            guard let block = open, block.closingTotalRow != nil, !block.itemRows.isEmpty else {
                return
            }
            blocks.append(block)
        }
        for index in firstData..<rows.count {
            let row = rows[index]
            let labelCells = RevenueRecognitionCandidates.leadingLabelCells(row)
            let parts = RevenueRecognitionCandidates.distinctLabelParts(labelCells)
                .map(RevenueRecognitionCandidates.stripNoteMarker).filter { !$0.isEmpty }
            if parts.isEmpty { continue }
            if parts.contains(where: RevenueRecognitionCandidates.isPeriodHeadingLabel) { continue }
            let display = parts.last!
            let hasAmt = row.dropFirst(labelCells.count).contains {
                RevenueRecognitionCandidates.isAmountCell($0)
            }
            if RevenueRecognitionCandidates.isTotalLabel(display) {
                if var block = open, !block.itemRows.isEmpty {
                    block.closingTotalRow = index
                    open = block
                    flushClosed()
                }
                open = nil
                continue
            }
            if RevenueRecognitionCandidates.isGroupSubtotalLabel(display) { continue }
            if !hasAmt {
                if let block = open, block.closingTotalRow == nil, !block.itemRows.isEmpty {
                    continue
                }
                flushClosed()
                open = Block(
                    heading: display, headingRow: index, itemRows: [], closingTotalRow: nil,
                    kind: kind(of: display))
                continue
            }
            if open == nil {
                open = Block(
                    heading: nil, headingRow: nil, itemRows: [], closingTotalRow: nil, kind: .unknown)
            }
            open?.itemRows.append(index)
        }
        flushClosed()
        return blocks
    }
}
