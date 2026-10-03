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
    var model: String
    var options: [String]
}

enum RevenueRecognitionColumnNormalizer {
    /// 272A S100YSCR の実測正解 confidence は 0.75（見出し行が無く期間は表上キャプションのみ）。
    /// それより下に置き、同様の無見出し表を通しつつ、当て推量の列選択は needs_review にする。
    static let confidenceThreshold: Double = 0.6

    static let noneOfThese = "none_of_these"
    static let question = "col"
    static let warningLowConfidence = "jev_column_confidence_below_threshold"
    static let warningGroupSumMismatch = "revenue_recognition_group_sum_mismatch"

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
        let jev = SegmentNoteJevAuditPayload(
            code: "", docID: docID, axis: breakdownAxisBusiness,
            model: choice.model, threshold: confidenceThreshold,
            applied: false, needsReview: false, sentences: [],
            calls: [
                SegmentNoteJevCallPayload(
                    question: question,
                    options: choice.options,
                    selected: choice.selected,
                    probability: choice.confidence,
                    sentences: [],
                    applied: false)
            ])
        var audit = LLMBreakdownAudit(
            sourceTableIndex: nil, periodColumn: choice.selected, unit: "",
            profitDisclosed: false,
            notes: "jev_column=\(choice.selected ?? "nil") confidence=\(choice.confidence.map { String($0) } ?? "nil")",
            jev: jev)

        guard let selected = choice.selected, selected != noneOfThese else {
            return (nil, audit)
        }
        guard let column = columns.first(where: { $0.key == selected }),
              let table = parsed.first(where: { $0.tableIndex == column.tableIndex })
        else { return (nil, audit) }

        let confidence = choice.confidence
        let belowThreshold = confidence.map { $0 < confidenceThreshold } ?? true
        var (built, groupSumReview) = RevenueRecognitionCandidates.buildRows(
            table: table, column: column.column)
        var transposedWholeCompany: Double?
        if built.isEmpty {
            let transposed = RevenueRecognitionCandidates.transposeMetricRow(
                table: table, wholeCompanyColumn: column.column)
            built = transposed.rows
            transposedWholeCompany = transposed.wholeCompanyAmount
            groupSumReview = false
        }
        guard !built.isEmpty else { return (nil, audit) }

        let scale = BreakdownLLMAmountScale.scaling(
            declaredUnit: "other",
            tables: result.tables,
            sourceTableIndex: table.tableIndex,
            rawAmounts: built.map(\.amount),
            consolidatedSales: consolidatedSales
        )
        var warnings: [String] = []
        var needsReview = belowThreshold || groupSumReview
        if belowThreshold { warnings.append(warningLowConfidence) }
        if groupSumReview { warnings.append(warningGroupSumMismatch) }
        BreakdownLLMAmountScale.applyPublicFlags(
            scale, needsReview: &needsReview, warnings: &warnings)
        let multiplier = scale.multiplier

        let tableTotal = RevenueRecognitionCandidates.tableTotal(
            table: table, column: column.column)
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
        if var jev = audit.jev {
            jev.applied = !belowThreshold
            jev.needsReview = needsReview
            if !jev.calls.isEmpty {
                jev.calls[0].applied = !belowThreshold
            }
            audit.jev = jev
        }

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
            let selected = choice?.selected
            let fromProbabilities = selected.flatMap { choice?.probabilities[$0] }
            return RevenueRecognitionColumnChoice(
                selected: selected,
                confidence: choice?.confidence ?? fromProbabilities,
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
            "No column holds current-fiscal-year whole-company amounts"
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
            (前連結会計年度 / 前事業年度) are wrong. If the table splits amounts into \
            reportable-segment columns (e.g. 国内事業 / 北米事業 / アジア事業), choose that \
            table's 合計 (total) column, not a single segment column.
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
