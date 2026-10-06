// geography（地域別情報）の html_table を、決定論の表構造チェック + Jev の列選択で
// BreakdownSnapshot へ正規化する。Chat Completions は使わない。
// 表構造は収益認識と同じ候補列。Jev は当期の全社（または合計）金額列だけを選ぶ。
// 行・単位・うち内数・脚注はコードが組む。
// 親地域に（うち〜）が重なった列は親を残す。
// 列 Choice と最終判定は N 回並列（JevChoiceAggregate）。一致は confident（生 confidence
// の 0.5 ゲートは使わない）。不一致・成功不足は needs_review（公開面 fail-closed）。
// 行を組んだあと Jev 第二パスで最終判定する。一致した confident wrong は NR。
// 低確信 NR は一致した confident correct かつハードガード無しのときだけ回復する。
// 分母整合は既存の llm_row_sum_mismatch。アンカーは損益計算書売上、無ければ表の総合計。
// 同じ表の内部小計では満たさない。95–105% の外は NR（correct では覆さない）。
// 表 markdown が reviewMarkdownLimit 字で切れたときは table_truncated を渡し、correct 回復はしない。
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

struct GeographyExtractionReviewRow: Equatable, Sendable {
    var label: String
    var amountMillionYen: Double
    var rowKind: String
}

struct GeographyReviewPeriodColumn: Equatable, Sendable {
    var key: String
    var header: String
    var priorOnly: Bool
    var amounts: [String: Double]
}

protocol GeographyExtractionReviewing: Sendable {
    func reviewExtractedGeography(
        rows: [GeographyExtractionReviewRow],
        tableMarkdown: String,
        heading: String,
        caption: String?,
        warnings: [String],
        needsReview: Bool,
        periodColumns: [GeographyReviewPeriodColumn],
        tableTruncated: Bool,
        docID: String,
        consolidatedSalesMillionYen: Double?
    ) async -> SegmentNoteConsultedChoice
}

enum GeographyBreakdownLLMNormalizer {

    /// 分母整合性チェックの許容範囲。xbrl_facts 経路と同じ 0.95...1.05。
    /// キヤノン地域別注記の計 vs 連結売上 ≈ 2.5% 差は帯の内側。
    private static let denominatorTolerance = 0.95...1.05
    /// 単位推定だけ従来どおり広め。分母整合の帯を単位判定に使わない。
    private static let unitScaleTolerance = 0.90...1.10

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

        let afterFilters = dropAssetTables(
            dropProductGeographyMatricesWhenSimpleExists(
                dropNonGeographyTables(
                    SegmentInfoLLMNormalizer.dropPriorEraTables(
                        parsed, among: parsed, fiscalYearEnd: fiscalYearEnd)
                )
            )
        )
        let currentGeography = afterFilters.filter { $0.period != "前期" }
        // 前期 TextBlock に当期行がある表（1887 S100YXXI / 4568 S100YEY0）は落とさない。
        // 前期だけの地域表は当期内訳に使わない（2146 S100YKK1 / 1968 S100TU63）。
        let priorWithCurrentRow = afterFilters.filter {
            $0.period == "前期" && tableHasCurrentPeriodRow($0)
        }
        if currentGeography.isEmpty, afterFilters.contains(where: { $0.period == "前期" }),
           priorWithCurrentRow.isEmpty
        {
            return (nil, nil)
        }
        let scopedTables =
            currentGeography.isEmpty
            ? (priorWithCurrentRow.isEmpty ? afterFilters : priorWithCurrentRow)
            : currentGeography
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

        let columnSamples = await sampleColumnChoices(
            decider: decider, columns: offered, tables: offeredTables,
            fiscalYearEnd: fiscalYearEnd, docID: docID)
        let columnAggregate = JevChoiceAggregate.combine(
            columnSamples.map(JevChoiceAggregate.fromColumn))
        let choice = JevChoiceAggregate.columnChoice(from: columnAggregate)
        let resolved = RevenueRecognitionColumnNormalizer.resolveSelection(choice, columns: offered)
        let columnJev = jevPayload(
            docID: docID, samples: columnSamples, aggregate: columnAggregate)
        let pNoneNote = choice.pNone.map { String($0) } ?? "nil"
        let medianNote = columnAggregate.probability.map { String($0) } ?? "nil"
        var notes =
            "jev_column=\(choice.selected ?? "nil") samples=\(columnSamples.count) \(columnAggregate.outcome.rawValue) median=\(medianNote) p_none=\(pNoneNote)"
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

        let columnUncertain = !columnAggregate.isConfident
        let priorPeriod = (
            selectedTable.period == "前期" && !tableHasCurrentPeriodRow(selectedTable)
        ) || RevenueRecognitionColumnNormalizer.isPriorOnlyColumn(
            selectedColumn, table: selectedTable)
        var warnings: [String] = []
        var needsReview = columnUncertain || resolved.forceReview || priorPeriod
        switch columnAggregate.outcome {
        case .disagreement:
            warnings.append(warningColumnSampleDisagreement)
        case .insufficient:
            warnings.append(warningColumnSampleInsufficient)
        case .allFailed, .agreed:
            break
        }
        if resolved.forceReview {
            warnings.append(RevenueRecognitionColumnNormalizer.warningNoneOfTheseOverridden)
        }
        if priorPeriod { warnings.append(warningPriorPeriodColumn) }

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
        rows = rows.filter { row in
            guard row.rowKind == "segment" else { return true }
            if RevenueRecognitionCandidates.isPeriodHeadingLabel(row.labelRaw) { return false }
            if row.labelRaw.contains("金額") { return false }
            if RevenueRecognitionCandidates.isGeographySalesMetricLabel(row.labelRaw),
               !looksLikeGeographyLabel(row.labelRaw)
                && !row.labelRaw.contains("その他の地域") && !row.labelRaw.contains("その他地域")
            {
                return false
            }
            return true
        }
        rows = dropDuplicateSegmentLabels(rows)
        rows = dropMismatchedSubtotals(rows)

        if extractedMatchesPriorYearColumn(
            rows: rows, table: selectedTable, selectedColumn: selectedColumn,
            multiplier: unitMultiplier)
        {
            needsReview = true
            if !warnings.contains(warningPriorPeriodColumn) {
                warnings.append(warningPriorPeriodColumn)
            }
        } else if extractedMismatchesSelectedColumn(
            rows: rows, table: selectedTable, selectedColumn: selectedColumn,
            multiplier: unitMultiplier)
        {
            // 組立額が選んだ列のセルに無いとき。原本 S100XRTH の当期は 155,330。
            // 本番 137,712 は訂正 130 S100YTNF の当期列であり、原本表へ載せると不一致。
            needsReview = true
            if !warnings.contains(warningSelectedColumnMismatch) {
                warnings.append(warningSelectedColumnMismatch)
            }
        }

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
        let internalSum = segmentSum + reconcilingSum
        let segmentShare = segmentSum / consolidatedSales

        var denominator = consolidatedSales
        var denominatorTag = "income_statement.sales"
        let fromPublishedSubtotals = tableGrandTotalAmount(
            rows: rows, transposedWhole: transposedWhole, unitMultiplier: unitMultiplier)
        let fromTableTotal = tableTotalAmount.map { $0 * unitMultiplier }
        let tableGrandTotal: Double? = {
            switch (fromPublishedSubtotals, fromTableTotal) {
            case let (row?, table?): return max(row, table)
            case let (row?, nil): return row
            case let (nil, table?): return table
            default: return nil
            }
        }()
        let publishedCoversGrandTotal = tableGrandTotal.map {
            denominatorTolerance.contains(internalSum / $0)
        } ?? false

        // 公開分母の同一報告ベース切替は表の総合計だけ。公開行に近い内部小計では満たさない。
        if let grand = tableGrandTotal, grand != 0, publishedCoversGrandTotal {
            let isGap = relativeGap(internalSum, consolidatedSales)
            let tableGap = relativeGap(internalSum, grand)
            let closerThanSales = isGap > sameBasisGapFloor && tableGap + 1e-12 < isGap
            if !denominatorTolerance.contains(segmentShare) || closerThanSales {
                denominator = grand
                denominatorTag = "llm_table_subtotal"
                warnings.append("llm_denominator_from_internal_subtotal")
            }
        }

        // 既存の分母整合。アンカーは損益計算書売上、無ければ表の総合計。
        // 銀行・保険の経常収益／営業収益表は表の総合計をアンカーにする。
        if let anchor = coverageCheckAnchor(
            table: selectedTable, consolidatedSales: consolidatedSales,
            tableGrandTotal: tableGrandTotal), anchor != 0
        {
            let coverageShare = segmentSum / anchor
            if !denominatorTolerance.contains(coverageShare) {
                needsReview = true
                if !warnings.contains("llm_row_sum_mismatch") {
                    warnings.append("llm_row_sum_mismatch")
                }
            }
        } else if tableUsesNonSalesRevenueLine(selectedTable) {
            let suffix = "coverage_anchor=skipped_non_sales_line"
            notes = notes.isEmpty ? suffix : notes + " / " + suffix
            audit.notes = notes
        }

        let rowsWithShare = rows.map { row -> BreakdownRow in
            var copy = row
            copy.share = copy.amount / denominator
            return copy
        }

        audit.sourceTableIndex = selectedTable.tableIndex
        audit.periodColumn = selectedColumn.key
        audit.unit = scale.headerToken ?? selectedTable.unitCaption ?? ""
        stampJev(&audit, applied: columnAggregate.isConfident, needsReview: needsReview)

        var snapshot = BreakdownSnapshot(
            axis: "geography",
            denominator: denominator,
            denominatorTag: denominatorTag,
            rows: rowsWithShare,
            sourceKind: "html_table",
            needsReview: needsReview,
            warnings: warnings
        )
        if let reviewer = decider as? any GeographyExtractionReviewing {
            (snapshot, audit) = await applyFinalReview(
                snapshot: snapshot, audit: audit, table: selectedTable,
                reviewer: reviewer, docID: docID,
                consolidatedSales: consolidatedSales)
        }
        return (snapshot, audit)
    }

    /// 抽出済み subtotal が segment / reconciling の一部の和と一致しないときの警告。
    /// 公開面は `needs_review` で隠す。
    static let subtotalMismatchWarning = "subtotal_mismatch"
    /// Jev 最終判定が公開行を誤りとしたとき。公開面は `needs_review` で隠す。
    static let warningFinalReviewWrong = "jev_final_review_wrong"
    /// 前期列の金額を当期として組んだとき。公開面は `needs_review`。最終判定の correct では覆さない。
    static let warningPriorPeriodColumn = "geography_prior_period_column"
    /// 表の総合計の方が損益計算書売上より明らかに近いときの同一報告ベース切替。
    private static let sameBasisGapFloor = 0.05
    /// 組んだ金額が選んだ当期列と一致しないとき。最終判定の correct では覆さない。
    static let warningSelectedColumnMismatch = "geography_selected_column_mismatch"
    /// 列サンプルが同じ selected に揃わないとき。最終判定の correct では覆さない。
    static let warningColumnSampleDisagreement = "jev_column_sample_disagreement"
    /// 列サンプルの成功が足りないとき。最終判定の correct では覆さない。
    static let warningColumnSampleInsufficient = "jev_column_sample_insufficient"
    static let reviewCorrect = "correct"
    static let reviewWrong = "wrong"
    static let reviewOptions = [reviewCorrect, reviewWrong]
    static let reviewMarkdownLimit = 8_000

    static func clippedReviewMarkdown(_ raw: String) -> (text: String, truncated: Bool) {
        if raw.count <= reviewMarkdownLimit { return (raw, false) }
        return (String(raw.prefix(reviewMarkdownLimit)), true)
    }

    /// 小計・分母・ラベル・単位・列サンプル不一致のハードガード。最終判定の correct では覆さない。
    static func hasHardGuardWarnings(_ warnings: [String]) -> Bool {
        warnings.contains(subtotalMismatchWarning)
            || warnings.contains("llm_row_sum_mismatch")
            || warnings.contains("geography_label_mismatch")
            || warnings.contains(breakdownWarningLLMUnitUnresolved)
            || warnings.contains(warningPriorPeriodColumn)
            || warnings.contains(warningSelectedColumnMismatch)
            || warnings.contains(warningColumnSampleDisagreement)
            || warnings.contains(warningColumnSampleInsufficient)
    }

    static func relativeGap(_ amount: Double, _ reference: Double) -> Double {
        guard reference != 0 else { return .infinity }
        return abs(amount - reference) / abs(reference)
    }

    /// 表の総合計ラベル（計／合計）。小計・海外計は総合計ではない。
    static func isTableGrandTotalLabel(_ label: String) -> Bool {
        let compact = RevenueRecognitionCandidates.compactCell(label)
        if compact.contains("小計") { return false }
        if compact == "海外計" || compact == "海外合計" { return false }
        return compact == "計" || compact == "合計" || compact == "連結合計"
            || compact == "連結計" || compact == "売上高合計" || compact == "総合計"
            || compact == "連結売上高" || compact == "連結売上"
    }

    /// 表の総合計（計／合計。公開行に近い内部小計ではない）。
    static func tableGrandTotalAmount(
        rows: [BreakdownRow],
        transposedWhole: Double?,
        unitMultiplier: Double
    ) -> Double? {
        let subtotals = rows.filter { $0.rowKind == "subtotal" && $0.amount > 0 }
        let grandLabeled = subtotals.filter { isTableGrandTotalLabel($0.labelRaw) }
        // 公開行に合う内部小計へフォールバックしない（計が subtotal_mismatch で落ちたあとの小計）。
        let fromRows = grandLabeled.max(by: { $0.amount < $1.amount })?.amount
        let fromTransposed: Double? = {
            guard let transposedWhole, transposedWhole != 0 else { return nil }
            return transposedWhole * unitMultiplier
        }()
        switch (fromRows, fromTransposed) {
        case let (row?, transposed?): return max(row, transposed)
        case let (row?, nil): return row
        case let (nil, transposed?): return transposed
        default: return nil
        }
    }

    /// 分母整合のアンカー。損益計算書売上があればそれ、無ければ表の総合計。
    /// 経常収益／営業収益／保険収益の表は表の総合計を先に使う。
    static func coverageCheckAnchor(
        table: RevenueRecognitionCandidates.ParsedTable,
        consolidatedSales: Double,
        tableGrandTotal: Double?
    ) -> Double? {
        if tableUsesNonSalesRevenueLine(table) {
            if let tableGrandTotal, tableGrandTotal != 0 { return tableGrandTotal }
            return nil
        }
        if consolidatedSales != 0 { return consolidatedSales }
        if let tableGrandTotal, tableGrandTotal != 0 { return tableGrandTotal }
        return nil
    }

    /// 銀行・保険など、地理注記の行が売上高ではなく経常収益／営業収益／保険収益のとき。
    static func tableUsesNonSalesRevenueLine(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> Bool {
        let labels = [table.heading, table.precedingCaption ?? ""]
            + Array(table.columnHeaders.values)
            + table.items.map(\.label) + table.totals.map(\.label)
        return labels.contains { label in
            let compact = RevenueRecognitionCandidates.compactCell(label)
            return compact.contains("経常収益") || compact.contains("営業収益")
                || compact.contains("保険収益")
        }
    }

    /// 組んだ金額が当期列ではなく、同じ表の前期列と一致するとき。
    /// 列キーが当期でもセルが前期なら公開しない。
    static func extractedMatchesPriorYearColumn(
        rows: [BreakdownRow],
        table: RevenueRecognitionCandidates.ParsedTable,
        selectedColumn: RevenueRecognitionCandidates.AmountColumn,
        multiplier: Double
    ) -> Bool {
        let segments = rows.filter { $0.rowKind == "segment" }
        guard !segments.isEmpty else { return false }
        let priorColumns = RevenueRecognitionCandidates.amountColumns(in: [table]).filter {
            $0.column != selectedColumn.column
                && RevenueRecognitionColumnNormalizer.isPriorOnlyColumn($0, table: table)
        }
        guard !priorColumns.isEmpty else { return false }
        if amountsMatchColumn(
            segments, table: table, column: selectedColumn.column, multiplier: multiplier)
        {
            return false
        }
        return priorColumns.contains {
            amountsMatchColumn(segments, table: table, column: $0.column, multiplier: multiplier)
        }
    }

    /// 選んだ列に同じラベルがあるのに金額が違うとき（原本 120 の 155,330 列へ訂正 130 の 137,712 を載せた形）。
    /// 同一ラベルが売上と資産で二度出る表は、どれか1つの出現に一致すれば足りる。
    static func extractedMismatchesSelectedColumn(
        rows: [BreakdownRow],
        table: RevenueRecognitionCandidates.ParsedTable,
        selectedColumn: RevenueRecognitionCandidates.AmountColumn,
        multiplier: Double
    ) -> Bool {
        let segments = rows.filter { $0.rowKind == "segment" }
        guard !segments.isEmpty else { return false }
        let map = allAmountsByCompactLabel(
            table: table, column: selectedColumn.column, multiplier: multiplier)
        let comparable = segments.filter { !(map[compactGeographyLabel($0.labelRaw)] ?? []).isEmpty }
        guard !comparable.isEmpty else { return false }
        return comparable.contains { row in
            let candidates = map[compactGeographyLabel(row.labelRaw)] ?? []
            return candidates.allSatisfy { expected in
                abs(expected - row.amount) > max(1.0, abs(expected) * subtotalRelativeTolerance)
            }
        }
    }

    private static func amountsMatchColumn(
        _ segments: [BreakdownRow],
        table: RevenueRecognitionCandidates.ParsedTable,
        column: Int,
        multiplier: Double
    ) -> Bool {
        let map = allAmountsByCompactLabel(table: table, column: column, multiplier: multiplier)
        return segments.allSatisfy { row in
            let candidates = map[compactGeographyLabel(row.labelRaw)] ?? []
            return candidates.contains { expected in
                abs(expected - row.amount) <= max(1.0, abs(expected) * subtotalRelativeTolerance)
            }
        }
    }

    private static func allAmountsByCompactLabel(
        table: RevenueRecognitionCandidates.ParsedTable,
        column: Int,
        multiplier: Double
    ) -> [String: [Double]] {
        let amounts = RevenueRecognitionCandidates.dataAmounts(table: table, column: column)
        var map: [String: [Double]] = [:]
        for item in table.items {
            guard let value = amounts[item.row] else { continue }
            map[compactGeographyLabel(item.label), default: []].append(value * multiplier)
        }
        for total in table.totals {
            guard let value = amounts[total.row] else { continue }
            map[compactGeographyLabel(total.label), default: []].append(value * multiplier)
        }
        return map
    }

    static func reviewPeriodColumns(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> [[String: Any]] {
        reviewPeriodColumnValues(table).map { column in
            [
                "key": column.key,
                "header": column.header,
                "prior_only": column.priorOnly,
                "amounts": column.amounts,
            ]
        }
    }

    static func reviewPeriodColumnValues(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> [GeographyReviewPeriodColumn] {
        RevenueRecognitionCandidates.amountColumns(in: [table]).map { column in
            let amounts = RevenueRecognitionCandidates.dataAmounts(
                table: table, column: column.column)
            var byLabel: [String: Double] = [:]
            for item in table.items {
                guard let value = amounts[item.row] else { continue }
                byLabel[item.label] = value
            }
            return GeographyReviewPeriodColumn(
                key: column.key,
                header: column.header,
                priorOnly: RevenueRecognitionColumnNormalizer.isPriorOnlyColumn(
                    column, table: table),
                amounts: byLabel)
        }
    }

    static func canRecoverLowConfidence(_ snapshot: BreakdownSnapshot) -> Bool {
        snapshot.needsReview
            && snapshot.warnings.contains(RevenueRecognitionColumnNormalizer.warningLowConfidence)
            && !snapshot.warnings.contains(RevenueRecognitionColumnNormalizer.warningNoneOfTheseOverridden)
            && !hasHardGuardWarnings(snapshot.warnings)
            && snapshot.rows.contains { $0.rowKind == "segment" }
    }

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

    /// 製品×地域マトリクスは、同じ合計の地域行テーブルがあるときだけ落とす（6762）。
    /// 任天堂型はマトリクスの合計行が地域内訳なので、近い単純表が無いときは残す。
    static func dropProductGeographyMatricesWhenSimpleExists(
        _ tables: [RevenueRecognitionCandidates.ParsedTable]
    ) -> [RevenueRecognitionCandidates.ParsedTable] {
        let matrices = tables.filter(isProductGeographyMatrix)
        let simple = tables.filter(isSimpleGeographyTable)
        guard !matrices.isEmpty, !simple.isEmpty else { return tables }
        let matrixMax = matrices.compactMap(tableMaxAmount).max() ?? 0
        let matchingSimple = simple.contains { table in
            guard let amount = tableMaxAmount(table), matrixMax != 0 else { return false }
            return relativeGap(amount, matrixMax) <= sameBasisGapFloor
        }
        guard matchingSimple else { return tables }
        return tables.filter { !isProductGeographyMatrix($0) }
    }

    static func isSimpleGeographyTable(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> Bool {
        guard !isProductGeographyMatrix(table) else { return false }
        let geoItems = table.items.filter { looksLikeGeographyLabel($0.label) }
        return geoItems.count >= 2
    }

    static func isProductGeographyMatrix(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> Bool {
        guard regionColumnCount(table) >= 2 else { return false }
        let nonGeo = table.items.filter { item in
            let label = item.label
            return !looksLikeGeographyLabel(label)
                && !RevenueRecognitionCandidates.isTotalLabel(label)
                && !RevenueRecognitionCandidates.isGeographySalesMetricLabel(label)
                && !RevenueRecognitionCandidates.isPeriodHeadingLabel(label)
                && !RevenueRecognitionCandidates.isAssetMetricLabel(label)
        }
        return nonGeo.count >= 2
    }

    static func tableMaxAmount(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> Double? {
        var maxAmount: Double?
        for row in table.grid.dropFirst(table.headerRowCount) {
            for cell in row {
                guard let amount = RevenueRecognitionCandidates.parseAmount(cell) else { continue }
                maxAmount = max(maxAmount ?? amount, amount)
            }
        }
        return maxAmount
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

    /// dedicated の Prior コンテキストでも、表内に当期行があれば当期内訳に使う。
    static func tableHasCurrentPeriodRow(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> Bool {
        RevenueRecognitionCandidates.tableHasCurrentPeriodRow(table)
    }

    static func dropNonGeographyMetricRows(
        _ rows: [RevenueRecognitionCandidates.BuiltRow]
    ) -> [RevenueRecognitionCandidates.BuiltRow] {
        var skippingAsset = false
        var kept: [RevenueRecognitionCandidates.BuiltRow] = []
        for row in rows {
            let label = RevenueRecognitionCandidates.displayLabel(
                categoryGroup: row.categoryGroup, category: row.category)
            let group = row.categoryGroup
            if RevenueRecognitionCandidates.isAssetMetricLabel(label)
                || RevenueRecognitionCandidates.isAssetMetricLabel(group)
            {
                skippingAsset = true
                continue
            }
            if skippingAsset { continue }
            if RevenueRecognitionCandidates.isPeriodHeadingLabel(label) { continue }
            if RevenueRecognitionCandidates.isPercentMetricLabel(label) { continue }
            if label.contains("単位") || label.contains("金額") || label.hasPrefix("Ⅰ")
                || label.hasPrefix("Ⅱ") || label.hasPrefix("I．") || label.hasPrefix("I.")
            {
                continue
            }
            if RevenueRecognitionCandidates.isGeographySalesMetricLabel(label),
               !looksLikeGeographyLabel(label)
                && !label.contains("その他の地域") && !label.contains("その他地域")
            {
                continue
            }
            if label.contains("セグメント損失") || label.contains("セグメント利益") {
                continue
            }
            if group.contains("政府債") || label.contains("政府債") { continue }
            kept.append(row)
        }
        return kept
    }

    static func isAssetMetricTable(_ table: RevenueRecognitionCandidates.ParsedTable) -> Bool {
        // 直前キャプションの「売上高」で PPE 表を残さない（6758）。
        let labels = table.items.map(\.label) + table.totals.map(\.label)
            + Array(table.columnHeaders.values)
            + table.grid.prefix(6).compactMap(\.first)
        let body = labels.joined(separator: " ")
        if body.contains("固定資産") || body.contains("非流動資産") || body.contains("長期性資産") {
            let hasSales = labels.contains { label in
                let compact = RevenueRecognitionCandidates.compactCell(label)
                return compact.contains("売上") || compact.contains("外部顧客")
                    || compact.contains("営業収益") || compact == "収益"
            }
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

    /// 同一地域ラベルの二回目以降は売上ブロックのあとに続く PPE / 重複表（8604）。
    static func dropDuplicateSegmentLabels(_ rows: [BreakdownRow]) -> [BreakdownRow] {
        var seen = Set<String>()
        return rows.filter { row in
            guard row.rowKind == "segment" else { return true }
            let key = compactGeographyLabel(row.labelRaw)
            return seen.insert(key).inserted
        }
    }

    /// 売上ブロックの `合計` は残し、後続 PPE の合わない `合計` は捨てる。
    /// `海外計` のような名前付き小計は残して subtotal_mismatch 判定に回す。
    static func dropMismatchedSubtotals(_ rows: [BreakdownRow]) -> [BreakdownRow] {
        let components = rows.compactMap { row -> Double? in
            (row.rowKind == "segment" || row.rowKind == "reconciling") ? row.amount : nil
        }
        guard !components.isEmpty else { return rows }
        var keptGeneric = false
        return rows.filter { row in
            guard row.rowKind == "subtotal", row.amount != 0 else { return true }
            let generic = row.labelRaw == "合計" || row.labelRaw == "計"
            guard generic else { return true }
            if subsetSums(to: row.amount, among: components), !keptGeneric {
                keptGeneric = true
                return true
            }
            return false
        }
    }
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
            if RevenueRecognitionCandidates.isGeographySalesMetricLabel(group)
                || RevenueRecognitionCandidates.isAssetMetricLabel(group)
            {
                return stripStackedOfWhichAnnotation(category)
            }
            if isOfWhichGeographyLabel(category) {
                if group.isEmpty || isOfWhichGeographyLabel(group) {
                    return stripStackedOfWhichAnnotation(category)
                }
                return stripStackedOfWhichAnnotation(group)
            }
            if RevenueRecognitionCandidates.isOtherResidualChild(category),
               !group.isEmpty, group != category,
               !RevenueRecognitionCandidates.isGeographySalesMetricLabel(group),
               !isOfWhichGeographyLabel(group)
            {
                return stripStackedOfWhichAnnotation(group + category)
            }
            return stripStackedOfWhichAnnotation(category)
        }
        return stripStackedOfWhichAnnotation(group)
    }

    static func stripStackedOfWhichAnnotation(_ label: String) -> String {
        RevenueRecognitionCandidates.geographyParentBeforeOfWhichAnnotation(label) ?? label
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
        if RevenueRecognitionCandidates.geographyParentBeforeOfWhichAnnotation(label) != nil {
            return false
        }
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
        var existing = Set(rows.map(\.labelRaw))
        let firstAssetRow = table.grid.enumerated().dropFirst(table.headerRowCount)
            .compactMap { index, row -> Int? in
                let label = RevenueRecognitionCandidates.compactCell(row.first ?? "")
                return RevenueRecognitionCandidates.isAssetMetricLabel(label) ? index : nil
            }.first
        for total in table.totals {
            if let firstAssetRow, total.row >= firstAssetRow { continue }
            let raw = stripGeographyLabelFootnotes(total.label)
            if raw != total.label {
                strippedFootnotes.append("\(total.label)→\(raw)")
            }
            if RevenueRecognitionCandidates.isGeographySalesMetricLabel(raw),
               !looksLikeGeographyLabel(raw)
            {
                continue
            }
            guard existing.insert(raw).inserted, let amount = amounts[total.row] else { continue }
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
        let yenOK = unitScaleTolerance.contains(abs(total / sales))
        let millionOK = unitScaleTolerance.contains(
            abs(total * Financial.millionYen / sales))
        if millionOK != yenOK {
            return millionOK ? "million_yen" : "yen"
        }
        return "other"
    }

    private static func jevPayload(
        docID: String, samples: [RevenueRecognitionColumnChoice],
        aggregate: JevChoiceAggregate.Result
    ) -> SegmentNoteJevAuditPayload {
        let calls = samples.map { sample in
            SegmentNoteJevCallPayload(
                question: RevenueRecognitionColumnNormalizer.question,
                options: sample.options.isEmpty ? aggregate.options : sample.options,
                selected: sample.selected,
                probability: sample.confidence,
                sentences: [],
                applied: false)
        }
        return SegmentNoteJevAuditPayload(
            code: "", docID: docID, axis: breakdownAxisGeography,
            model: aggregate.model.isEmpty
                ? (samples.first?.model ?? "") : aggregate.model,
            threshold: RevenueRecognitionColumnNormalizer.confidenceThreshold,
            applied: false, needsReview: false, sentences: [],
            calls: calls)
    }

    private static func stampJev(
        _ audit: inout LLMBreakdownAudit, applied: Bool, needsReview: Bool
    ) {
        func apply(_ payload: SegmentNoteJevAuditPayload?) -> SegmentNoteJevAuditPayload? {
            guard var payload else { return nil }
            payload.applied = applied
            payload.needsReview = needsReview
            for index in payload.calls.indices
            where payload.calls[index].question == RevenueRecognitionColumnNormalizer.question {
                payload.calls[index].applied = applied
            }
            return payload
        }
        audit.jev = apply(audit.jev)
        audit.columnJev = apply(audit.columnJev)
    }

    private static func sampleColumnChoices(
        decider: any RevenueRecognitionColumnDeciding,
        columns: [RevenueRecognitionCandidates.AmountColumn],
        tables: [RevenueRecognitionCandidates.ParsedTable],
        fiscalYearEnd: String?,
        docID: String
    ) async -> [RevenueRecognitionColumnChoice] {
        await withTaskGroup(of: RevenueRecognitionColumnChoice.self) { group in
            for _ in 0..<JevChoiceAggregate.sampleCount {
                group.addTask {
                    await decider.chooseColumn(
                        columns: columns, tables: tables,
                        fiscalYearEnd: fiscalYearEnd, docID: docID)
                }
            }
            var samples: [RevenueRecognitionColumnChoice] = []
            samples.reserveCapacity(JevChoiceAggregate.sampleCount)
            for await choice in group { samples.append(choice) }
            return samples
        }
    }

    /// 組んだ行が当期全社の地域別売上として正しいか Jev に聞く。
    /// 公開直前の一致した confident wrong は NR。低確信 NR の一致した confident correct は
    /// ハードガード無しのときだけ回復。表 markdown が切れているときは correct 回復をしない
    /// （wrong の降格はする）。呼び出し失敗・不一致・低信頼は提案を維持する。
    static func applyFinalReview(
        snapshot: BreakdownSnapshot,
        audit: LLMBreakdownAudit,
        table: RevenueRecognitionCandidates.ParsedTable,
        reviewer: any GeographyExtractionReviewing,
        docID: String,
        consolidatedSales: Double
    ) async -> (BreakdownSnapshot, LLMBreakdownAudit) {
        let shouldAsk = !snapshot.needsReview || canRecoverLowConfidence(snapshot)
        guard shouldAsk else { return (snapshot, audit) }

        let rows = snapshot.rows.map {
            GeographyExtractionReviewRow(
                label: $0.labelRaw,
                amountMillionYen: $0.amount / Financial.millionYen,
                rowKind: $0.rowKind)
        }
        let clipped = clippedReviewMarkdown(BreakdownExtractor.gridToMarkdown(table.grid))
        let periodColumns = reviewPeriodColumnValues(table)
        let reviewSamples = await withTaskGroup(of: SegmentNoteConsultedChoice.self) { group in
            for _ in 0..<JevChoiceAggregate.sampleCount {
                group.addTask {
                    await reviewer.reviewExtractedGeography(
                        rows: rows,
                        tableMarkdown: clipped.text,
                        heading: table.heading,
                        caption: table.precedingCaption,
                        warnings: snapshot.warnings,
                        needsReview: snapshot.needsReview,
                        periodColumns: periodColumns,
                        tableTruncated: clipped.truncated,
                        docID: docID,
                        consolidatedSalesMillionYen: consolidatedSales / Financial.millionYen)
                }
            }
            var samples: [SegmentNoteConsultedChoice] = []
            samples.reserveCapacity(JevChoiceAggregate.sampleCount)
            for await choice in group { samples.append(choice) }
            return samples
        }
        let aggregate = JevChoiceAggregate.combine(reviewSamples.map(JevChoiceAggregate.fromReview))

        var next = snapshot
        var nextAudit = audit
        let high = SegmentNoteDecision.meetsThreshold(aggregate.probability)
        var applied = false
        if aggregate.isConfident, high, aggregate.selected == reviewWrong, !snapshot.needsReview {
            next.needsReview = true
            next.warnings.append(warningFinalReviewWrong)
            applied = true
        } else if aggregate.isConfident, high, aggregate.selected == reviewCorrect,
            canRecoverLowConfidence(snapshot), !clipped.truncated
        {
            next.needsReview = false
            applied = true
        }
        let reviewCalls = reviewSamples.map { sample in
            SegmentNoteJevCallPayload(
                question: OpenRouterSegmentNoteDecider.reviewDecisionQuestion,
                options: sample.options.isEmpty ? reviewOptions : sample.options,
                selected: sample.selected,
                probability: sample.probability,
                sentences: sample.sentences,
                applied: applied && sample.selected == aggregate.selected)
        }
        if var jev = nextAudit.jev {
            jev.calls.append(contentsOf: reviewCalls)
            jev.needsReview = next.needsReview
            if applied {
                jev.applied = true
                jev.decisionSource = SegmentNoteDecision.reviewDecisionSource
            }
            nextAudit.jev = jev
        } else {
            nextAudit.jev = SegmentNoteJevAuditPayload(
                code: "", docID: docID, axis: breakdownAxisGeography,
                model: Api.openrouterDecisionsModel,
                threshold: SegmentNoteDecision.applyProbabilityThreshold,
                applied: applied, needsReview: next.needsReview, sentences: [],
                calls: reviewCalls,
                decisionSource: applied ? SegmentNoteDecision.reviewDecisionSource : nil)
        }
        let selected = aggregate.selected ?? "nil"
        let pNote = aggregate.probability.map { String($0) } ?? "nil"
        let suffix =
            "final_review=\(selected) samples=\(reviewSamples.count) \(aggregate.outcome.rawValue) p=\(pNote) applied=\(applied)"
        nextAudit.notes = nextAudit.notes.isEmpty ? suffix : nextAudit.notes + " / " + suffix
        return (next, nextAudit)
    }
}

struct OpenRouterGeographyColumnDecider: RevenueRecognitionColumnDeciding, GeographyExtractionReviewing {
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

    func reviewExtractedGeography(
        rows: [GeographyExtractionReviewRow],
        tableMarkdown: String,
        heading: String,
        caption: String?,
        warnings: [String],
        needsReview: Bool,
        periodColumns: [GeographyReviewPeriodColumn],
        tableTruncated: Bool,
        docID: String,
        consolidatedSalesMillionYen: Double?
    ) async -> SegmentNoteConsultedChoice {
        let unavailable = SegmentNoteConsultedChoice(
            question: OpenRouterSegmentNoteDecider.reviewDecisionQuestion,
            selected: nil, probability: nil,
            options: GeographyBreakdownLLMNormalizer.reviewOptions, sentences: [])
        guard let body = Self.reviewRequestJSON(
            model: model, rows: rows, tableMarkdown: tableMarkdown, heading: heading,
            caption: caption, warnings: warnings, needsReview: needsReview,
            periodColumns: periodColumns, tableTruncated: tableTruncated, docID: docID,
            consolidatedSalesMillionYen: consolidatedSalesMillionYen)
        else {
            return unavailable
        }
        do {
            let data = try await client.decide(requestJSON: body)
            return OpenRouterSegmentNoteDecider.consultedChoice(
                from: data, question: OpenRouterSegmentNoteDecider.reviewDecisionQuestion,
                options: GeographyBreakdownLLMNormalizer.reviewOptions, sentences: [])
        } catch {
            printError("GeographyBreakdownLLMNormalizer: 最終判定のJev呼び出し失敗: \(error)\n")
            return unavailable
        }
    }

    static func reviewRequestJSON(
        model: String,
        rows: [GeographyExtractionReviewRow],
        tableMarkdown: String,
        heading: String,
        caption: String?,
        warnings: [String],
        needsReview: Bool,
        periodColumns: [GeographyReviewPeriodColumn] = [],
        tableTruncated: Bool = false,
        docID: String,
        consolidatedSalesMillionYen: Double? = nil
    ) -> Data? {
        let criteria: [String: String] = [
            GeographyBreakdownLLMNormalizer.reviewCorrect: """
                抽出された行は、当期の全社（合計／連結）列から組んだ仕向地または地域ごとの \
                外部顧客売上高の内訳である。日本のみ・単一地域も正しい。うち内数を落としているのは正しい。 \
                有形固定資産・長期性資産・事業別・顧客別ではない。前期列の金額ではない。
                """,
            GeographyBreakdownLLMNormalizer.reviewWrong: """
                抽出された行は正しくない。前期列の金額、有形固定資産／長期性資産、事業別、顧客別、 \
                うち内数の独立行、合計や列の取り違えなど、当期・全社の地域別売上ではない。 \
                period_columns の prior_only=true の金額と抽出行が一致するなら wrong。 \
                表にある地域が抽出から欠け、合計が consolidated_sales_million_yen より明らかに足りないなら wrong。
                """,
        ]
        let rowState: [[String: Any]] = rows.map {
            [
                "label": $0.label,
                "amount_million_yen": $0.amountMillionYen,
                "row_kind": $0.rowKind,
            ]
        }
        let columnState: [[String: Any]] = periodColumns.map {
            [
                "key": $0.key,
                "header": $0.header,
                "prior_only": $0.priorOnly,
                "amounts": $0.amounts,
            ]
        }
        let questions: [String: Any] = [
            OpenRouterSegmentNoteDecider.reviewDecisionQuestion: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: """
                    抽出された行は、当期・会社全体の仕向地／地域別（外部顧客への売上高）の内訳として正しいか。 \
                    正しいなら correct、誤りなら wrong。前期列の金額なら wrong。 \
                    period_columns に当期列と前期列の金額がある。抽出行が前期列と一致し当期列と一致しないなら wrong。 \
                    表の地域が欠け、抽出合計が consolidated_sales_million_yen より明らかに足りないなら wrong。 \
                    欠落を correct で回復してはいけない。自信が無いときは probabilities を下げる。
                    """,
                criteria: criteria),
        ]
        var state: [String: Any] = [
            "doc_id": docID,
            "heading": heading,
            "caption_above_table": caption ?? "",
            "warnings": warnings,
            "needs_review": needsReview,
            "extracted_rows": rowState,
            "period_columns": columnState,
            "table_markdown": tableMarkdown,
            "table_truncated": tableTruncated,
        ]
        if let sales = consolidatedSalesMillionYen {
            state["consolidated_sales_million_yen"] = sales
        }
        return OpenRouterDecisionsCodec.requestJSON(
            model: model,
            state: state,
            questions: questions)
    }
}
