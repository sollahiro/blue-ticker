// geography（地域別情報）の html_table を、決定論の表構造チェック + Jev の列選択で
// BreakdownSnapshot へ正規化する。Chat Completions は使わない。
// 表構造は収益認識と同じ候補列。Jev は当期の全社（または合計）金額列だけを選ぶ。
// 行・単位・うち内数・脚注はコードが組む。低確信は needs_review（公開面 fail-closed）。
// docs/breakdown.md。BreakdownNormalizer.swift（xbrl_facts 経路）とは別経路。

import Foundation

/// LLM がどの表・どの期間列・どの単位を採用したかの監査情報（目視検証用）。
/// `BreakdownSnapshot` 自体（xbrl_facts 経路と共有する契約型）は汚さず、別チャネルで返す。
/// product_service 軸の正規化器（`RevenueRecognitionColumnNormalizer` 等）と共有する型。
struct LLMBreakdownAudit {
    var sourceTableIndex: Int?
    var periodColumn: String?
    var unit: String
    /// 表がそもそも事業別/製品別の利益情報を含んでいたか。`BreakdownRow.profit == nil` だけでは
    /// 「未開示（確認済み）」と「LLM の見落とし」を区別できないため独立して持つ。
    /// geography 軸（本ファイル）は利益比較の対象外のため常に false。
    var profitDisclosed: Bool
    var notes: String
    /// `applicable=false` のときの理由種別（`geography_only` | `other`）。product_service 軸の
    /// 正規化器（`SegmentInfoLLMNormalizer`）のみが設定する
    /// （issue #135: html_table経由でLLMが地域別のみと判定したケースをE判定として拾うため）。
    /// `applicable=true` のときは無視されるフィールドのため nil のままでよい。
    var notApplicableReason: String? = nil
    /// 収益分解の列選択など、Jev を使ったときの監査。無い経路は nil。
    var jev: SegmentNoteJevAuditPayload? = nil
    /// 収益分解の列選択 Jev。`jev` は後段のセグメント注記判断で上書きされる。
    var columnJev: SegmentNoteJevAuditPayload? = nil
}

enum GeographyBreakdownLLMNormalizer {

    /// 分母整合性チェックの許容範囲。xbrl_facts 経路（0.95...1.05）より広め。
    /// html_table は「注記の仕向地合計」と「損益計算書の売上」が数%ずれることがある
    /// （実データ: キヤノン地域別注記の計 4,509,821 百万円 vs 連結売上 4,624,727 百万円 ≈ 2.5%差）。
    private static let denominatorTolerance = 0.90...1.10

    /// geography の ExtractedBreakdown（html_table）と連結外部売上から BreakdownSnapshot を組み立てる。
    /// 列が選べない・非該当・パース不能の場合は snapshot=nil。
    static func normalize(
        _ result: ExtractedBreakdown,
        consolidatedSales: Double?,
        decider: any RevenueRecognitionColumnDeciding,
        fiscalYearEnd: String?,
        docID: String
    ) async -> (snapshot: BreakdownSnapshot?, audit: LLMBreakdownAudit?) {
        guard !result.tables.isEmpty,
              let consolidatedSales, consolidatedSales != 0 else { return (nil, nil) }

        let parsed = RevenueRecognitionCandidates.parse(tables: result.tables)
        let columns = RevenueRecognitionCandidates.amountColumns(in: parsed)
        guard !columns.isEmpty else { return (nil, nil) }

        let scopedTables = dropAssetTables(
            dropNonGeographyTables(
                SegmentInfoLLMNormalizer.dropPriorEraTables(parsed, among: parsed, fiscalYearEnd: fiscalYearEnd)
            )
        )
        let scopedColumns = columns.filter { column in
            scopedTables.contains { $0.tableIndex == column.tableIndex }
        }
        let tablesForChoice = scopedTables.isEmpty ? parsed : scopedTables
        let columnsForChoice = scopedColumns.isEmpty ? columns : scopedColumns
        let offered = offeredColumns(columnsForChoice, tables: tablesForChoice)
        let offeredTables = tablesForChoice.filter { table in
            offered.contains { $0.tableIndex == table.tableIndex }
        }
        guard !offered.isEmpty else { return (nil, nil) }

        let choice = await decider.chooseColumn(
            columns: offered, tables: offeredTables, fiscalYearEnd: fiscalYearEnd, docID: docID)
        let resolved = RevenueRecognitionColumnNormalizer.resolveSelection(choice, columns: offered)
        let columnJev = jevPayload(
            docID: docID, choice: choice, resolvedKey: resolved?.key ?? choice.selected)
        let pNoneNote = choice.pNone.map { String($0) } ?? "nil"
        var notes =
            "jev_column=\(choice.selected ?? "nil") confidence=\(choice.confidence.map { String($0) } ?? "nil") p_none=\(pNoneNote)"
        if let resolved, resolved.forceReview {
            notes += " overridden=\(resolved.key)"
        }
        var audit = LLMBreakdownAudit(
            sourceTableIndex: nil, periodColumn: resolved?.key ?? choice.selected, unit: "",
            profitDisclosed: false, notes: notes, jev: columnJev, columnJev: columnJev)

        guard let resolved else { return (nil, audit) }
        guard let selectedColumn = columns.first(where: { $0.key == resolved.key }),
              let selectedTable = parsed.first(where: { $0.tableIndex == selectedColumn.tableIndex })
        else { return (nil, audit) }

        let wholeCompanyColumn = preferredWholeCompanyColumn(
            selectedTable, selected: selectedColumn.column)
        let regionCols = regionColumnCount(selectedTable)
        var built: [RevenueRecognitionCandidates.BuiltRow] = []
        var transposedWhole: Double?
        if regionCols >= 2 {
            let transposed = RevenueRecognitionCandidates.transposeMetricRow(
                table: selectedTable, wholeCompanyColumn: wholeCompanyColumn,
                geographySales: true)
            built = dropNonGeographyMetricRows(transposed.rows)
            transposedWhole = transposed.wholeCompanyAmount
        } else {
            (built, _) = RevenueRecognitionCandidates.buildRows(
                table: selectedTable, column: wholeCompanyColumn, applyParallelDimension: false)
            built = dropNonGeographyMetricRows(built)
            if built.isEmpty {
                let transposed = RevenueRecognitionCandidates.transposeMetricRow(
                    table: selectedTable, wholeCompanyColumn: wholeCompanyColumn,
                    geographySales: true)
                built = dropNonGeographyMetricRows(transposed.rows)
                transposedWhole = transposed.wholeCompanyAmount
            }
        }
        if built.isEmpty {
            stampJev(&audit, applied: false, needsReview: true)
            return (nil, audit)
        }

        let belowThreshold = (choice.confidence ?? 0) < RevenueRecognitionColumnNormalizer
            .confidenceThreshold
        var warnings: [String] = []
        var needsReview = belowThreshold || resolved.forceReview
        if belowThreshold { warnings.append(RevenueRecognitionColumnNormalizer.warningLowConfidence) }
        if resolved.forceReview {
            warnings.append(RevenueRecognitionColumnNormalizer.warningNoneOfTheseOverridden)
        }

        let tableTotalAmount = RevenueRecognitionCandidates.tableTotal(
            table: selectedTable, column: wholeCompanyColumn)?.amount
        let scaleRef = transposedWhole
            ?? tableTotalAmount
            ?? built.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
                .reduce(0) { $0 + $1.amount }
        let declaredUnit = inferredDeclaredUnit(
            tableTotal: scaleRef == 0 ? nil : scaleRef,
            consolidatedSales: consolidatedSales)
        let scale = BreakdownLLMAmountScale.scaling(
            declaredUnit: declaredUnit,
            tables: result.tables,
            sourceTableIndex: selectedTable.tableIndex,
            rawAmounts: built.map(\.amount),
            consolidatedSales: consolidatedSales
        )
        BreakdownLLMAmountScale.applyPublicFlags(
            scale, needsReview: &needsReview, warnings: &warnings)
        let unitMultiplier = scale.multiplier

        var strippedFootnotes: [String] = []
        var rows: [BreakdownRow] = []
        for row in built {
            let rawLabel = geographyPublishedLabel(row)
            let label = stripGeographyLabelFootnotes(rawLabel)
            if label != rawLabel {
                strippedFootnotes.append("\(rawLabel)→\(label)")
            }
            rows.append(BreakdownRow(
                labelRaw: label,
                amount: row.amount * unitMultiplier,
                share: nil,
                profit: nil,
                rowKind: geographyRowKind(label: label, fallback: row.rowKind)
            ))
        }
        appendSubtotalRows(
            from: selectedTable, column: wholeCompanyColumn, multiplier: unitMultiplier,
            into: &rows, strippedFootnotes: &strippedFootnotes)

        if !strippedFootnotes.isEmpty {
            let suffix = "label_footnotes_stripped: " + strippedFootnotes.joined(separator: "; ")
            notes = notes.isEmpty ? suffix : notes + " / " + suffix
            audit.notes = notes
        }

        rows = dropOfWhichSubsetSegments(rows)
        rows = dropCoarseOverseasWhenFinerRegionsExist(rows)

        if extractedSubtotalsMismatch(rows) {
            needsReview = true
            warnings.append(subtotalMismatchWarning)
        }

        let segmentLabels = rows.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        let hasGeographyLikeLabel = segmentLabels.contains { label in
            Xbrl.segmentGeographyLabelKeywordsJa.contains { label.contains($0) }
        }
        if !hasGeographyLikeLabel {
            needsReview = true
            warnings.append("geography_label_mismatch")
        }

        let segmentSum = rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + $1.amount }
        let reconcilingSum = rows.filter { $0.rowKind == "reconciling" }.reduce(0.0) { $0 + $1.amount }
        let segmentShare = segmentSum / consolidatedSales

        var denominator = consolidatedSales
        var denominatorTag = "income_statement.sales"

        if !denominatorTolerance.contains(segmentShare) {
            let internalSum = segmentSum + reconcilingSum
            let subtotalCandidates = rows.filter { $0.rowKind == "subtotal" }
            if let closest = subtotalCandidates.min(by: {
                abs($0.amount - internalSum) < abs($1.amount - internalSum)
            }), closest.amount != 0, abs(closest.amount - internalSum) / abs(closest.amount) <= 0.05 {
                denominator = closest.amount
                denominatorTag = "llm_table_subtotal"
                warnings.append("llm_denominator_from_internal_subtotal")
            } else if let transposedWhole, transposedWhole != 0 {
                denominator = transposedWhole * unitMultiplier
                denominatorTag = "llm_table_subtotal"
                warnings.append("llm_denominator_from_internal_subtotal")
            } else {
                needsReview = true
                warnings.append("llm_row_sum_mismatch")
            }
        }

        let rowsWithShare = rows.map { row -> BreakdownRow in
            var copy = row
            copy.share = copy.amount / denominator
            return copy
        }

        audit.sourceTableIndex = selectedTable.tableIndex
        audit.periodColumn = selectedColumn.key
        audit.unit = scale.headerToken ?? selectedTable.unitCaption ?? ""
        stampJev(&audit, applied: !belowThreshold, needsReview: needsReview)

        let snapshot = BreakdownSnapshot(
            axis: "geography",
            denominator: denominator,
            denominatorTag: denominatorTag,
            rows: rowsWithShare,
            sourceKind: "html_table",
            needsReview: needsReview,
            warnings: warnings
        )
        return (snapshot, audit)
    }

    /// 抽出済み subtotal が segment / reconciling の一部の和と一致しないときの警告。
    /// 公開面は `needs_review` で隠す。
    static let subtotalMismatchWarning = "subtotal_mismatch"

    /// 相対 0.5%。百万円表の行丸めは通すが、1 桁のコピー誤り（約 1.4% 以上）は落とす。
    private static let subtotalRelativeTolerance = 0.005

    static func offeredColumns(
        _ columns: [RevenueRecognitionCandidates.AmountColumn],
        tables: [RevenueRecognitionCandidates.ParsedTable]
    ) -> [RevenueRecognitionCandidates.AmountColumn] {
        let byIndex = Dictionary(uniqueKeysWithValues: tables.map { ($0.tableIndex, $0) })
        let usable = columns.filter { column in
            guard let table = byIndex[column.tableIndex] else { return true }
            if RevenueRecognitionColumnNormalizer.isPriorOnlyColumn(column, table: table) {
                return false
            }
            let header = RevenueRecognitionCandidates.collapsedCell(column.header)
            if RevenueRecognitionCandidates.isOfWhichColumnHeader(column.header) { return false }
            if header.contains("％") || header.contains("%") || header.contains("構成比") {
                return false
            }
            return true
        }
        let regionColumnTables = tables.filter {
            regionColumnCount($0) >= 2 && tableHasGeographySalesMetric($0)
        }
        let tablesForOffer = regionColumnTables.isEmpty ? tables : regionColumnTables
        var preferred: [RevenueRecognitionCandidates.AmountColumn] = []
        for table in tablesForOffer {
            let tableCols = usable.filter { $0.tableIndex == table.tableIndex }
            let totals = tableCols.filter {
                RevenueRecognitionCandidates.isAggregateColumnHeader($0.header)
            }
            let rowGeo = (table.items.map(\.label) + table.totals.map(\.label)).filter { label in
                looksLikeGeographyLabel(label)
            }
            if regionColumnCount(table) >= 2 {
                preferred.append(contentsOf: totals.isEmpty ? tableCols : totals)
            } else if rowGeo.count >= 2, !totals.isEmpty {
                // 3659: 行=地域、列=事業＋合計。合計列だけを選ぶ。
                preferred.append(contentsOf: totals)
            } else {
                preferred.append(contentsOf: tableCols)
            }
        }
        return preferred.isEmpty ? (usable.isEmpty ? columns : usable) : preferred
    }

    static func regionColumnCount(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> Int {
        let headers = table.columnHeaders.values
            + table.grid.prefix(table.headerRowCount).flatMap { $0 }
        return Set(headers.filter {
            looksLikeGeographyLabel($0) && !RevenueRecognitionCandidates.isAggregateColumnHeader($0)
                && !RevenueRecognitionCandidates.isOfWhichColumnHeader($0)
        }.map { RevenueRecognitionCandidates.collapsedCell($0) }).count
    }

    static func preferredWholeCompanyColumn(
        _ table: RevenueRecognitionCandidates.ParsedTable, selected: Int
    ) -> Int {
        guard regionColumnCount(table) >= 2 else { return selected }
        let totals = table.columnHeaders.filter {
            RevenueRecognitionCandidates.isAggregateColumnHeader($0.value)
        }
        return totals.keys.sorted().last ?? selected
    }

    static func looksLikeGeographyLabel(_ label: String) -> Bool {
        let compact = RevenueRecognitionCandidates.collapsedCell(label)
        return Xbrl.segmentGeographyLabelKeywordsJa.contains { compact.contains($0) }
    }

    static func tableHasGeographySalesMetric(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> Bool {
        let labels = table.items.map(\.label) + table.totals.map(\.label)
            + table.grid.prefix(6).compactMap(\.first)
        if labels.contains(where: { $0.contains("政府債") || $0.contains("有価証券") }) {
            return false
        }
        return labels.contains { RevenueRecognitionCandidates.isGeographySalesMetricLabel($0) }
            || RevenueRecognitionCandidates.geographySalesMetricRowIndex(table) != nil
    }

    static func dropAssetTables(
        _ tables: [RevenueRecognitionCandidates.ParsedTable]
    ) -> [RevenueRecognitionCandidates.ParsedTable] {
        let sales = tables.filter { !isAssetMetricTable($0) && !isUnitStubTable($0) }
        return sales.isEmpty ? tables : sales
    }

    /// 顧客別表など、地域ラベルが無い表は列候補から外す（4575 の主要顧客表）。
    static func dropNonGeographyTables(
        _ tables: [RevenueRecognitionCandidates.ParsedTable]
    ) -> [RevenueRecognitionCandidates.ParsedTable] {
        let geo = tables.filter(isGeographyContentTable)
        return geo.isEmpty ? tables : geo
    }

    static func isGeographyContentTable(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> Bool {
        var labels = [table.precedingCaption ?? ""]
            + Array(table.columnHeaders.values)
            + table.items.map(\.label) + table.totals.map(\.label)
        if table.headerRowCount > 0 {
            labels.append(contentsOf: table.grid.prefix(table.headerRowCount).flatMap { $0 })
        }
        if labels.contains(where: {
            $0.contains("期日内") || $0.contains("30日") || $0.contains("90日")
                || $0.contains("税引前当期純利益")
        }) {
            return false
        }
        return labels.contains { label in
            looksLikeGeographyLabel(label)
                || label.contains("その他の地域") || label.contains("その他地域")
        }
    }

    static func dropNonGeographyMetricRows(
        _ rows: [RevenueRecognitionCandidates.BuiltRow]
    ) -> [RevenueRecognitionCandidates.BuiltRow] {
        rows.filter { row in
            let label = RevenueRecognitionCandidates.displayLabel(
                categoryGroup: row.categoryGroup, category: row.category)
            let group = row.categoryGroup
            if RevenueRecognitionCandidates.isAssetMetricLabel(label)
                || RevenueRecognitionCandidates.isAssetMetricLabel(group)
            {
                return false
            }
            if RevenueRecognitionCandidates.isPeriodHeadingLabel(label) { return false }
            if RevenueRecognitionCandidates.isPercentMetricLabel(label) { return false }
            if label.contains("単位") || label.hasPrefix("Ⅰ") || label.hasPrefix("Ⅱ")
                || label.hasPrefix("I．") || label.hasPrefix("I.")
            {
                return false
            }
            if RevenueRecognitionCandidates.isGeographySalesMetricLabel(label),
               !looksLikeGeographyLabel(label)
                && !label.contains("その他の地域") && !label.contains("その他地域")
            {
                return false
            }
            if label.contains("セグメント損失") || label.contains("セグメント利益") {
                return false
            }
            if group.contains("政府債") || label.contains("政府債") { return false }
            return true
        }
    }

    static func isAssetMetricTable(_ table: RevenueRecognitionCandidates.ParsedTable) -> Bool {
        let blob = [
            table.heading,
            table.precedingCaption ?? "",
            table.columnHeaders.values.joined(separator: " "),
            table.items.map(\.label).joined(separator: " "),
            table.totals.map(\.label).joined(separator: " "),
        ].joined(separator: " ")
        if blob.contains("固定資産") || blob.contains("非流動資産") || blob.contains("長期性資産") {
            let hasSales = blob.contains("売上") || blob.contains("外部顧客") || blob.contains("収益")
            if !hasSales { return true }
        }
        return false
    }

    static func isUnitStubTable(_ table: RevenueRecognitionCandidates.ParsedTable) -> Bool {
        let labels = table.items.map(\.label) + table.totals.map(\.label)
            + Array(table.columnHeaders.values)
        let stub = labels.contains { label in
            let compact = RevenueRecognitionCandidates.compactCell(label)
            return compact.contains("単位") || compact.hasPrefix("Ⅰ") || compact.hasPrefix("I．")
                || compact.hasPrefix("I.")
        }
        if !stub { return false }
        let geo = labels.contains { label in
            Xbrl.segmentGeographyLabelKeywordsJa.contains { label.contains($0) }
        }
        return !geo
    }

    /// 親地域の内数（「うち」）として重複計上されている segment 行を除く。
    /// 親を残し内数を落とす（注記の加算構造に合わせる。内数は親金額の内訳開示）。
    static func dropOfWhichSubsetSegments(_ rows: [BreakdownRow]) -> [BreakdownRow] {
        let segmentIndices = rows.indices.filter { rows[$0].rowKind == "segment" }
        guard segmentIndices.count >= 2 else { return rows }
        var drop = Set<Int>()
        for childIdx in segmentIndices {
            let child = rows[childIdx]
            for parentIdx in segmentIndices where parentIdx != childIdx && !drop.contains(parentIdx) {
                let parent = rows[parentIdx]
                if isLikelyOfWhichChild(parent: parent, child: child) {
                    drop.insert(childIdx)
                    break
                }
            }
        }
        guard !drop.isEmpty else { return rows }
        return rows.enumerated().compactMap { drop.contains($0.offset) ? nil : $0.element }
    }

    /// アジア/北米等の細目があるとき、親の「海外」行は小計であり segment に残すと分母が二重になる（5401）。
    /// 日本/海外の2区分（アサヒ型）は細目が無いので残す。
    static func dropCoarseOverseasWhenFinerRegionsExist(
        _ rows: [BreakdownRow]
    ) -> [BreakdownRow] {
        let fine = ["アジア", "北米", "欧州", "米州", "中国", "米国", "オセアニア"]
        let hasFine = rows.contains { row in
            row.rowKind == "segment" && fine.contains { row.labelRaw.contains($0) }
        }
        guard hasFine else { return rows }
        return rows.filter { row in
            !(row.rowKind == "segment" && (row.labelRaw == "海外" || row.labelRaw == "国外"))
        }
    }

    /// 地域ラベル末尾の脚注マーカーを決定的に除去する。
    /// 例: `米州（注）2` → `米州`、`欧州他(注1)` → `欧州他`、`アジア※１` → `アジア`。
    /// 「（注記）」のような一般語や、地域名の一部としての「注」は対象外。
    private static let footnoteStripPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"[\s　]*[（(]\s*注\s*[）)]\s*[0-9０-９]+$"#),
        try! NSRegularExpression(pattern: #"[\s　]*[（(]\s*注\s*[0-9０-９]+\s*[）)]$"#),
        try! NSRegularExpression(pattern: #"[\s　]*[（(]\s*注\s*[）)]$"#),
        try! NSRegularExpression(pattern: #"[\s　]*[※＊*]\s*[0-9０-９]+$"#),
    ]

    static func compactGeographyLabel(_ label: String) -> String {
        var token = RevenueRecognitionCandidates.compactCell(label)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
        token = token.replacingOccurrences(
            of: #"\([^)]*円[^)]*\)"#, with: "", options: .regularExpression)
        token = token.replacingOccurrences(of: "※", with: "")
        return token
    }

    static func geographyPublishedLabel(
        _ row: RevenueRecognitionCandidates.BuiltRow
    ) -> String {
        let group = compactGeographyLabel(row.categoryGroup)
        if let category = row.category.map(compactGeographyLabel), !category.isEmpty {
            if isOfWhichGeographyLabel(category) {
                if group.isEmpty || isOfWhichGeographyLabel(group) { return category }
                return group
            }
            if RevenueRecognitionCandidates.isOtherResidualChild(category),
               !group.isEmpty, group != category,
               !RevenueRecognitionCandidates.isGeographySalesMetricLabel(group),
               !isOfWhichGeographyLabel(group)
            {
                return group + category
            }
            if RevenueRecognitionCandidates.isGeographySalesMetricLabel(group)
                || RevenueRecognitionCandidates.isAssetMetricLabel(group)
            {
                return category
            }
            return category
        }
        return group
    }

    static func stripGeographyLabelFootnotes(_ label: String) -> String {
        var s = label.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for regex in footnoteStripPatterns {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                let replaced = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
                if replaced != s {
                    s = replaced.trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                    break
                }
            }
        }
        return s
    }

    /// 抽出された subtotal 行それぞれについて、構成行の部分集合和が
    /// 丸め許容内で一致しなければ true。subtotal が無ければ検査しない。
    static func extractedSubtotalsMismatch(_ rows: [BreakdownRow]) -> Bool {
        let components = rows.compactMap { row -> Double? in
            (row.rowKind == "segment" || row.rowKind == "reconciling") ? row.amount : nil
        }
        let subtotals = rows.compactMap { row -> Double? in
            row.rowKind == "subtotal" && row.amount != 0 ? row.amount : nil
        }
        guard !subtotals.isEmpty, !components.isEmpty else { return false }
        guard components.count <= 20 else { return false }
        for target in subtotals {
            if !subsetSums(to: target, among: components) {
                return true
            }
        }
        return false
    }

    private static func subsetSums(to target: Double, among amounts: [Double]) -> Bool {
        let tol = abs(target) * subtotalRelativeTolerance
        let n = amounts.count
        var found = false
        func dfs(_ i: Int, _ acc: Double, _ used: Bool) {
            if found { return }
            if used, abs(acc - target) <= tol { found = true; return }
            guard i < n else { return }
            dfs(i + 1, acc + amounts[i], true)
            dfs(i + 1, acc, used)
        }
        dfs(0, 0, false)
        return found
    }

    static func isOfWhichGeographyLabel(_ label: String) -> Bool {
        let compact = RevenueRecognitionCandidates.collapsedCell(label)
        return compact.contains("うち") || compact.hasPrefix("内、") || compact.hasPrefix("内,")
            || (compact.hasPrefix("(") && (compact.contains("うち") || compact.contains("米国")))
    }

    private static func isLikelyOfWhichChild(parent: BreakdownRow, child: BreakdownRow) -> Bool {
        guard child.amount > 0, parent.amount > 0 else { return false }
        guard child.amount <= parent.amount * 1.001 else { return false }
        if isOfWhichGeographyLabel(child.labelRaw) {
            return true
        }
        guard child.amount >= parent.amount * 0.80 else { return false }
        return matchesOfWhichLabelPair(parent: parent.labelRaw, child: child.labelRaw)
    }

    private static func matchesOfWhichLabelPair(parent: String, child: String) -> Bool {
        let pairs: [(parents: [String], children: [String])] = [
            (["北米", "米州", "米大陸", "アメリカ"], ["米国", "アメリカ合衆国"]),
            (["欧州", "ヨーロッパ"], ["フランス", "ドイツ", "英国", "イギリス", "イタリア", "スペイン"]),
        ]
        for pair in pairs {
            let parentHit = pair.parents.contains { parent.contains($0) }
            let childHit = pair.children.contains { child.contains($0) }
            let parentIsChildOnly = pair.children.contains { parent == $0 || parent.contains($0) }
                && !pair.parents.contains { parent.contains($0) }
            if parentHit && childHit && !parentIsChildOnly { return true }
        }
        return false
    }

    private static func geographyRowKind(label: String, fallback: String) -> String {
        if label.contains("消去") || label.contains("除去") || label.contains("調整額") {
            return "reconciling"
        }
        // 連結売上高 / 海外合計 は表の合計・グループ小計。segment に残すと分母が二重になる（7734）。
        if RevenueRecognitionCandidates.isTotalLabel(label)
            || RevenueRecognitionCandidates.isGroupSubtotalLabel(label)
            || label.contains("連結売上") || label == "連結" || label.contains("連結合計")
            || label == "海外計" || label == "海外合計" || label.hasSuffix("合計")
            || label.contains("海外売上収益") || label.contains("海外売上高")
        {
            return "subtotal"
        }
        return fallback
    }

    private static func appendSubtotalRows(
        from table: RevenueRecognitionCandidates.ParsedTable,
        column: Int,
        multiplier: Double,
        into rows: inout [BreakdownRow],
        strippedFootnotes: inout [String]
    ) {
        let amounts = RevenueRecognitionCandidates.dataAmounts(table: table, column: column)
        let existing = Set(rows.map(\.labelRaw))
        for total in table.totals {
            let raw = stripGeographyLabelFootnotes(total.label)
            if raw != total.label {
                strippedFootnotes.append("\(total.label)→\(raw)")
            }
            if RevenueRecognitionCandidates.isGeographySalesMetricLabel(raw),
               !looksLikeGeographyLabel(raw)
            {
                continue
            }
            guard !existing.contains(raw), let amount = amounts[total.row] else { continue }
            rows.append(BreakdownRow(
                labelRaw: raw, amount: amount * multiplier, share: nil, profit: nil,
                rowKind: "subtotal"
            ))
        }
    }

    private static func inferredDeclaredUnit(
        tableTotal: Double?,
        consolidatedSales: Double?
    ) -> String {
        guard let total = tableTotal, total != 0,
              let sales = consolidatedSales, sales != 0
        else { return "other" }
        let yenOK = denominatorTolerance.contains(abs(total / sales))
        let millionOK = denominatorTolerance.contains(
            abs(total * Financial.millionYen / sales))
        if millionOK != yenOK {
            return millionOK ? "million_yen" : "yen"
        }
        return "other"
    }

    private static func jevPayload(
        docID: String, choice: RevenueRecognitionColumnChoice, resolvedKey: String?
    ) -> SegmentNoteJevAuditPayload {
        SegmentNoteJevAuditPayload(
            code: "", docID: docID, axis: breakdownAxisGeography,
            model: choice.model, threshold: RevenueRecognitionColumnNormalizer.confidenceThreshold,
            applied: false, needsReview: false, sentences: [],
            calls: [
                SegmentNoteJevCallPayload(
                    question: RevenueRecognitionColumnNormalizer.question,
                    options: choice.options,
                    selected: resolvedKey ?? choice.selected,
                    probability: choice.confidence,
                    sentences: [],
                    applied: false)
            ])
    }

    private static func stampJev(
        _ audit: inout LLMBreakdownAudit, applied: Bool, needsReview: Bool
    ) {
        func apply(_ payload: SegmentNoteJevAuditPayload?) -> SegmentNoteJevAuditPayload? {
            guard var payload else { return nil }
            payload.applied = applied
            payload.needsReview = needsReview
            if !payload.calls.isEmpty {
                payload.calls[0].applied = applied
            }
            return payload
        }
        audit.jev = apply(audit.jev)
        audit.columnJev = apply(audit.columnJev)
    }
}

struct OpenRouterGeographyColumnDecider: RevenueRecognitionColumnDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    func chooseColumn(
        columns: [RevenueRecognitionCandidates.AmountColumn],
        tables: [RevenueRecognitionCandidates.ParsedTable],
        fiscalYearEnd: String?,
        docID: String
    ) async -> RevenueRecognitionColumnChoice {
        let options = columns.map(\.key) + [RevenueRecognitionColumnNormalizer.noneOfThese]
        let unavailable = RevenueRecognitionColumnChoice(
            selected: nil, confidence: nil, model: model, options: options)
        guard let body = Self.requestJSON(
            model: model, columns: columns, tables: tables,
            fiscalYearEnd: fiscalYearEnd, docID: docID)
        else { return unavailable }
        do {
            let data = try await client.decide(requestJSON: body)
            let answer = OpenRouterDecisionsCodec.answers(from: data)[
                RevenueRecognitionColumnNormalizer.question]
            let choice = answer?.choice
            let probabilities = choice?.probabilities ?? [:]
            let selected = choice?.selected
            let fromProbabilities = selected.flatMap { probabilities[$0] }
            return RevenueRecognitionColumnChoice(
                selected: selected,
                confidence: choice?.confidence ?? fromProbabilities,
                pNone: probabilities[RevenueRecognitionColumnNormalizer.noneOfThese],
                probabilities: probabilities,
                model: model,
                options: options)
        } catch {
            printError("GeographyBreakdownLLMNormalizer: Jev呼び出し失敗: \(error)\n")
            return unavailable
        }
    }

    static func requestJSON(
        model: String,
        columns: [RevenueRecognitionCandidates.AmountColumn],
        tables: [RevenueRecognitionCandidates.ParsedTable],
        fiscalYearEnd: String?,
        docID: String
    ) -> Data? {
        let fy = fiscalYearEnd ?? "不明"
        var criteria: [String: String] = [:]
        for column in columns {
            let caption = column.caption ?? "none"
            let header = column.header.isEmpty ? "none" : column.header
            let unit = column.unit ?? "none"
            criteria[column.key] = """
                table t\(column.tableIndex) (caption above the table: \(caption), unit: \(unit)), \
                column \(column.column) (column header: \(header))
                """
        }
        criteria[RevenueRecognitionColumnNormalizer.noneOfThese] =
            "No column holds current-fiscal-year geography external-sales amounts."
        var tableState: [[String: Any]] = []
        for table in tables {
            tableState.append([
                "table_id": "t\(table.tableIndex)",
                "caption_above_table": table.precedingCaption ?? "",
                "unit": table.unitCaption ?? "",
                "table_markdown": BreakdownExtractor.gridToMarkdown(table.grid),
            ])
        }
        let instructions = """
            The state lists 地域ごとの情報 (geographic information) table(s) from a Japanese \
            annual securities report (有価証券報告書) for the fiscal year ending \(fy), or a \
            収益の分解 table whose rows are regions. Which single column holds CURRENT \
            fiscal year (当連結会計年度 / 当事業年度, the year ending \(fy)) external sales \
            (売上高 / 外部顧客) by geography? The period can be in the caption above a table \
            or in the column header. Prior-year columns (前連結会計年度 / 前事業年度) are \
            wrong. Non-current assets / property, plant and equipment columns are wrong. \
            うち / (うち〜) inner columns are not parallel regions. Composition-ratio \
            columns are wrong. If regions are columns, choose the 合計 / 連結 total column \
            (the code expands the other columns into region rows). If regions are rows, \
            choose the current-year amount column (or 合計 when the table also has \
            business-segment columns). Do not choose none_of_these when a current-year \
            geography sales column exists.
            """
        let questions: [String: Any] = [
            RevenueRecognitionColumnNormalizer.question: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: instructions, criteria: criteria),
        ]
        return OpenRouterDecisionsCodec.requestJSON(
            model: model,
            state: [
                "doc_id": docID,
                "fiscal_year_end": fy,
                "tables": tableState,
            ],
            questions: questions)
    }
}
