// 収益認識注記の html_table から、決定論で 2 段候補（category_group / category）を組む。
// Jev は当期の全社金額列だけを選び、行ラベルと金額はここが読む。
// docs/breakdown.md

import Foundation

enum RevenueRecognitionCandidates {
    static let totalMarkers = [
        "顧客との契約から生じる収益",
        "顧客との契約から認識した収益",
        "その他の収益",
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
        var items: [Item]
        var totals: [Total]
        var groups: [GroupHeader]
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
    static func buildRows(table: ParsedTable, column: Int) -> (rows: [BuiltRow], needsReview: Bool) {
        let amounts = dataAmounts(table: table, column: column)
        var built: [BuiltRow] = []
        var needsReview = false

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
                    if let groupAmount {
                        built.append(BuiltRow(
                            categoryGroup: group, category: nil, amount: groupAmount,
                            isPartial: false, rowKind: "segment"))
                    }
                    for item in partialItems {
                        built.append(BuiltRow(
                            categoryGroup: group, category: item.label,
                            amount: amounts[item.row] ?? 0, isPartial: true, rowKind: "segment"))
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
    static func transposeMetricRow(
        table: ParsedTable, wholeCompanyColumn: Int
    ) -> (rows: [BuiltRow], wholeCompanyAmount: Double?) {
        guard table.items.isEmpty else { return ([], nil) }
        let preferred = [
            "顧客との契約から生じる収益", "顧客との契約から認識した収益",
            "外部顧客への売上高", "外部顧客に対する売上高", "外部顧客への収益", "外部収益合計",
        ]
        let total = preferred.compactMap { marker in
            table.totals.first { $0.label == marker || $0.label.hasPrefix(marker) }
        }.first ?? table.totals.first
        guard let total, total.row < table.grid.count else { return ([], nil) }
        let row = table.grid[total.row]
        let wholeCompanyAmount = consolidatedWholeCompanyAmount(
            table: table, row: row, selectedColumn: wholeCompanyColumn)
        var built: [BuiltRow] = []
        for (column, header) in table.columnHeaders.sorted(by: { $0.key < $1.key }) {
            if column == wholeCompanyColumn { continue }
            if isAggregateColumnHeader(header) { continue }
            guard column < row.count, let amount = parseAmount(row[column]) else { continue }
            let name = compactCell(header)
            guard !name.isEmpty else { continue }
            built.append(BuiltRow(
                categoryGroup: name, category: nil, amount: amount,
                isPartial: false, rowKind: "segment"))
        }
        return (built, wholeCompanyAmount)
    }

    static func isAggregateColumnHeader(_ header: String) -> Bool {
        let compact = compactCell(header)
        return compact.contains("合計") || compact.contains("連結") || compact.contains("調整")
            || compact.contains("消去") || compact.hasSuffix("計")
    }

    static func displayLabel(categoryGroup: String, category: String?) -> String {
        BreakdownRowPayload.displayLabel(categoryGroup: categoryGroup, category: category)
    }

    static func stripNoteMarker(_ label: String) -> String {
        let compact = compactCell(label)
        let pattern = try! NSRegularExpression(
            pattern: #"[（(]注(?:[）)]?\s*)?[0-9０-９]+[）)]?$"#)
        let ns = compact as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = pattern.firstMatch(in: compact, options: [], range: range) else {
            return compact
        }
        return ns.substring(to: match.range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rowLabel(_ row: [String]) -> String {
        for cell in row {
            let text = compactCell(cell)
            if text.isEmpty { continue }
            if isAmountCell(text) { continue }
            return text
        }
        return compactCell(row.first ?? "")
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

    private static func parseTable(
        index: Int, grid: [[String]], table: BreakdownTable
    ) -> ParsedTable {
        let ncol = grid.map(\.count).max() ?? 0
        let rows = grid.map { $0 + Array(repeating: "", count: max(0, ncol - $0.count)) }
        var firstData = 0
        while firstData < rows.count {
            let row = rows[firstData]
            let amounts = row.dropFirst().contains { isAmountCell($0) }
            let labelOnly = !compactCell(row.first ?? "").isEmpty
                && row.dropFirst().allSatisfy { compactCell($0).isEmpty }
            if amounts || labelOnly { break }
            firstData += 1
        }
        var headers: [Int: String] = [:]
        for column in 1..<ncol {
            let parts = rows.prefix(firstData).compactMap { row -> String? in
                let text = compactCell(row[column])
                return text.isEmpty ? nil : text
            }
            headers[column] = parts.joined(separator: " / ")
        }

        var items: [Item] = []
        var totals: [Total] = []
        var groups: [GroupHeader] = []
        var group = ""
        var lastClosedRow = firstData - 1
        for i in firstData..<rows.count {
            let row = rows[i]
            let rawLabel = compactCell(rowLabel(row))
            if rawLabel.isEmpty { continue }
            if isPeriodHeadingLabel(rawLabel) { continue }
            let label = stripNoteMarker(rawLabel)
            if label.isEmpty { continue }
            let hasAmt = row.contains {
                let cell = compactCell($0)
                return cell != rawLabel && isAmountCell(cell)
            }
            if isTotalLabel(label) {
                totals.append(Total(label: label, row: i))
                continue
            }
            if isGroupSubtotalLabel(label) {
                attachGroupSubtotal(
                    stem: groupNameFromSubtotal(label), subtotalRow: i,
                    items: &items, groups: &groups, lastClosedRow: lastClosedRow)
                group = ""
                lastClosedRow = i
                continue
            }
            if !hasAmt {
                group = rawLabel
                groups.append(GroupHeader(group: rawLabel, row: i))
                continue
            }
            let partial = isPartialItem(label)
            if partial {
                var parentGroup = group
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
                group: group, label: label, row: i, isPartial: false))
        }
        return ParsedTable(
            tableIndex: index, grid: rows, headerRowCount: firstData, columnHeaders: headers,
            precedingCaption: table.precedingCaption, unitCaption: table.unitCaption,
            items: items, totals: totals, groups: groups)
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
    /// `その他の収益` は完全一致または接頭辞だけ。`contains` だと「その他」製品行を合計にする。
    static func isTotalLabel(_ label: String) -> Bool {
        let token = totalToken(label)
        if token == "合計" || token == "売上高合計" || token == "連結合計"
            || token == "連結計" || token == "連結金額" || token == "売上高" || token == "小計"
        {
            return true
        }
        return totalMarkers.contains { marker in
            let markerToken = marker.replacingOccurrences(of: " ", with: "")
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

    /// 明細（うちを除く）の合計が、表のどの合計行とも合わないとき。
    /// 顧客との契約から生じる収益 と 外部顧客への売上高 が違う（その他の収益がある）表では、
    /// どちらかに合えば足りる。
    static func tableSumMismatch(
        rows: [BuiltRow], table: ParsedTable, column: Int
    ) -> Bool {
        let full = rows.filter { !$0.isPartial }
        guard !full.isEmpty else { return false }
        let amounts = dataAmounts(table: table, column: column)
        let totalAmounts = table.totals.compactMap { amounts[$0.row] }
        guard !totalAmounts.isEmpty else { return false }
        let sum = full.reduce(0.0) { $0 + $1.amount }
        return !totalAmounts.contains { sumMatches(sum, subtotal: $0, itemCount: full.count) }
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

    private static func dataAmounts(table: ParsedTable, column: Int) -> [Int: Double] {
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
