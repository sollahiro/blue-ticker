// 収益認識注記の html_table から、決定論で 2 段候補（category_group / category）を組む。
// Jev は当期の全社金額列だけを選び、行ラベルと金額はここが読む。
// docs/breakdown.md

import Foundation

enum RevenueRecognitionCandidates {
    static let totalMarkers = [
        "顧客との契約から生じる収益",
        "顧客との契約から認識した収益",
        "その他の収益",
        "その他収益",
        "その他の源泉から認識した収益",
        "その他の源泉から生じる収益",
        "外部顧客への売上高",
        "外部顧客に対する売上高",
        "外部顧客への収益",
        "外部収益合計",
        "連結合計",
        "連結計",
    ]

    static let balanceMarkers = [
        "契約負債", "契約資産", "受取手形", "売掛金", "一時点で認識", "一定期間にわたり",
        "残存履行義務", "契約の履行のためのコスト", "顧客との契約から生じた債権", "契約残高",
    ]

    static let remainingPerformanceBuckets = [
        "1年以内", "１年以内", "1年超", "１年超", "5年以内", "５年以内",
        "5年超", "５年超", "10年超", "１０年超",
    ]

    static let dashCells: Set<String> = ["―", "－", "-", "−", "—", "─", "‐"]

    struct ParsedTable: Equatable {
        var tableIndex: Int
        var grid: [[String]]
        var headerRowCount: Int
        var columnHeaders: [Int: String]
        var precedingCaption: String?
        var unitCaption: String?
        var period: String?
        var heading: String = ""
        var items: [Item]
        var totals: [Total]
        var groups: [GroupHeader]
        var structure: RevenueRecognitionTableStructure.Result = RevenueRecognitionTableStructure.undetermined
    }

    struct Item: Equatable {
        var group: String
        var label: String
        var row: Int
        var isPartial: Bool
    }

    struct Total: Equatable {
        var label: String
        var row: Int
    }

    struct GroupHeader: Equatable {
        var group: String
        var row: Int
    }

    struct AmountColumn: Equatable {
        var key: String
        var tableIndex: Int
        var column: Int
        var header: String
        var caption: String?
        var unit: String?
    }

    struct BuiltRow: Equatable {
        var categoryGroup: String
        var category: String?
        var amount: Double
        var isPartial: Bool
        var rowKind: String
    }

    /// 契約残高表を除き、金額列がある分解表だけを候補にする。
    static func parse(
        tables: [BreakdownTable], skipBalanceTables: Bool = true
    ) -> [ParsedTable] {
        var parsed: [ParsedTable] = []
        for (index, table) in tables.enumerated() {
            let grid = BreakdownExtractor.markdownToGrid(table.markdown)
            guard !grid.isEmpty else { continue }
            if skipBalanceTables, isContractBalanceTable(grid) { continue }
            guard hasAmountColumn(grid) else { continue }
            parsed.append(parseTable(index: index, grid: grid, table: table))
        }
        return parsed
    }

    static func amountColumns(in tables: [ParsedTable]) -> [AmountColumn] {
        var columns: [AmountColumn] = []
        for table in tables {
            let dataRows = table.grid.dropFirst(table.headerRowCount)
            for (column, header) in table.columnHeaders.sorted(by: { $0.key < $1.key }) {
                let hasAmount = dataRows.contains { row in
                    column < row.count && isAmountCell(row[column])
                }
                guard hasAmount else { continue }
                columns.append(AmountColumn(
                    key: "t\(table.tableIndex)_c\(column)",
                    tableIndex: table.tableIndex,
                    column: column,
                    header: header,
                    caption: table.precedingCaption,
                    unit: table.unitCaption
                ))
            }
        }
        return columns
    }

    /// 選んだ列のセルから行を組む。Jev は呼ばない。
    /// `applyParallelDimension` は収益認識の並行次元（製品 vs 顧客/時点）用。geography は
    /// 売上高と固定資産が同じ合計で並ぶ表を wipe してしまうので切る。
    static func buildRows(
        table: ParsedTable, column: Int, applyParallelDimension: Bool = true
    ) -> (rows: [BuiltRow], needsReview: Bool) {
        var table = table
        var needsReview = false
        if applyParallelDimension, applyBusinessDimension(&table, column: column) {
            needsReview = true
        }
        let amounts = dataAmounts(table: table, column: column)
        var built: [BuiltRow] = []

        let itemsByGroup = Dictionary(grouping: table.items, by: \.group)
        let orderedGroups = uniqueGroups(in: table)
        if orderedGroups.isEmpty {
            for item in table.items {
                let amount = amounts[item.row] ?? 0
                built.append(BuiltRow(
                    categoryGroup: item.label, category: nil, amount: amount,
                    isPartial: item.isPartial, rowKind: "segment"))
            }
        } else {
            for group in orderedGroups {
                let items = itemsByGroup[group] ?? []
                let headerRow = table.groups.first { $0.group == group }?.row
                let groupAmount = headerRow.flatMap { amounts[$0] }
                let partialItems = items.filter(\.isPartial)
                let fullItems = items.filter { !$0.isPartial }
                let pattern = classifyPattern(
                    groupAmount: groupAmount, fullItems: fullItems, partialItems: partialItems)

                switch pattern {
                case .groupOnly:
                    if let groupAmount {
                        built.append(BuiltRow(
                            categoryGroup: group, category: nil, amount: groupAmount,
                            isPartial: false, rowKind: "segment"))
                    }
                case .groupPlusPartial:
                    let childSum = partialItems.reduce(0.0) { $0 + (amounts[$1.row] ?? 0) }
                    if let groupAmount,
                       sumMatches(childSum, subtotal: groupAmount, itemCount: partialItems.count)
                    {
                        for item in partialItems {
                            built.append(BuiltRow(
                                categoryGroup: group, category: item.label,
                                amount: amounts[item.row] ?? 0, isPartial: false, rowKind: "segment"))
                        }
                    } else if let groupAmount {
                        built.append(BuiltRow(
                            categoryGroup: group, category: nil, amount: groupAmount,
                            isPartial: false, rowKind: "segment"))
                    }
                case .groupPlusExhaustive:
                    if let groupAmount {
                        let itemSum = fullItems.reduce(0.0) { $0 + (amounts[$1.row] ?? 0) }
                        if !sumMatches(itemSum, subtotal: groupAmount, itemCount: fullItems.count) {
                            needsReview = true
                        }
                    }
                    if fullItems.isEmpty, let groupAmount {
                        built.append(BuiltRow(
                            categoryGroup: group, category: nil, amount: groupAmount,
                            isPartial: false, rowKind: "segment"))
                    } else {
                        for item in fullItems {
                            built.append(BuiltRow(
                                categoryGroup: group, category: item.label,
                                amount: amounts[item.row] ?? 0, isPartial: false, rowKind: "segment"))
                        }
                    }
                    for item in partialItems {
                        built.append(BuiltRow(
                            categoryGroup: group, category: item.label,
                            amount: amounts[item.row] ?? 0, isPartial: true, rowKind: "segment"))
                    }
                case .shortSumWithoutUchi:
                    needsReview = true
                    if let groupAmount {
                        built.append(BuiltRow(
                            categoryGroup: group, category: nil, amount: groupAmount,
                            isPartial: false, rowKind: "segment"))
                    }
                    for item in fullItems {
                        built.append(BuiltRow(
                            categoryGroup: group, category: item.label,
                            amount: amounts[item.row] ?? 0, isPartial: false, rowKind: "segment"))
                    }
                }
            }
            for item in table.items where item.group.isEmpty && !item.isPartial {
                let amount = amounts[item.row] ?? 0
                built.append(BuiltRow(
                    categoryGroup: item.label, category: nil, amount: amount,
                    isPartial: false, rowKind: "segment"))
            }
        }

        built = mergeWrappedRows(built)
        built = collapseParentChildRows(built)
        return (built, needsReview)
    }

    static func tableTotal(table: ParsedTable, column: Int, preferredLabels: [String] = [
        "外部顧客への売上高", "外部顧客に対する売上高", "外部顧客への収益",
        "顧客との契約から生じる収益", "顧客との契約から認識した収益",
        "外部収益合計",
    ]) -> (label: String, amount: Double)? {
        let amounts = dataAmounts(table: table, column: column)
        for marker in preferredLabels {
            if let total = table.totals.first(where: {
                $0.label == marker || $0.label.hasPrefix(marker)
            }), let amount = amounts[total.row]
            {
                return (total.label, amount)
            }
        }
        if let last = table.totals.last, let amount = amounts[last.row] {
            return (last.label, amount)
        }
        return nil
    }

    /// 行が指標・列が事業のマトリクス（三菱商事 / ファナック）。明細行が無いときだけ、
    /// 選んだ全社列で表を特定し、合計行の他列を category_group にする。
    /// geography の仕向地表も同じ形（行=外部顧客への売上高、列=地域）。固定資産行は選ばない。
    /// 7734 型の「Ⅰ売上高」や 1887 型の前期/当期行も、geography では指標行として読む。
    static func transposeMetricRow(
        table: ParsedTable, wholeCompanyColumn: Int, geographySales: Bool = false
    ) -> (rows: [BuiltRow], wholeCompanyAmount: Double?) {
        if !table.items.isEmpty, !geographySales { return ([], nil) }
        if !table.items.isEmpty, geographySales,
           !itemsLookLikeMetrics(table.items), !itemsLookLikePeriodRows(table.items)
        {
            return ([], nil)
        }
        let metricRowIndex: Int?
        if geographySales {
            metricRowIndex = geographySalesMetricRowIndex(table)
        } else {
            let preferred = [
                "顧客との契約から生じる収益", "顧客との契約から認識した収益",
                "外部顧客への売上高", "外部顧客に対する売上高", "外部顧客への収益", "外部収益合計",
                "売上高", "売上収益",
            ]
            let total = preferred.compactMap { marker in
                table.totals.first {
                    let label = compactCell($0.label)
                    return label == marker || label.hasPrefix(marker)
                }
            }.first ?? table.totals.first { total in
                let label = compactCell(total.label)
                return !isAssetMetricLabel(label) && !label.contains("単位")
                    && !label.hasPrefix("Ⅰ")
            }
            metricRowIndex = total?.row
        }
        guard let metricRowIndex, metricRowIndex < table.grid.count else { return ([], nil) }
        let row = table.grid[metricRowIndex]
        let wholeCompanyAmount = consolidatedWholeCompanyAmount(
            table: table, row: row, selectedColumn: wholeCompanyColumn)
        var built: [BuiltRow] = []
        var headers = table.columnHeaders
        if geographySales, headers[0] == nil, table.headerRowCount > 0 {
            let parts = table.grid.prefix(table.headerRowCount).compactMap { headerRow -> String? in
                guard !headerRow.isEmpty else { return nil }
                let text = compactCell(headerRow[0])
                return text.isEmpty ? nil : text
            }
            let joined = joinHeaderParts(parts)
            if !joined.isEmpty { headers[0] = joined }
        }
        for (column, header) in headers.sorted(by: { $0.key < $1.key }) {
            if column == wholeCompanyColumn { continue }
            if isAggregateColumnHeader(header) { continue }
            if isOfWhichColumnHeader(header) { continue }
            if isPeriodHeadingLabel(header) { continue }
            guard column < row.count, let amount = parseAmount(row[column]) else { continue }
            let name = compactCell(header)
            guard !name.isEmpty else { continue }
            built.append(BuiltRow(
                categoryGroup: name, category: nil, amount: amount,
                isPartial: false, rowKind: "segment"))
        }
        return (built, wholeCompanyAmount)
    }

    static func unlabeledMetricRowIndex(_ table: ParsedTable) -> Int? {
        unlabeledMetricRowIndex(table, geographySales: false)
    }

    static func unlabeledMetricRowIndex(
        _ table: ParsedTable, geographySales: Bool
    ) -> Int? {
        let data = table.grid.enumerated().dropFirst(table.headerRowCount)
        let hits = data.compactMap { index, row -> (Int, Int, Bool)? in
            let label = compactCell(row.first ?? "")
            if geographySales, isPercentMetricLabel(label) { return nil }
            let amounts = row.enumerated().filter { column, cell in
                (geographySales || column > 0) && isAmountCell(cell)
            }
            guard amounts.count >= 2 else { return nil }
            let current = isCurrentPeriodHeading(label)
            return (index, amounts.count, current)
        }
        if geographySales, let current = hits.first(where: { $0.2 }) {
            return current.0
        }
        if geographySales {
            let unlabeled = hits.filter { index, _, _ in
                compactCell(table.grid[index].first ?? "").isEmpty
            }
            if let last = unlabeled.last { return last.0 }
        }
        guard hits.count == 1 else { return hits.max(by: { $0.1 < $1.1 })?.0 }
        return hits[0].0
    }

    /// 7734 の「Ⅰ売上高（千円）」や Canon の「売上高」、1887 の当期行。
    /// 金額の無い親見出し（7211 の「売上高」）は飛ばし、外部顧客合計や 計 を優先する。
    static func geographySalesMetricRowIndex(_ table: ParsedTable) -> Int? {
        let labeled = table.totals.map { ($0.row, $0.label) }
            + table.items.map { ($0.row, $0.label) }
        let withAmounts = labeled.filter { rowHasAmountCells(table, row: $0.0) }
        let preferredMarkers = [
            "外部顧客に対する売上高", "外部顧客への売上高", "外部顧客への収益",
            "顧客との契約から生じる収益", "顧客との契約から認識した収益",
            "営業収益", "売上収益", "売上高", "収益",
        ]
        for marker in preferredMarkers {
            if let hit = withAmounts.first(where: {
                let compact = collapsedCell($0.1)
                return compact.contains(marker)
                    && !compact.contains("その他")
                    && !compact.contains("税引前")
                    && isGeographySalesMetricLabel($0.1)
            }) {
                return hit.0
            }
        }
        if let total = withAmounts.first(where: { isTotalLabel($0.1) }) {
            return total.0
        }
        if let hit = withAmounts.first(where: { isGeographySalesMetricLabel($0.1) }) {
            return hit.0
        }
        let current = table.items.filter {
            isCurrentPeriodHeading($0.label) && rowHasAmountCells(table, row: $0.row)
        }
        if let row = current.last { return row.row }
        return unlabeledMetricRowIndex(table, geographySales: true)
    }

    static func rowHasAmountCells(_ table: ParsedTable, row: Int) -> Bool {
        guard row >= 0, row < table.grid.count else { return false }
        let amounts = table.grid[row].enumerated().filter { column, cell in
            column > 0 && isAmountCell(cell) && parseAmount(cell) != 0
        }
        return amounts.count >= 2
    }

    /// 空白を潰した照合用。`日 本` / `合 計` を地域・合計判定に使う。
    static func collapsedCell(_ text: String) -> String {
        compactCell(text).replacingOccurrences(of: " ", with: "")
    }

    static func isPercentMetricLabel(_ label: String) -> Bool {
        let compact = compactCell(label)
        return compact.contains("％") || compact.contains("%")
            || compact.contains("割合") || compact.contains("構成比")
    }

    static func isGeographySalesMetricLabel(_ label: String) -> Bool {
        if isPercentMetricLabel(label) { return false }
        if isAssetMetricLabel(label) { return false }
        let stripped = stripSectionMarker(compactCell(label))
        if stripped.contains("単位") && !stripped.contains("売上") { return false }
        return stripped.contains("売上") || stripped.contains("収益")
            || stripped.contains("外部顧客")
    }

    static func stripSectionMarker(_ label: String) -> String {
        var token = compactCell(label)
        let prefixes = ["Ⅰ", "Ⅱ", "III", "I．", "I.", "II．", "II.", "(1)", "（1）", "1.", "１."]
        for prefix in prefixes where token.hasPrefix(prefix) {
            token = String(token.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return token
    }

    static func itemsLookLikePeriodRows(_ items: [Item]) -> Bool {
        guard !items.isEmpty else { return false }
        return items.allSatisfy { isPeriodHeadingLabel($0.label) }
    }

    static func isCurrentPeriodHeading(_ label: String) -> Bool {
        let compact = compactCell(label)
        guard isPeriodHeadingLabel(compact) else { return false }
        return compact.contains("当") && !compact.contains("前")
    }

    static func isAssetMetricLabel(_ label: String) -> Bool {
        let compact = compactCell(label)
        return compact.contains("固定資産") || compact.contains("非流動資産")
            || compact.contains("長期性資産") || compact.contains("有形固定資産")
            || compact == "セグメント資産" || compact.contains("非流動資産合計")
    }

    static func itemsLookLikeMetrics(_ items: [Item]) -> Bool {
        let labels = items.map { compactCell($0.label) }
        guard !labels.isEmpty else { return true }
        let metric = labels.filter { label in
            label.contains("売上") || label.contains("収益") || isAssetMetricLabel(label)
                || label.contains("利益") || label.contains("損失") || label.contains("単位")
                || label.hasPrefix("Ⅰ") || label.hasPrefix("I．") || label.hasPrefix("I.")
        }
        return metric.count * 2 >= labels.count
    }

    static func isAggregateColumnHeader(_ header: String) -> Bool {
        let compact = collapsedCell(header)
        return compact.contains("合計") || compact.contains("連結") || compact.contains("調整")
            || compact.contains("消去") || compact.hasSuffix("計")
    }

    static func isOfWhichColumnHeader(_ header: String) -> Bool {
        let compact = collapsedCell(header)
        return compact.contains("うち") || compact.contains("内、") || compact.hasPrefix("内,")
    }

    static func displayLabel(categoryGroup: String, category: String?) -> String {
        BreakdownRowPayload.displayLabel(categoryGroup: categoryGroup, category: category)
    }

    static func stripNoteMarker(_ label: String) -> String {
        let compact = compactCell(label)
        let pattern = try! NSRegularExpression(
            pattern: #"[（(]注(?:[）)]?\s*)?[0-9０-９]*[）)]?$"#)
        let ns = compact as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = pattern.firstMatch(in: compact, options: [], range: range) else {
            return compact
        }
        return ns.substring(to: match.range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 列見出しの「業界の名称」など軸タイトル。カテゴリ本体だけ残す。
    static func isStubAxisHeader(_ label: String) -> Bool {
        let token = compactCell(label)
        if token.isEmpty { return false }
        if token.hasSuffix("の名称") || token == "名称" { return true }
        if token == "報告セグメント" || token.hasPrefix("報告セグメント") { return true }
        if token == "主な地域市場" || token.hasPrefix("主な地域") { return true }
        return false
    }

    static func joinHeaderParts(_ parts: [String]) -> String {
        let compact = parts.map(compactCell).filter { !$0.isEmpty }
        let withoutUnit = compact.filter { !isUnitCaptionHeader($0) }
        let withoutStub = withoutUnit.filter { !isStubAxisHeader($0) }
        var source = withoutStub.isEmpty ? withoutUnit : withoutStub
        source = collapseConsecutiveDuplicates(source)
        if let nested = nestedGeographyLeafLabel(source) {
            return nested
        }
        let leaves = source.filter { !isSpanningParentHeader($0) }
        if !leaves.isEmpty {
            source = collapseConsecutiveDuplicates(leaves)
        }
        return source.joined(separator: " / ")
    }

    /// 入れ子の地域見出し。海外売上高/アジアは葉のアジア、アジア/タイはアジアタイ。
    /// 「その他」だけ親とつなげる（その他の地域その他）。事業名の葉があるときは使わない。
    static func nestedGeographyLeafLabel(_ parts: [String]) -> String? {
        guard parts.count >= 2, parts.allSatisfy(isGeographyRelatedHeader) else { return nil }
        let parent = compactCell(parts[parts.count - 2])
        let child = compactCell(parts[parts.count - 1])
        if isPeriodHeadingLabel(parent) { return child }
        if isGeographySalesMetricLabel(parent) { return child }
        if isAggregateColumnHeader(child) { return child }
        if isCoarseGeographyGroupHeader(parent)
            || parent.contains("その他の地域") || parent.hasSuffix("の地域")
        {
            if isOtherResidualChild(child) { return parent + child }
            return child
        }
        if isOtherResidualChild(child) { return parent + child }
        return parent + child
    }

    static func isGeographyRelatedHeader(_ label: String) -> Bool {
        let token = compactCell(label)
        if token.isEmpty { return false }
        if isPeriodHeadingLabel(token) || isAggregateColumnHeader(token) { return true }
        if isGeographySalesMetricLabel(token) { return true }
        if isCoarseGeographyGroupHeader(token) { return true }
        if token.contains("その他") { return true }
        return RevenueRecognitionTableStructure.isBareGeographyLabel(token)
            || RevenueRecognitionTableStructure.isGeographyHeading(token)
            || token.contains("海外")
    }

    static func isOtherResidualChild(_ label: String) -> Bool {
        let token = compactCell(label)
        return token == "その他" || token == "その他地域"
    }

    static func isCoarseGeographyGroupHeader(_ label: String) -> Bool {
        let token = compactCell(label)
        if token == "海外" || token == "国内" || token == "国外" || token == "本邦" {
            return true
        }
        if token.contains("海外売上") || token == "連結売上高" { return true }
        let stripped = stripSalesMetricSuffix(token)
        return stripped == "海外" || stripped == "国内" || stripped == "国外" || stripped == "本邦"
    }

    static func stripSalesMetricSuffix(_ label: String) -> String {
        var token = compactCell(label)
        for suffix in ["売上高", "売上収益", "収益", "売上"] where token.hasSuffix(suffix) {
            token = String(token.dropLast(suffix.count))
            break
        }
        return token
    }

    /// 「その他 / その他」のように同一セルがヘッダー行で繰り返された結合を畳む。
    static func collapseConsecutiveDuplicates(_ parts: [String]) -> [String] {
        var out: [String] = []
        for part in parts {
            if out.last != part { out.append(part) }
        }
        return out
    }

    /// 全列に載る「○○（連結）」や年度見出し、地域グループ。葉の事業名と同居するときだけ落とす。
    static func isSpanningParentHeader(_ label: String) -> Bool {
        if isPeriodHeadingLabel(label) { return true }
        if isGeographySalesMetricLabel(label) { return true }
        if label.contains("その他") { return false }
        if isAggregateColumnHeader(label) { return true }
        if isCoarseGeographyGroupHeader(label) { return true }
        let stripped = stripSalesMetricSuffix(compactCell(label))
        if stripped != compactCell(label),
           RevenueRecognitionTableStructure.isBareGeographyLabel(stripped)
        {
            return true
        }
        return RevenueRecognitionTableStructure.isBareGeographyLabel(label)
            || RevenueRecognitionTableStructure.isGeographyHeading(label)
    }

    /// 列見出しに載った「（単位：百万円）」はカテゴリ名ではない（6140）。
    /// `日本（百万円）` は単位付き地域名なので残す（8031 / 8572）。
    static func isUnitCaptionHeader(_ label: String) -> Bool {
        let token = compactCell(label)
        if token.isEmpty { return false }
        if BreakdownExtractor.parseUnitCaption(token) == nil, !token.contains("単位") {
            return false
        }
        return unitCaptionRemainder(token).isEmpty
    }

    static func unitCaptionRemainder(_ label: String) -> String {
        var token = collapsedCell(label)
            .replacingOccurrences(of: "単位", with: "")
            .replacingOccurrences(of: "：", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "（", with: "")
            .replacingOccurrences(of: "）", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        for unit in ["百万ユーロ", "百万米ドル", "千米ドル", "千ユーロ", "十億円", "百万円", "千円", "億円"] {
            token = token.replacingOccurrences(of: unit, with: "")
        }
        return token
    }

    /// 先頭から連続する非金額セル。Denso / 7416 のラベル域（空 rowspan + 内側ラベル）。
    static func leadingLabelCells(_ row: [String]) -> [String] {
        var cells: [String] = []
        for cell in row {
            let text = compactCell(cell)
            if isAmountCell(text) { break }
            cells.append(text)
        }
        return cells
    }

    /// colspan で同じ文言が複製されたセルは1つにする。空の外側セルは落とす。
    static func distinctLabelParts(_ cells: [String]) -> [String] {
        var parts: [String] = []
        for cell in cells {
            if cell.isEmpty { continue }
            if parts.last == cell { continue }
            parts.append(cell)
        }
        return parts
    }

    /// ラベル域の内側（カテゴリ）。外側 rowspan 見出しは `distinctLabelParts` の先頭。
    static func rowLabel(_ row: [String]) -> String {
        distinctLabelParts(leadingLabelCells(row)).last ?? compactCell(row.first ?? "")
    }

    static func isAmountCell(_ raw: String) -> Bool {
        let text = compactCell(raw)
        if dashCells.contains(text) { return true }
        return XBRLUtils.parseHtmlNumber(text) != nil
    }

    static func parseAmount(_ raw: String) -> Double? {
        let text = compactCell(raw)
        if dashCells.contains(text) { return 0 }
        return XBRLUtils.parseHtmlNumber(text)
    }

    /// |sum - subtotal| <= 項目数 × 表の 1 単位。パターン3でグループに小計があるときだけ。
    static func sumMatches(_ sum: Double, subtotal: Double, itemCount: Int) -> Bool {
        abs(sum - subtotal) <= Double(max(itemCount, 1))
    }

    static func compactCell(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - parse one table

    /// 期間・単位の列見出しの直後。ラベルだけの次元見出し（地理的区分）はデータ扱い。
    static func dataStartRow(_ rows: [[String]]) -> Int {
        var firstData = 0
        while firstData < rows.count {
            let row = rows[firstData]
            let amounts = row.dropFirst().contains { isAmountCell($0) }
            let labelOnly = !compactCell(row.first ?? "").isEmpty
                && row.dropFirst().allSatisfy { compactCell($0).isEmpty }
            if amounts || labelOnly { break }
            firstData += 1
        }
        return firstData
    }

    private static func parseTable(
        index: Int, grid: [[String]], table: BreakdownTable
    ) -> ParsedTable {
        let ncol = grid.map(\.count).max() ?? 0
        let rows = grid.map { $0 + Array(repeating: "", count: max(0, ncol - $0.count)) }
        let structure = RevenueRecognitionTableStructure.inspect(grid: rows)
        let firstData = structure.headerRowCount
        var headers: [Int: String] = [:]
        for column in 1..<ncol {
            let parts = rows.prefix(firstData).compactMap { row -> String? in
                let text = compactCell(row[column])
                return text.isEmpty ? nil : text
            }
            headers[column] = joinHeaderParts(parts)
        }

        var items: [Item] = []
        var totals: [Total] = []
        var groups: [GroupHeader] = []
        var group = ""
        var lastClosedRow = firstData - 1
        for classified in structure.rows {
            let i = classified.index
            if classified.amountKind == .subtotal {
                let label = classified.category ?? classified.categoryGroup ?? ""
                if isTotalLabel(label) {
                    totals.append(Total(label: label, row: i))
                } else if isGroupSubtotalLabel(label) {
                    attachGroupSubtotal(
                        stem: groupNameFromSubtotal(label), subtotalRow: i,
                        items: &items, groups: &groups, lastClosedRow: lastClosedRow)
                    group = ""
                    lastClosedRow = i
                }
                continue
            }
            if classified.labelKind == .categoryGroup, classified.amountKind == nil {
                group = classified.categoryGroup ?? ""
                groups.append(GroupHeader(group: group, row: i))
                continue
            }
            guard classified.amountKind == .segment else { continue }
            let label = classified.category ?? classified.categoryGroup ?? ""
            if label.isEmpty { continue }
            if isAmountCell(label) { continue }
            if classified.labelKind == .categoryGroup, classified.category == nil {
                items.append(Item(group: "", label: label, row: i, isPartial: false))
                continue
            }
            let assigned = classified.categoryGroup ?? group
            let partial = isPartialItem(label)
            if partial {
                var parentGroup = assigned
                if parentGroup.isEmpty, let parent = items.last {
                    if parent.isPartial {
                        parentGroup = parent.group
                    } else {
                        parentGroup = parent.label
                        if !groups.contains(where: { $0.group == parent.label }) {
                            groups.append(GroupHeader(group: parent.label, row: parent.row))
                        }
                        items.removeLast()
                    }
                }
                items.append(Item(
                    group: parentGroup, label: label, row: i, isPartial: true))
                continue
            }
            items.append(Item(
                group: assigned, label: label, row: i, isPartial: false))
        }
        return ParsedTable(
            tableIndex: index, grid: rows, headerRowCount: firstData, columnHeaders: headers,
            precedingCaption: table.precedingCaption, unitCaption: table.unitCaption,
            period: table.period, heading: table.heading,
            items: items, totals: totals, groups: groups, structure: structure)
    }

    /// 同一全社合計で閉じる並行次元は加算しない。事業軸は製品・サービスブロックだけ残す。
    static func applyBusinessDimension(_ table: inout ParsedTable, column: Int) -> Bool {
        let amounts = dataAmounts(table: table, column: column)
        let whole = tableTotal(table: table, column: column)?.amount
            ?? table.totals.compactMap { amounts[$0.row] }.last
        let parallel = RevenueRecognitionTableStructure.parallelDimensionBlocks(
            in: table.structure, grid: table.grid, column: column, tableTotal: whole)
        guard parallel.count >= 2 else { return false }
        guard let chosen = RevenueRecognitionTableStructure.businessBlock(
            in: parallel, rows: table.structure.rows)
        else {
            table.items = []
            table.groups = []
            return true
        }
        let keep = Set(chosen.itemRows)
        table.items = table.items.filter { keep.contains($0.row) }.map { item in
            var copy = item
            copy.group = ""
            return copy
        }
        table.groups = []
        return false
    }

    static func parallelDimensionsUnresolved(table: ParsedTable, column: Int) -> Bool {
        let amounts = dataAmounts(table: table, column: column)
        let whole = tableTotal(table: table, column: column)?.amount
            ?? table.totals.compactMap { amounts[$0.row] }.last
        let parallel = RevenueRecognitionTableStructure.parallelDimensionBlocks(
            in: table.structure, grid: table.grid, column: column, tableTotal: whole)
        return parallel.count >= 2
            && RevenueRecognitionTableStructure.businessBlock(
                in: parallel, rows: table.structure.rows) == nil
    }

    /// 期間見出しか。`自` 接頭辞だけでは期間にしない（自社メディア広告）。
    static func isPeriodHeadingLabel(_ label: String) -> Bool {
        let compact = compactCell(label)
        if compact.hasPrefix("自") && !compact.contains("当") && !compact.contains("前")
            && !compact.contains("至")
        {
            return false
        }
        if compact.contains("当連結会計年度") || compact.contains("前連結会計年度")
            || compact.contains("当事業年度") || compact.contains("前事業年度")
        {
            return true
        }
        if compact.contains("終了した事業年度") || compact.contains("終了した連結会計年度") {
            return true
        }
        if compact.range(of: #"^第[0-9]+期$"#, options: .regularExpression) != nil {
            return true
        }
        return BreakdownExtractor.parsePeriodCue(compact) != nil
            && (compact.contains("連結") || compact.contains("事業年度") || compact.contains("年度"))
    }

    static func isPartialItem(_ label: String) -> Bool {
        let compact = compactCell(label)
        if compact.contains("うち") { return true }
        return isFullyParenthesized(compact) && !isTotalLabel(compact)
    }

    static func isFullyParenthesized(_ label: String) -> Bool {
        let compact = compactCell(label)
        guard compact.count > 2 else { return false }
        return (compact.hasPrefix("（") && compact.hasSuffix("）"))
            || (compact.hasPrefix("(") && compact.hasSuffix(")"))
    }

    /// 表全体の合計行。`自動車分野計` のようなグループ小計は含めない。
    /// `その他の収益` / `その他収益` は完全一致だけ（調整末尾。2467 S100YMA4 の製品行は `その他`）。
    /// 裸の `計` はブロック／表のクローザー（4825 / 6287）。
    static func isTotalLabel(_ label: String) -> Bool {
        let token = totalToken(label)
        if token == "合計" || token == "売上高合計" || token == "連結合計"
            || token == "連結計" || token == "連結金額" || token == "売上高" || token == "小計"
            || token == "計" || token == "海外合計" || token == "海外計" || token == "連結売上高"
            || token == "連結売上"
        {
            return true
        }
        return totalMarkers.contains { marker in
            let markerToken = marker.replacingOccurrences(of: " ", with: "")
            if markerToken.hasPrefix("その他") {
                return token == markerToken
            }
            return token == markerToken || token.hasPrefix(markerToken)
        }
    }

    /// `{group}計` / `{group}合計`。表全体の合計行ではないグループ小計。
    static func isGroupSubtotalLabel(_ label: String) -> Bool {
        if isTotalLabel(label) { return false }
        let token = totalToken(label)
        if token.hasSuffix("合計") && token.count > 2 { return true }
        return token.hasSuffix("計") && token.count > 1
    }

    static func groupNameFromSubtotal(_ label: String) -> String {
        let token = totalToken(label)
        if token.hasSuffix("合計") { return String(token.dropLast(2)) }
        if token.hasSuffix("計") { return String(token.dropLast()) }
        return token
    }

    private static func unwrapParentheses(_ label: String) -> String {
        guard isFullyParenthesized(label) else { return label }
        return String(label.dropFirst().dropLast())
    }

    private static func totalToken(_ label: String) -> String {
        let collapsed = label.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
        return unwrapParentheses(collapsed)
    }

    /// `自動車分野計` の直前までをそのグループのカテゴリにする。見出し行があれば
    /// 小計行の金額を groupAmount に使う。小計自体は row に出さない。
    private static func attachGroupSubtotal(
        stem: String, subtotalRow: Int,
        items: inout [Item], groups: inout [GroupHeader], lastClosedRow: Int
    ) {
        guard !stem.isEmpty else { return }
        let headerRow = groups.last(where: { $0.group == stem })?.row
        let bound = headerRow ?? lastClosedRow
        for index in items.indices where items[index].group.isEmpty && items[index].row > bound {
            items[index].group = stem
        }
        if let existing = groups.firstIndex(where: { $0.group == stem }) {
            groups[existing].row = subtotalRow
        } else {
            groups.append(GroupHeader(group: stem, row: subtotalRow))
        }
    }

    /// 横結合表の `合計` 列は報告セグメント小計（三菱商事 13,939,592）。分母は `連結金額`。
    static func consolidatedWholeCompanyAmount(
        table: ParsedTable, row: [String], selectedColumn: Int
    ) -> Double? {
        let preferred = ["連結金額", "連結合計", "連結計"]
        let headers = table.columnHeaders.sorted(by: { $0.key < $1.key })
        for marker in preferred {
            if let column = headers.first(where: {
                let compact = compactCell($0.value)
                return compact == marker || compact.contains(marker)
            }), column.key < row.count, let amount = parseAmount(row[column.key]), amount != 0
            {
                return amount
            }
        }
        return selectedColumn < row.count ? parseAmount(row[selectedColumn]) : nil
    }

    /// 改行で割れた同一金額のラベルを1行に戻す（1807 S100YJEE）。
    static func mergeWrappedRows(_ rows: [BuiltRow]) -> [BuiltRow] {
        guard rows.count >= 2 else { return rows }
        var merged: [BuiltRow] = []
        for row in rows {
            guard let last = merged.last,
                  !last.isPartial, !row.isPartial,
                  last.amount == row.amount, last.amount != 0,
                  last.rowKind == row.rowKind
            else {
                merged.append(row)
                continue
            }
            var combined = last
            if last.category == nil && row.category == nil {
                combined.categoryGroup = last.categoryGroup + row.categoryGroup
            } else {
                let left = last.category ?? last.categoryGroup
                let right = row.category ?? row.categoryGroup
                combined.category = left + right
            }
            merged[merged.count - 1] = combined
        }
        return merged
    }

    /// 金額行の直後に、その金額へ合計する行が続くとき親子。一致すれば子だけ残す（4519 S100XTBJ）。
    static func collapseParentChildRows(_ rows: [BuiltRow]) -> [BuiltRow] {
        guard rows.count >= 2 else { return rows }
        var result: [BuiltRow] = []
        var index = 0
        while index < rows.count {
            let parent = rows[index]
            if parent.isPartial {
                result.append(parent)
                index += 1
                continue
            }
            var sum = 0.0
            var childCount = 0
            var childEnd: Int?
            for follower in (index + 1)..<rows.count {
                if rows[follower].isPartial { break }
                sum += rows[follower].amount
                childCount += 1
                if childCount >= 2,
                   sumMatches(sum, subtotal: parent.amount, itemCount: childCount)
                {
                    childEnd = follower
                    break
                }
                if abs(sum) > abs(parent.amount) + Double(childCount) { break }
            }
            if let childEnd {
                result.append(contentsOf: rows[(index + 1)...childEnd])
                index = childEnd + 1
            } else {
                result.append(parent)
                index += 1
            }
        }
        return result
    }

    /// 明細（うちを除く）の合計が、表のどの合計行とも合わないとき。
    /// 顧客との契約から生じる収益 と 外部顧客への売上高 が違う（その他の収益がある）表では、
    /// どちらかに合えば足りる。合計が分母（または表の最大合計）を超えたときも不一致（4519）。
    static func tableSumMismatch(
        rows: [BuiltRow], table: ParsedTable, column: Int, cap: Double? = nil
    ) -> Bool {
        let full = rows.filter { !$0.isPartial }
        guard !full.isEmpty else { return false }
        let amounts = dataAmounts(table: table, column: column)
        let totalAmounts = table.totals.compactMap { amounts[$0.row] }
        let sum = full.reduce(0.0) { $0 + $1.amount }
        let ceilings = totalAmounts + [cap].compactMap { $0 }
        if let ceiling = ceilings.max(),
           sum > ceiling,
           !sumMatches(sum, subtotal: ceiling, itemCount: full.count)
        {
            return true
        }
        guard !totalAmounts.isEmpty else { return false }
        return !totalAmounts.contains { sumMatches(sum, subtotal: $0, itemCount: full.count) }
    }

    static func emittedSumExceedsCap(_ rows: [BuiltRow], cap: Double) -> Bool {
        let full = rows.filter { !$0.isPartial }
        guard !full.isEmpty else { return false }
        let sum = full.reduce(0.0) { $0 + $1.amount }
        return sum > cap && !sumMatches(sum, subtotal: cap, itemCount: full.count)
    }

    static func isContractBalanceTable(_ grid: [[String]]) -> Bool {
        let flat = grid.flatMap { $0 }.joined()
        if balanceMarkers.contains(where: { flat.contains($0) }) { return true }
        let bucketHits = remainingPerformanceBuckets.filter { flat.contains($0) }
        return Set(bucketHits).count >= 2
    }

    private static func hasAmountColumn(_ grid: [[String]]) -> Bool {
        grid.contains { row in
            row.dropFirst().contains { isAmountCell($0) && !dashCells.contains(compactCell($0)) }
        }
    }

    static func dataAmounts(table: ParsedTable, column: Int) -> [Int: Double] {
        var amounts: [Int: Double] = [:]
        for (index, row) in table.grid.enumerated() where index >= table.headerRowCount {
            guard column < row.count, let value = parseAmount(row[column]) else { continue }
            amounts[index] = value
        }
        return amounts
    }

    private static func uniqueGroups(in table: ParsedTable) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for header in table.groups where seen.insert(header.group).inserted {
            ordered.append(header.group)
        }
        for item in table.items where !item.group.isEmpty && seen.insert(item.group).inserted {
            ordered.append(item.group)
        }
        return ordered
    }

    private enum GroupPattern {
        case groupOnly
        case groupPlusPartial
        case groupPlusExhaustive
        case shortSumWithoutUchi
    }

    private static func classifyPattern(
        groupAmount: Double?, fullItems: [Item], partialItems: [Item]
    ) -> GroupPattern {
        if !partialItems.isEmpty && fullItems.isEmpty {
            return .groupPlusPartial
        }
        if !partialItems.isEmpty {
            return .groupPlusExhaustive
        }
        if fullItems.isEmpty {
            return .groupOnly
        }
        return .groupPlusExhaustive
    }
}
