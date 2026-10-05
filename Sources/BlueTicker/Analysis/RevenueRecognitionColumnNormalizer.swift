// 収益認識関係注記の html_table を、Jev の列選択 + 決定論の行組立で BreakdownSnapshot にする。
// Jev は当期の全社金額列（セグメント列があるときは合計列）だけを選ぶ。行・ラベル・金額は書かない。
// Luna / Chat Completions は使わない。

import Foundation

protocol RevenueRecognitionColumnDeciding: Sendable {
    func chooseColumn(
        columns: [RevenueRecognitionCandidates.AmountColumn],
        tables: [RevenueRecognitionCandidates.ParsedTable],
        fiscalYearEnd: String?,
        docID: String
    ) async -> RevenueRecognitionColumnChoice
}

struct RevenueRecognitionColumnChoice: Equatable, Sendable {
    var selected: String?
    var confidence: Double?
    var pNone: Double? = nil
    var probabilities: [String: Double] = [:]
    var model: String
    var options: [String]
}

enum RevenueRecognitionColumnNormalizer {
    /// Live 296 件: 誤った列選択はどの confidence でも 0 件。正しい列の false needs_review は
    /// 閾値 0.5 で 14 件、0.6 で 23 件。同一入力でも 272A は 0.69 / 0.94 / 0.87 と揺れる。
    static let confidenceThreshold: Double = 0.5
    /// none_of_these を採用するのは confidence と p_none が両方高いときだけ。
    static let noneOfTheseMinConfidence: Double = 0.5
    static let noneOfTheseMinPNone: Double = 0.75

    static let noneOfThese = "none_of_these"
    static let question = "col"
    static let warningLowConfidence = "jev_column_confidence_below_threshold"
    static let warningGroupSumMismatch = "revenue_recognition_group_sum_mismatch"
    static let warningTableSumMismatch = "revenue_recognition_table_sum_mismatch"
    static let warningNoneOfTheseOverridden = "jev_none_of_these_overridden"
    static let warningNoCategoryRows = "revenue_recognition_no_category_rows"
    static let warningParallelDimensions = "revenue_recognition_parallel_dimensions_unresolved"
    static let warningCategoryRowsDropped = "revenue_recognition_category_rows_dropped"
    static let warningCustomerOrTimingAxis = "revenue_recognition_customer_or_timing_axis_only"
    static let warningGeographyAxisOnly = "revenue_recognition_geography_axis_only"
    static let warningDenominatorUndercoverage = "revenue_recognition_denominator_undercoverage"
    static let warningPriorPeriod = "revenue_recognition_prior_period_table"
    static let warningSingleRowTable = "revenue_recognition_single_row_table"
    static let warningZeroEmittedSum = "revenue_recognition_zero_emitted_sum"
    /// 明細合計が分母の 95% を切ったら不足（表合計が無く連結売上に落ちる 6620）。
    static let coverageFloor: Double = 0.95
    /// カテゴリ行だけ。合計行・グリッドの「その他の収益（注）」ではカバー不足を免除しない。
    static let recognizedOtherRevenueMarkers = ["その他の源泉", "その他の収益", "その他収益"]

    static func normalize(
        _ result: ExtractedBreakdown,
        consolidatedSales: Double?,
        decider: any RevenueRecognitionColumnDeciding,
        fiscalYearEnd: String?,
        docID: String,
        denominatorTag: String? = nil
    ) async -> (snapshot: BreakdownSnapshot?, audit: LLMBreakdownAudit?) {
        guard !result.tables.isEmpty else { return (nil, nil) }
        let parsed = RevenueRecognitionCandidates.parse(tables: result.tables)
        let columns = RevenueRecognitionCandidates.amountColumns(in: parsed)
        guard !columns.isEmpty else { return (nil, nil) }

        let constraint = RevenueRecognitionTableStructure.axisConstraint(tables: parsed)
        let offered = offeredColumns(columns, tables: parsed, constraint: constraint)
        let offeredTables = parsed.filter { table in
            offered.contains { $0.tableIndex == table.tableIndex }
        }
        let choice = await decider.chooseColumn(
            columns: offered, tables: offeredTables, fiscalYearEnd: fiscalYearEnd, docID: docID)
        var resolved = resolveSelection(choice, columns: offered)
        resolved = preferProductAxis(
            resolved, columns: offered, tables: parsed, constraint: constraint)
        let jev = SegmentNoteJevAuditPayload(
            code: "", docID: docID, axis: breakdownAxisBusiness,
            model: choice.model, threshold: confidenceThreshold,
            applied: false, needsReview: false, sentences: [],
            calls: [
                SegmentNoteJevCallPayload(
                    question: question,
                    options: choice.options,
                    selected: resolved?.key ?? choice.selected,
                    probability: choice.confidence,
                    sentences: [],
                    applied: false)
            ])
        let pNoneNote = choice.pNone.map { String($0) } ?? "nil"
        var notes =
            "jev_column=\(choice.selected ?? "nil") confidence=\(choice.confidence.map { String($0) } ?? "nil") p_none=\(pNoneNote)"
        if let resolved, resolved.forceReview {
            notes += " overridden=\(resolved.key)"
        }
        var audit = LLMBreakdownAudit(
            sourceTableIndex: nil, periodColumn: resolved?.key ?? choice.selected, unit: "",
            profitDisclosed: false,
            notes: notes,
            jev: jev,
            columnJev: jev)

        guard let resolved else {
            return (nil, audit)
        }
        guard let column = columns.first(where: { $0.key == resolved.key }),
              let table = parsed.first(where: { $0.tableIndex == column.tableIndex })
        else { return (nil, audit) }

        let sourceHadCategoryRows = !table.items.isEmpty
        let confidence = choice.confidence
        let belowThreshold = confidence.map { $0 < confidenceThreshold } ?? true
        var (built, groupSumReview) = RevenueRecognitionCandidates.buildRows(
            table: table, column: column.column)
        let parallelUnresolved = RevenueRecognitionCandidates.parallelDimensionsUnresolved(
            table: table, column: column.column)
        var transposedWholeCompany: Double?
        if built.isEmpty && !parallelUnresolved {
            let transposed = RevenueRecognitionCandidates.transposeMetricRow(
                table: table, wholeCompanyColumn: column.column)
            built = transposed.rows
            transposedWholeCompany = transposed.wholeCompanyAmount
            groupSumReview = false
        }
        let tableTotal = RevenueRecognitionCandidates.tableTotal(
            table: table, column: column.column)
        var tableSumReview = transposedWholeCompany == nil
            && RevenueRecognitionCandidates.tableSumMismatch(
                rows: built, table: table, column: column.column, cap: tableTotal?.amount)

        let scale = BreakdownLLMAmountScale.scaling(
            declaredUnit: "other",
            tables: result.tables,
            sourceTableIndex: table.tableIndex,
            rawAmounts: built.isEmpty ? [tableTotal?.amount].compactMap { $0 } : built.map(\.amount),
            consolidatedSales: consolidatedSales
        )
        var warnings: [String] = []
        let selectedAxis = RevenueRecognitionTableStructure.tableAxis(of: table)
        let customerReview = selectedAxis == .customer || selectedAxis == .timing
            || constraint == .customerOrTimingOnly
        let geographyReview = selectedAxis == .geography || constraint == .geographyOnly
        let priorReview = table.period == "前期" || isPriorOnlyColumn(column, table: table)
        let droppedCategoryRows = built.isEmpty && sourceHadCategoryRows
        var needsReview = belowThreshold || groupSumReview || tableSumReview
            || resolved.forceReview || built.isEmpty || parallelUnresolved
            || customerReview || geographyReview || priorReview
        if belowThreshold { warnings.append(warningLowConfidence) }
        if resolved.forceReview { warnings.append(warningNoneOfTheseOverridden) }
        if groupSumReview && !parallelUnresolved { warnings.append(warningGroupSumMismatch) }
        if tableSumReview { warnings.append(warningTableSumMismatch) }
        if parallelUnresolved { warnings.append(warningParallelDimensions) }
        if built.isEmpty { warnings.append(warningNoCategoryRows) }
        if droppedCategoryRows { warnings.append(warningCategoryRowsDropped) }
        if customerReview { warnings.append(warningCustomerOrTimingAxis) }
        if geographyReview { warnings.append(warningGeographyAxisOnly) }
        if priorReview { warnings.append(warningPriorPeriod) }
        BreakdownLLMAmountScale.applyPublicFlags(
            scale, needsReview: &needsReview, warnings: &warnings)
        let multiplier = scale.multiplier

        let denominator: Double
        let resolvedDenomTag: String
        if let transposedWholeCompany {
            denominator = transposedWholeCompany * multiplier
            resolvedDenomTag = denominatorTag ?? "llm_table_subtotal"
        } else if let tableTotal {
            denominator = tableTotal.amount * multiplier
            resolvedDenomTag = denominatorTag ?? "llm_table_subtotal"
        } else if let consolidatedSales, consolidatedSales != 0 {
            denominator = consolidatedSales
            resolvedDenomTag = denominatorTag ?? "income_statement.sales"
        } else {
            return (nil, audit)
        }
        guard denominator != 0 else { return (nil, audit) }
        if transposedWholeCompany == nil, !built.isEmpty {
            let tableUnitCap = denominator / multiplier
            if RevenueRecognitionCandidates.emittedSumExceedsCap(built, cap: tableUnitCap) {
                needsReview = true
                if !warnings.contains(warningTableSumMismatch) {
                    warnings.append(warningTableSumMismatch)
                }
            }
        }
        if built.isEmpty {
            audit.sourceTableIndex = table.tableIndex
            audit.periodColumn = column.key
            audit.unit = scale.headerToken ?? table.unitCaption ?? ""
            stampJev(&audit, applied: false, needsReview: true)
            return (BreakdownSnapshot(
                axis: "business",
                denominator: denominator,
                denominatorTag: resolvedDenomTag,
                rows: [],
                sourceKind: "revenue_recognition",
                needsReview: true,
                warnings: warnings
            ), audit)
        }

        var rows: [BreakdownRow] = []
        for row in built {
            let yen = row.amount * multiplier
            let label = RevenueRecognitionCandidates.displayLabel(
                categoryGroup: row.categoryGroup, category: row.category)
            rows.append(BreakdownRow(
                labelRaw: row.category ?? row.categoryGroup,
                label: label,
                amount: yen,
                share: yen / denominator,
                profit: nil,
                rowKind: row.rowKind,
                categoryGroup: row.categoryGroup,
                category: row.category
            ))
        }
        let segments = rows.filter { $0.rowKind == "segment" }
        let emitted = segments.reduce(0.0) { $0 + $1.amount }
        if isPubliclyInsufficientRevenueRecognition(
            segmentCount: segments.count, emittedSum: emitted)
        {
            needsReview = true
            if segments.count <= 1, !warnings.contains(warningSingleRowTable) {
                warnings.append(warningSingleRowTable)
            }
            if emitted == 0, !warnings.contains(warningZeroEmittedSum) {
                warnings.append(warningZeroEmittedSum)
            }
        }
        if !rows.isEmpty, !hasRecognizedOtherRevenue(table) {
            if abs(denominator) > 0, emitted / abs(denominator) < coverageFloor {
                needsReview = true
                if !warnings.contains(warningDenominatorUndercoverage) {
                    warnings.append(warningDenominatorUndercoverage)
                }
            }
        }

        SegmentInfoPublishGuards.apply(
            rows: rows, allTables: parsed, selectedTable: table, selectedColumn: column,
            fiscalYearEnd: fiscalYearEnd, needsReview: &needsReview, warnings: &warnings)

        audit.sourceTableIndex = table.tableIndex
        audit.periodColumn = column.key
        audit.unit = scale.headerToken ?? table.unitCaption ?? ""
        stampJev(&audit, applied: !belowThreshold, needsReview: needsReview)

        let snapshot = BreakdownSnapshot(
            axis: "business",
            denominator: denominator,
            denominatorTag: resolvedDenomTag,
            rows: rows,
            sourceKind: "revenue_recognition",
            needsReview: needsReview,
            warnings: warnings
        )
        return (snapshot, audit)
    }

    struct ResolvedColumn {
        var key: String
        var forceReview: Bool
    }

    /// none_of_these は confidence ≥ 0.5 かつ p_none ≥ 0.75 のときだけ採用する。
    /// それ以外は最良の実列へ落とし needs_review（1436 / 4431 / 5247 / 7050 の誤省略）。
    static func resolveSelection(
        _ choice: RevenueRecognitionColumnChoice,
        columns: [RevenueRecognitionCandidates.AmountColumn]
    ) -> ResolvedColumn? {
        guard let selected = choice.selected else { return nil }
        if selected != noneOfThese {
            return ResolvedColumn(key: selected, forceReview: false)
        }
        let confidence = choice.confidence ?? 0
        let pNone = choice.pNone ?? 0
        if confidence >= noneOfTheseMinConfidence && pNone >= noneOfTheseMinPNone {
            return nil
        }
        guard let fallback = bestRealColumn(choice, columns: columns) else { return nil }
        return ResolvedColumn(key: fallback, forceReview: true)
    }

    static func bestRealColumn(
        _ choice: RevenueRecognitionColumnChoice,
        columns: [RevenueRecognitionCandidates.AmountColumn]
    ) -> String? {
        let keys = Set(columns.map(\.key))
        let real = choice.options.filter { $0 != noneOfThese && keys.contains($0) }
        if let best = real.max(by: { (choice.probabilities[$0] ?? 0) < (choice.probabilities[$1] ?? 0) }) {
            return best
        }
        return columns.first?.key
    }

    static func offeredColumns(
        _ columns: [RevenueRecognitionCandidates.AmountColumn],
        tables: [RevenueRecognitionCandidates.ParsedTable],
        constraint: RevenueRecognitionTableStructure.AxisConstraint
    ) -> [RevenueRecognitionCandidates.AmountColumn] {
        var scoped = columns
        if constraint == .productOnly {
            let productTables = Set(
                tables.filter {
                    RevenueRecognitionTableStructure.tableAxis(of: $0) == .productOrBusiness
                }.map(\.tableIndex))
            let filtered = columns.filter { productTables.contains($0.tableIndex) }
            if !filtered.isEmpty { scoped = filtered }
        }
        let byIndex = Dictionary(uniqueKeysWithValues: tables.map { ($0.tableIndex, $0) })
        let current = scoped.filter { column in
            guard let table = byIndex[column.tableIndex] else { return true }
            return !isPriorOnlyColumn(column, table: table)
        }
        return current.isEmpty ? scoped : current
    }

    static func preferProductAxis(
        _ resolved: ResolvedColumn?,
        columns: [RevenueRecognitionCandidates.AmountColumn],
        tables: [RevenueRecognitionCandidates.ParsedTable],
        constraint: RevenueRecognitionTableStructure.AxisConstraint
    ) -> ResolvedColumn? {
        guard constraint == .productOnly, let resolved else { return resolved }
        let byIndex = Dictionary(uniqueKeysWithValues: tables.map { ($0.tableIndex, $0) })
        if let column = columns.first(where: { $0.key == resolved.key }),
           let table = byIndex[column.tableIndex],
           RevenueRecognitionTableStructure.tableAxis(of: table) == .productOrBusiness
        {
            return resolved
        }
        guard let fallback = currentProductColumn(columns, tables: tables) ?? columns.first else {
            return resolved
        }
        return ResolvedColumn(key: fallback.key, forceReview: false)
    }

    static func currentProductColumn(
        _ columns: [RevenueRecognitionCandidates.AmountColumn],
        tables: [RevenueRecognitionCandidates.ParsedTable]
    ) -> RevenueRecognitionCandidates.AmountColumn? {
        let byIndex = Dictionary(uniqueKeysWithValues: tables.map { ($0.tableIndex, $0) })
        return columns.first { column in
            guard let table = byIndex[column.tableIndex] else { return false }
            return !isPriorOnlyColumn(column, table: table)
        }
    }

    static func isPriorOnlyColumn(
        _ column: RevenueRecognitionCandidates.AmountColumn,
        table: RevenueRecognitionCandidates.ParsedTable
    ) -> Bool {
        if table.period == "前期" { return true }
        let caption = column.caption ?? table.precedingCaption ?? ""
        let headerCells = table.grid.prefix(table.headerRowCount).compactMap { row -> String? in
            guard column.column < row.count else { return nil }
            let text = RevenueRecognitionCandidates.compactCell(row[column.column])
            return text.isEmpty ? nil : text
        }
        let blob = caption + column.header + headerCells.joined()
        let hasPrior = blob.contains("前連結会計年度") || blob.contains("前事業年度")
            || blob.contains("前期")
        let hasCurrent = blob.contains("当連結会計年度") || blob.contains("当事業年度")
            || blob.contains("当期") || column.header.contains("当")
            || headerCells.contains(where: { $0.contains("当") && !$0.contains("前") })
        if hasPrior && !hasCurrent { return true }
        let headerEra = SegmentInfoPublishGuards.eraNumber(in: column.header)
            ?? headerCells.compactMap { SegmentInfoPublishGuards.eraNumber(in: $0) }.first
            ?? SegmentInfoPublishGuards.eraNumber(in: caption)
        let siblingEras = table.columnHeaders.values.compactMap {
            SegmentInfoPublishGuards.eraNumber(in: $0)
        } + table.grid.prefix(table.headerRowCount).flatMap { row in
            row.compactMap { SegmentInfoPublishGuards.eraNumber(in: $0) }
        }
        if let headerEra, let maxEra = siblingEras.max(), headerEra < maxEra {
            return true
        }
        return false
    }

    /// 免除は明細のカテゴリ行だけ。合計行やグリッドに「その他の収益（注）」があっても
    /// 付随収入 1 行だけではカバー不足を止めない（6620 本番表）。
    static func hasRecognizedOtherRevenue(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> Bool {
        func hit(_ text: String) -> Bool {
            recognizedOtherRevenueMarkers.contains { text.contains($0) }
        }
        return table.items.contains { hit($0.label) || hit($0.group) }
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

struct OpenRouterRevenueRecognitionColumnDecider: RevenueRecognitionColumnDeciding {
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
            printError("RevenueRecognitionColumnNormalizer: Jev呼び出し失敗: \(error)\n")
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
            "No column holds current-fiscal-year whole-company amounts. Do not use this when the only reportable-segment column is the whole company."
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
            The state lists the 顧客との契約から生じる収益を分解した情報 (disaggregation of revenue) \
            table(s) from the 収益認識関係 note of a Japanese annual securities report \
            (有価証券報告書) for the fiscal year ending \(fy). Which single column holds the \
            CURRENT fiscal year (当連結会計年度 / 当事業年度, the year ending \(fy)) amounts \
            for the whole company? The period can be stated in the caption printed above a \
            table or in the column header. Columns or tables for the prior fiscal year \
            (前連結会計年度 / 前事業年度) are wrong. If the table splits amounts into several \
            reportable-segment columns (e.g. 国内事業 / 北米事業 / アジア事業), choose that \
            table's 合計 (total) column, not one of those segment columns. If there is only \
            one reportable-segment column because the company's business is a single \
            reportable segment (that column is the whole company), that column is a valid \
            answer; do not choose none_of_these.
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
