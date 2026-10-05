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
    /// 行ラベルが全て地域の表は列が見出しの製品名でも geography（7202 の国内/海外×車種）。
    enum TableAxis: Equatable {
        case productOrBusiness
        case customer
        case timing
        case geography
        case unknown
    }

    enum AxisConstraint: Equatable {
        case unconstrained
        case productOnly
        case customerOrTimingOnly
        case geographyOnly
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
        if token.contains("仕向地") { return true }
        if token.contains("地域別") || token.contains("地域") { return true }
        return false
    }

    static func isProductOrBusinessHeading(_ label: String) -> Bool {
        let token = RevenueRecognitionCandidates.compactCell(label)
        if token.isEmpty || isGeographyHeading(token) { return false }
        if isTimingAxisLabel(token) { return false }
        if isDisclosureOmissionProse(token) { return false }
        return token.contains("製品") || token.contains("サービス") || token.contains("事業")
            || token.contains("品種") || token.contains("品目")
    }

    /// 表レベルの製品・事業軸。`事業` 単体は顧客行（市販・非車載事業）にも出るので使わない。
    /// 時点ラベル（一時点で移転される財又はサービス）はサービス / 財より先に時点へ倒す。
    /// 「製品90％のため記載を省略」の散文は軸ラベルではない。
    static func isProductAxisLabel(_ label: String) -> Bool {
        let token = RevenueRecognitionCandidates.compactCell(label)
        if token.isEmpty || isGeographyHeading(token) { return false }
        if isTimingAxisLabel(token) { return false }
        if isDisclosureOmissionProse(token) { return false }
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
        if isGeographyHeading(token) || isBareGeographyLabel(token) { return false }
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
        if token.contains("官公庁") || token.contains("中央省庁") || token.contains("省庁") {
            return true
        }
        if token.contains("地方自治体") || token.contains("自治体") {
            return true
        }
        if token.contains("民間") || token.contains("公共") || token.contains("政府") {
            return true
        }
        if token.contains("業販") { return true }
        if token.contains("金融") || token.contains("銀行・証券") { return true }
        if token.contains("情報通信") { return true }
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
            "タイ", "ロシア", "カナダ", "豪州", "CIS",
        ]
        return regions.contains(token)
    }

    /// 地域キーワードを除いたあとに固有の事業語幹が残らないラベル（アジア(中国を除く) / 日本）。
    /// 国内食料品製造・販売は語幹が残るので地域ではない。
    static func isBareGeographyLabel(_ label: String) -> Bool {
        let token = RevenueRecognitionCandidates.compactCell(label)
        if token.isEmpty || RevenueRecognitionCandidates.isTotalLabel(token) { return false }
        if isTimingAxisLabel(token) { return false }
        if isRegionAxisLabel(token) || isGeographyHeading(token) { return true }
        guard geographyLeftoverStem(token).isEmpty else { return false }
        return geographyKeywords.contains { token.contains($0) }
    }

    static func isOtherResidualLabel(_ label: String) -> Bool {
        let token = RevenueRecognitionCandidates.compactCell(label)
        return token == "その他" || token == "その他の地域" || token == "その他地域"
    }

    /// 金額行のラベルが全て地域（その他は残余として可）。列見出しの製品名は見ない（7202）。
    static func isGeographyOnlyTable(_ table: RevenueRecognitionCandidates.ParsedTable) -> Bool {
        let labels = segmentLabels(in: table)
        guard !labels.isEmpty else { return false }
        let allGeo = labels.allSatisfy { isBareGeographyLabel($0) || isOtherResidualLabel($0) }
        return allGeo && labels.contains(where: isBareGeographyLabel)
    }

    /// 列が見出しの地域（日本 / アジア / 計）で行が売上・利益の報告セグメントマトリクス。
    /// 行ラベル経路の `isGeographyOnlyTable` では拾えない。
    /// 製品行 × 地域列（yjc56482 ロボット/特注機 × 日本/米国）は製品軸のまま残す。
    static func isGeographyOnlyColumnHeaders(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> Bool {
        let labels = columnHeaderLeaves(in: table)
        guard !labels.isEmpty else { return false }
        let allGeo = labels.allSatisfy { isBareGeographyLabel($0) || isOtherResidualLabel($0) }
        guard allGeo && labels.filter(isBareGeographyLabel).count >= 2 else { return false }
        return !hasProductAxisRowLabels(table)
    }

    /// 行の見出し・品目が製品／サービス軸（「製品及びサービス別」＋ロボット等）。
    static func hasProductAxisRowLabels(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> Bool {
        for row in table.structure.rows {
            let tokens = [row.categoryGroup, row.category].compactMap { $0 }
            if tokens.contains(where: { isProductAxisLabel($0) || isProductOrBusinessHeading($0) }) {
                return true
            }
        }
        return false
    }

    /// 製品90％・単一セグメントなどの記載省略文。見出しや品目ラベルではない。
    static func isDisclosureOmissionProse(_ label: String) -> Bool {
        let token = RevenueRecognitionCandidates.compactCell(label)
        return token.contains("記載を省略")
    }

    static func columnHeaderLeaves(
        in table: RevenueRecognitionCandidates.ParsedTable
    ) -> [String] {
        var labels: [String] = []
        for header in table.columnHeaders.values {
            let token = RevenueRecognitionCandidates.compactCell(header)
            let leaf = token.components(separatedBy: " / ").last ?? token
            guard !leaf.isEmpty else { continue }
            if RevenueRecognitionCandidates.isTotalLabel(leaf) { continue }
            if RevenueRecognitionCandidates.isAggregateColumnHeader(leaf) { continue }
            if RevenueRecognitionCandidates.isStubAxisHeader(leaf) { continue }
            if RevenueRecognitionCandidates.isPeriodHeadingLabel(leaf) { continue }
            if RevenueRecognitionCandidates.isUnitCaptionHeader(leaf) { continue }
            labels.append(leaf)
        }
        return labels
    }

    /// 電力小売 / 電力卸売 のように、残余以外が小売と卸売だけの表は販路。
    static func isWholesaleRetailChannelTable(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> Bool {
        let core = segmentLabels(in: table).filter {
            !isOtherResidualLabel($0) && !RevenueRecognitionCandidates.isTotalLabel($0)
        }
        guard core.count >= 2 else { return false }
        let retail = core.contains { $0.contains("小売") }
        let wholesale = core.contains { $0.contains("卸売") }
        return retail && wholesale
            && core.allSatisfy { $0.contains("小売") || $0.contains("卸売") }
    }

    static func tableAxis(of table: RevenueRecognitionCandidates.ParsedTable) -> TableAxis {
        if isGeographyOnlyTable(table) { return .geography }
        if isGeographyOnlyColumnHeaders(table) { return .geography }
        if isWholesaleRetailChannelTable(table) { return .customer }
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
        for row in table.grid.prefix(table.headerRowCount) {
            for cell in row { consume(cell) }
        }
        for row in table.structure.rows {
            if let group = row.categoryGroup { consume(group) }
            if let category = row.category { consume(category) }
        }
        // 同一表の製品行と顧客行（3538 業販＋新車）は顧客軸として残し公開しない。
        if product && customer { return .customer }
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
        let hasGeography = axes.contains(.geography)
        if hasProduct && (hasCustomerOrTiming || hasGeography) { return .productOnly }
        if hasGeography && !hasProduct && !hasCustomerOrTiming { return .geographyOnly }
        if hasCustomerOrTiming && !hasProduct && !hasGeography && !axes.contains(.unknown) {
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
            isTimingAxisLabel($0) || isBareGeographyLabel($0) || isGeographyHeading($0)
                || isOtherResidualLabel($0)
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
        if labels.allSatisfy({ isBareGeographyLabel($0) || isGeographyHeading($0) }) {
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

    static func segmentLabels(in table: RevenueRecognitionCandidates.ParsedTable) -> [String] {
        table.structure.rows.compactMap { row in
            guard row.amountKind == .segment else { return nil }
            let token = row.category ?? row.categoryGroup ?? ""
            return token.isEmpty ? nil : token
        }
    }

    static let geographyKeywords: [String] =
        Xbrl.segmentGeographyLabelKeywordsJa + [
            "国外", "本邦", "韓国", "台湾", "中南米", "タイ", "ロシア", "カナダ", "豪州", "CIS",
        ]

    static func geographyLeftoverStem(_ label: String) -> String {
        var stripped = RevenueRecognitionCandidates.compactCell(label)
        for keyword in geographyKeywords.sorted(by: { $0.count > $1.count }) {
            stripped = stripped.replacingOccurrences(of: keyword, with: "")
        }
        for extra in [
            "を除く", "を含む", "除く", "以外", "及び", "および",
            "北東", "南西", "東南", "西北",
        ] {
            stripped = stripped.replacingOccurrences(of: extra, with: "")
        }
        return stripped.filter { !$0.isWhitespace && !$0.isPunctuation && $0 != "・" && $0 != "、" }
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
