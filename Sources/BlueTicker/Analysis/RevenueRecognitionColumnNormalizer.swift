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

        let choice = await decider.chooseColumn(
            columns: columns, tables: parsed, fiscalYearEnd: fiscalYearEnd, docID: docID)
        let resolved = resolveSelection(choice, columns: columns)
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
        let tableSumReview = transposedWholeCompany == nil
            && RevenueRecognitionCandidates.tableSumMismatch(
                rows: built, table: table, column: column.column)

        let scale = BreakdownLLMAmountScale.scaling(
            declaredUnit: "other",
            tables: result.tables,
            sourceTableIndex: table.tableIndex,
            rawAmounts: built.isEmpty ? [tableTotal?.amount].compactMap { $0 } : built.map(\.amount),
            consolidatedSales: consolidatedSales
        )
        var warnings: [String] = []
        var needsReview = belowThreshold || groupSumReview || tableSumReview
            || resolved.forceReview || built.isEmpty || parallelUnresolved
        if belowThreshold { warnings.append(warningLowConfidence) }
        if resolved.forceReview { warnings.append(warningNoneOfTheseOverridden) }
        if groupSumReview && !parallelUnresolved { warnings.append(warningGroupSumMismatch) }
        if tableSumReview { warnings.append(warningTableSumMismatch) }
        if parallelUnresolved { warnings.append(warningParallelDimensions) }
        if built.isEmpty { warnings.append(warningNoCategoryRows) }
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
