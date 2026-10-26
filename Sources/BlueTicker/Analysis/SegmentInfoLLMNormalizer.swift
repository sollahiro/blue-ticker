// `segments` キー自体が html_table を返すケース（キヤノン US-GAAP 注23、事業が列・指標が行）
// を、決定論の表構造チェック + Jev の列・行選択で BreakdownSnapshot（axis:"product_service"）へ正規化する。
// Chat Completions は使わない。地域別も同じ Jev 列選択（`GeographyBreakdownLLMNormalizer`）。
// 表構造は収益認識と同じ 4 段（ラベル列、group/category、subtotal/segment、同じ合計の並行ブロック）。
// docs/breakdown.md

import Foundation

struct SegmentInfoMetricRow: Equatable, Sendable {
    var key: String
    var tableIndex: Int
    var row: Int
    var label: String
}

struct SegmentInfoChoice: Equatable, Sendable {
    var column: RevenueRecognitionColumnChoice
    var salesRow: RevenueRecognitionColumnChoice?
    var profitRow: RevenueRecognitionColumnChoice?
}

protocol SegmentInfoDeciding: Sendable {
    func choose(
        columns: [RevenueRecognitionCandidates.AmountColumn],
        metricRows: [SegmentInfoMetricRow],
        tables: [RevenueRecognitionCandidates.ParsedTable],
        fiscalYearEnd: String?,
        docID: String
    ) async -> SegmentInfoChoice
}

/// 列選択だけを持つ Jev（収益認識と同じ `Fake` / OpenRouter 列デサイダ）を、
/// 売上・利益行は決定論の優先ラベルで埋めてセグメント情報に渡す。
struct SegmentInfoDeciderFromColumnDecider: SegmentInfoDeciding {
    let columnDecider: any RevenueRecognitionColumnDeciding

    func choose(
        columns: [RevenueRecognitionCandidates.AmountColumn],
        metricRows: [SegmentInfoMetricRow],
        tables: [RevenueRecognitionCandidates.ParsedTable],
        fiscalYearEnd: String?,
        docID: String
    ) async -> SegmentInfoChoice {
        let column = await columnDecider.chooseColumn(
            columns: columns, tables: tables, fiscalYearEnd: fiscalYearEnd, docID: docID)
        return SegmentInfoLLMNormalizer.choiceByFillingMetricRows(
            column: column, metricRows: metricRows, fiscalYearEnd: fiscalYearEnd)
    }
}

enum SegmentInfoLLMNormalizer {
    static let salesRowQuestion = "sales_row"
    static let profitRowQuestion = "profit_row"
    static let warningLowConfidence = RevenueRecognitionColumnNormalizer.warningLowConfidence
    static let warningNoneOfTheseOverridden =
        RevenueRecognitionColumnNormalizer.warningNoneOfTheseOverridden
    static let warningParallelDimensions =
        RevenueRecognitionColumnNormalizer.warningParallelDimensions
    /// 旧: 地域のみの報告セグメントを business に載せるときの warning。
    /// 現行: その形は `not_applicable` / `geography_only`。公開経路には使わない。
    static let warningGeographyTaken = "segment_info_geography_only_taken"
    static let warningSingleSegment = "segment_info_single_segment_disclosed"

    /// 分母整合性チェックの許容範囲。他の LLM 正規化器と同じ許容幅を使う。
    private static let denominatorTolerance = 0.90...1.10

    static let salesRowPreferred = [
        "外部顧客向け", "外部顧客に対する売上高", "外部顧客への売上高", "外部顧客への収益",
        "外部顧客への売上収益", "外部顧客に対するもの",
        "外部顧客からの売上収益", "外部顧客からの売上高", "外部顧客からの収益",
        "外部顧客に対する経常収益", "外部顧客への経常収益",
        "顧客との契約から生じる収益", "顧客との契約から認識した収益",
        "セグメント収益", "セグメント売上高",
        "実質業務粗利益", "連結粗利益", "業務粗利益", "経常収益",
    ]

    static let profitRowPreferred = [
        "営業利益", "セグメント利益", "実質業務純益",
    ]

    static func normalize(
        _ result: ExtractedBreakdown,
        consolidatedSales: Double?,
        decider: any SegmentInfoDeciding,
        fiscalYearEnd: String?,
        docID: String,
        salesDenominatorTag: String? = nil,
        publishedAxis: String = breakdownAxisProductService
    ) async -> (snapshot: BreakdownSnapshot?, audit: LLMBreakdownAudit?) {
        guard !result.tables.isEmpty else { return (nil, nil) }
        let parsed = RevenueRecognitionCandidates.parse(
            tables: mergingSplitSegmentMatrices(
                result.tables.map { collapsingSegmentBlocks(rebasingStackedExternalBlocks($0)) }))
        let columns = RevenueRecognitionCandidates.amountColumns(in: parsed)
        guard !columns.isEmpty else { return (nil, nil) }

        let scopedTables = dropPriorEraTables(
            preferredTables(parsed, axis: publishedAxis), among: parsed, fiscalYearEnd: fiscalYearEnd)
        let scopedColumns = columns.filter { column in
            scopedTables.contains { $0.tableIndex == column.tableIndex }
        }
        let tablesForChoice = scopedTables.isEmpty ? parsed : scopedTables
        let columnsForChoice = scopedColumns.isEmpty ? columns : scopedColumns
        let constraint = RevenueRecognitionTableStructure.axisConstraint(tables: tablesForChoice)
        // 報告セグメントが地域のみで、使える製品・事業表が無い（製品90％省略の文は製品表ではない）。
        // 製品表は preferredTables が先に残す。日本事業などの事業ユニットは対象外。
        // business に日本/アジアを載せない。地域は geography 軸。
        // `segment` 軸では報告セグメント表そのものを残す（地理軸でも product_service に載せない）。
        if constraint == .geographyOnly, publishedAxis != breakdownAxisSegment {
            var audit = LLMBreakdownAudit(
                sourceTableIndex: nil, periodColumn: nil, unit: "",
                profitDisclosed: false, notes: "axis_constraint=geography_only")
            audit.notApplicableReason = BusinessBreakdownNotApplicableReason.geographyOnly.rawValue
            return (nil, audit)
        }
        let offered = RevenueRecognitionColumnNormalizer.offeredColumns(
            columnsForChoice, tables: tablesForChoice, constraint: constraint)
        let offeredTables = tablesForChoice.filter { table in
            offered.contains { $0.tableIndex == table.tableIndex }
        }
        let metricRows = offeredTables.flatMap(metricRows(in:))
        let choiceSamples = await JevDecisionSampler.collect(
            count: RevenueRecognitionColumnNormalizer.jevPolicy.sampling.sampleCount
        ) {
            await decider.choose(
                columns: offered, metricRows: metricRows, tables: offeredTables,
                fiscalYearEnd: fiscalYearEnd, docID: docID)
        }
        let columnAggregate = JevChoiceAggregate.combine(
            choiceSamples.map { JevChoiceAggregate.fromColumn($0.column) })
        let columnChoice = JevChoiceAggregate.columnChoice(from: columnAggregate)
        let filledMetrics = choiceByFillingMetricRows(
            column: columnChoice, metricRows: metricRows, fiscalYearEnd: fiscalYearEnd)
        let choice = SegmentInfoChoice(
            column: columnChoice,
            salesRow: consensusMetricRow(choiceSamples.map(\.salesRow)) ?? filledMetrics.salesRow,
            profitRow: consensusMetricRow(choiceSamples.map(\.profitRow)) ?? filledMetrics.profitRow)
        var resolved = RevenueRecognitionColumnNormalizer.resolveSelection(
            choice.column, columns: offered)
        resolved = RevenueRecognitionColumnNormalizer.preferProductAxis(
            resolved, columns: offered, tables: tablesForChoice, constraint: constraint)

        let columnJev = jevPayload(
            docID: docID, samples: choiceSamples.map(\.column), aggregate: columnAggregate,
            resolved: resolved)
        let pNoneNote = choice.column.pNone.map { String($0) } ?? "nil"
        let medianNote = columnAggregate.probability.map { String($0) } ?? "nil"
        var notes =
            "jev_column=\(choice.column.selected ?? "nil") samples=\(choiceSamples.count) \(columnAggregate.outcome.rawValue) median=\(medianNote) p_none=\(pNoneNote)"
        if let resolved, resolved.forceReview {
            notes += " overridden=\(resolved.key)"
        }
        if let sales = choice.salesRow?.selected {
            notes += " sales_row=\(sales)"
        }
        if let profit = choice.profitRow?.selected {
            notes += " profit_row=\(profit)"
        }
        var audit = LLMBreakdownAudit(
            sourceTableIndex: nil, periodColumn: resolved?.key ?? choice.column.selected, unit: "",
            profitDisclosed: false, notes: notes, jev: columnJev, columnJev: columnJev)

        guard let resolved else { return (nil, audit) }
        guard let selectedColumn = columns.first(where: { $0.key == resolved.key }),
              let selectedTable = parsed.first(where: { $0.tableIndex == selectedColumn.tableIndex })
        else { return (nil, audit) }
        var column = selectedColumn
        var table = selectedTable
        let assembled = assembleRowsRecoveringOtherTables(
            selectedTable: table, selectedColumn: column, choice: choice,
            parsed: parsed, columns: columns, fiscalYearEnd: fiscalYearEnd)
        table = assembled.table
        column = assembled.column
        let built = assembled.built
        let profits = assembled.profits
        let groupSumReview = assembled.groupSumReview
        let parallelUnresolved = assembled.parallelUnresolved
        let transposedWhole = assembled.transposedWhole
        if assembled.recovered {
            notes += " recovered_table=\(table.tableIndex)"
            audit.notes = notes
        }
        if isSingleSegmentDisclosure(constraint: constraint, table: table) {
            audit.notApplicableReason = breakdownNotApplicableSingleSegmentDisclosed
            stampJev(&audit, applied: true, needsReview: false)
            return (nil, audit)
        }
        if built.isEmpty {
            return (nil, audit)
        }

        let belowThreshold = (choice.column.confidence ?? 0) < RevenueRecognitionColumnNormalizer
            .confidenceThreshold
        let columnUncertain = !columnAggregate.isConfident
        var warnings: [String] = []
        var needsReview = belowThreshold || columnUncertain || groupSumReview
            || resolved.forceReview || parallelUnresolved
        if belowThreshold { warnings.append(warningLowConfidence) }
        switch columnAggregate.outcome {
        case .disagreement:
            warnings.append(JevDecision.warningSampleDisagreement)
        case .insufficient:
            warnings.append(JevDecision.warningSampleInsufficient)
        case .allFailed, .agreed:
            break
        }
        if resolved.forceReview { warnings.append(warningNoneOfTheseOverridden) }
        if parallelUnresolved { warnings.append(warningParallelDimensions) }

        let tableTotalAmount = RevenueRecognitionCandidates.tableTotal(
            table: table, column: column.column)?.amount
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
            sourceTableIndex: table.tableIndex,
            rawAmounts: built.isEmpty ? [transposedWhole].compactMap { $0 } : built.map(\.amount),
            consolidatedSales: consolidatedSales
        )
        BreakdownLLMAmountScale.applyPublicFlags(
            scale, needsReview: &needsReview, warnings: &warnings)
        let multiplier = scale.multiplier

        let denominator: Double
        let resolvedDenomTag: String
        if let transposedWhole, transposedWhole != 0 {
            denominator = transposedWhole * multiplier
            resolvedDenomTag = salesDenominatorTag ?? "llm_table_subtotal"
        } else if let tableTotal = RevenueRecognitionCandidates.tableTotal(
            table: table, column: column.column)
        {
            denominator = tableTotal.amount * multiplier
            resolvedDenomTag = salesDenominatorTag ?? "llm_table_subtotal"
        } else if let consolidatedSales, consolidatedSales != 0 {
            denominator = consolidatedSales
            resolvedDenomTag = salesDenominatorTag ?? "income_statement.sales"
        } else {
            return (nil, audit)
        }
        guard denominator != 0 else { return (nil, audit) }

        var denom = denominator
        var denomTag = resolvedDenomTag
        let rows = finalizeRows(
            built: built, profits: profits, multiplier: multiplier,
            consolidatedSales: consolidatedSales, initialDenominator: denominator,
            initialDenomTag: resolvedDenomTag,
            needsReview: &needsReview, warnings: &warnings,
            denominator: &denom, denominatorTag: &denomTag)

        let profitDisclosed = rows.contains { $0.rowKind == "segment" && $0.profit != nil }
        flagGeographyLabels(rows, needsReview: &needsReview, warnings: &warnings)
        SegmentInfoPublishGuards.apply(
            rows: rows, allTables: parsed, selectedTable: table, selectedColumn: column,
            fiscalYearEnd: fiscalYearEnd, needsReview: &needsReview, warnings: &warnings)

        audit.sourceTableIndex = table.tableIndex
        audit.periodColumn = column.key
        audit.unit = scale.headerToken ?? table.unitCaption ?? ""
        audit.profitDisclosed = profitDisclosed
        stampJev(
            &audit, applied: !belowThreshold && columnAggregate.isConfident,
            needsReview: needsReview)

        let snapshot = BreakdownSnapshot(
            axis: publishedAxis,
            denominator: denom,
            denominatorTag: denomTag,
            rows: rows,
            sourceKind: "segment_info",
            needsReview: needsReview,
            warnings: warnings
        )
        return (snapshot, audit)
    }

    static func choiceByFillingMetricRows(
        column: RevenueRecognitionColumnChoice,
        metricRows: [SegmentInfoMetricRow],
        fiscalYearEnd: String? = nil
    ) -> SegmentInfoChoice {
        let sales = preferredSalesRow(in: metricRows, fiscalYearEnd: fiscalYearEnd)
        let profit = preferredProfitRow(in: metricRows)
        func asChoice(_ row: SegmentInfoMetricRow?) -> RevenueRecognitionColumnChoice? {
            guard let row else { return nil }
            return RevenueRecognitionColumnChoice(
                selected: row.key, confidence: column.confidence, pNone: 0,
                probabilities: [row.key: column.confidence ?? 0],
                model: column.model, options: metricRows.map(\.key) + [RevenueRecognitionColumnNormalizer.noneOfThese])
        }
        return SegmentInfoChoice(
            column: column, salesRow: asChoice(sales), profitRow: asChoice(profit))
    }

    static func metricRows(
        in table: RevenueRecognitionCandidates.ParsedTable
    ) -> [SegmentInfoMetricRow] {
        let fromStructure = table.structure.rows.compactMap { classified -> SegmentInfoMetricRow? in
            guard classified.hasAmount else { return nil }
            let label = classified.category ?? classified.categoryGroup ?? ""
            let compact = RevenueRecognitionCandidates.compactCell(label)
            guard !compact.isEmpty else { return nil }
            guard isMetricRowLabel(compact) else { return nil }
            return SegmentInfoMetricRow(
                key: "t\(table.tableIndex)_r\(classified.index)",
                tableIndex: table.tableIndex, row: classified.index, label: compact)
        }
        if !fromStructure.isEmpty { return fromStructure }
        return periodAmountRows(in: table)
    }

    /// 列が製品・事業、行が当連結会計年度／前連結会計年度のマトリクス（エーザイ製品別）。
    /// 構造分類は期間行を飛ばすので、グリッドから当期行を指標として拾う。
    static func periodAmountRows(
        in table: RevenueRecognitionCandidates.ParsedTable
    ) -> [SegmentInfoMetricRow] {
        var rows: [SegmentInfoMetricRow] = []
        for (index, row) in table.grid.enumerated() where index >= table.headerRowCount {
            let label = RevenueRecognitionCandidates.compactCell(row.first ?? "")
            guard RevenueRecognitionCandidates.isPeriodHeadingLabel(label) else { continue }
            let hasAmount = row.dropFirst().contains { RevenueRecognitionCandidates.isAmountCell($0) }
            guard hasAmount else { continue }
            rows.append(SegmentInfoMetricRow(
                key: "t\(table.tableIndex)_r\(index)",
                tableIndex: table.tableIndex, row: index, label: label))
        }
        return rows
    }

    static func preferredSalesRow(
        in rows: [SegmentInfoMetricRow], fiscalYearEnd: String? = nil
    ) -> SegmentInfoMetricRow? {
        for marker in salesRowPreferred {
            if let hit = rows.first(where: { isSalesLabel($0.label, marker: marker) }) {
                return hit
            }
        }
        if let current = rows.first(where: {
            isCurrentPeriodRowLabel($0, among: rows, fiscalYearEnd: fiscalYearEnd)
        }) {
            return current
        }
        if let revenue = rows.first(where: { isBareRevenueSalesLabel($0.label) }) {
            return revenue
        }
        return rows.first { isGenericSalesLabel($0.label) }
    }

    static func isCurrentPeriodRowLabel(_ row: SegmentInfoMetricRow) -> Bool {
        isCurrentPeriodRowLabel(row, among: [], fiscalYearEnd: nil)
    }

    static func isCurrentPeriodRowLabel(
        _ row: SegmentInfoMetricRow,
        among rows: [SegmentInfoMetricRow],
        fiscalYearEnd: String?
    ) -> Bool {
        let label = row.label
        if label.contains("前連結会計年度") || label.contains("前事業年度") {
            return false
        }
        if RevenueRecognitionCandidates.isPeriodHeadingLabel(label)
            && (label.contains("当連結会計年度") || label.contains("当事業年度")
                || label.contains("当年度") || label.contains("当期"))
        {
            return true
        }
        if let fyYear = fiscalYearEnd.flatMap({ Int($0.prefix(4)) }) {
            let years = SegmentInfoPublishGuards.years(in: label)
            if years.contains(fyYear) { return true }
        }
        if let era = SegmentInfoPublishGuards.eraNumber(in: label) {
            let siblingEras = rows.compactMap { SegmentInfoPublishGuards.eraNumber(in: $0.label) }
            if let maxEra = siblingEras.max(), era == maxEra, siblingEras.contains(where: { $0 < era }) {
                return true
            }
        }
        return false
    }

    static func preferredProfitRow(in rows: [SegmentInfoMetricRow]) -> SegmentInfoMetricRow? {
        for marker in profitRowPreferred {
            if let hit = rows.first(where: { $0.label.contains(marker) }) {
                return hit
            }
        }
        return nil
    }

    /// 列が事業・製品、行が売上高・営業利益などの指標マトリクス（キヤノン注23）。
    static func isSegmentColumnMatrix(_ table: RevenueRecognitionCandidates.ParsedTable) -> Bool {
        let named = table.columnHeaders.filter { _, header in
            let compact = RevenueRecognitionCandidates.compactCell(header)
            return !compact.isEmpty
                && !RevenueRecognitionCandidates.isPeriodHeadingLabel(compact)
                && !isPeriodColumnHeader(compact)
        }
        let segmentLike = named.filter { _, header in
            !isSkippedTotalColumn(header) && !isAmountUnitHeader(header)
        }
        guard segmentLike.count >= 2 else { return false }
        return !metricRows(in: table).isEmpty
    }

    /// 「金額（百万円）」「（単位：百万円）」は単位だけの列見出しで、セグメント名ではない。
    static func isAmountUnitHeader(_ header: String) -> Bool {
        let leaf = headerLeaf(header)
        if RevenueRecognitionCandidates.isUnitCaptionHeader(leaf) { return true }
        guard BreakdownExtractor.parseUnitCaption(RevenueRecognitionCandidates.compactCell(leaf)) != nil
        else { return false }
        return RevenueRecognitionCandidates.unitCaptionRemainder(leaf) == "金額"
    }

    static func isPeriodColumnHeader(_ header: String) -> Bool {
        let compact = RevenueRecognitionCandidates.compactCell(header)
        if compact.contains("当連結会計年度") || compact.contains("前連結会計年度")
            || compact.contains("当事業年度") || compact.contains("前事業年度")
        {
            return true
        }
        return compact == "当期" || compact == "前期" || compact == "当年度" || compact == "前年度"
            || RevenueRecognitionCandidates.isPeriodHeadingLabel(compact)
    }

    static func dropPriorEraTables(
        _ tables: [RevenueRecognitionCandidates.ParsedTable],
        among all: [RevenueRecognitionCandidates.ParsedTable],
        fiscalYearEnd: String?
    ) -> [RevenueRecognitionCandidates.ParsedTable] {
        let pool = tables.isEmpty ? all : tables
        let current = pool.filter {
            !SegmentInfoPublishGuards.isPriorEraTable($0, among: pool, fiscalYearEnd: fiscalYearEnd)
        }
        return current.isEmpty ? pool : current
    }

    /// 「その他（消去分を含む）」「その他及び全社」は残事業バケットなので合計列にしない。
    /// 結合見出しは葉だけ見る（「みずほFG（連結） / リテール」の連結で全列スキップしない）。
    static func isSkippedTotalColumn(_ header: String) -> Bool {
        let leaf = headerLeaf(header)
        if leaf.contains("その他") && (leaf.contains("消去分を含む") || leaf.contains("全社")) {
            return false
        }
        return RevenueRecognitionCandidates.isAggregateColumnHeader(leaf)
    }

    /// 転置表の「消去」「調整額」「調整・消去」「連結消去」「その他の調整額」の列。
    /// 合計・計・連結財務諸表計上額の列は含めない。行の種別と同じく「その他（消去分を含む）」
    /// 「その他及び全社」は残事業バケット（`resolvedRowKind`）なので対象外。
    static func isReconcilingColumnHeader(_ header: String) -> Bool {
        let leaf = RevenueRecognitionCandidates.collapsedCell(headerLeaf(header))
        guard leaf.contains("消去") || leaf.contains("調整") else { return false }
        guard resolvedRowKind(label: leaf, rowKind: "reconciling") == "reconciling" else { return false }
        return !(leaf.contains("合計") || leaf.contains("計上") || leaf.contains("財務諸表")
            || leaf.hasSuffix("計"))
    }

    static func headerLeaf(_ header: String) -> String {
        let compact = RevenueRecognitionCandidates.compactCell(header)
        let parts = compact.components(separatedBy: " / ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.last ?? compact
    }

    static func isMetricRowLabel(_ label: String) -> Bool {
        isGenericSalesLabel(label) || isProfitMetricLabel(label)
            || label.contains("売上原価") || label.contains("売上総利益")
            || label.contains("研究開発") || label.contains("総資産")
            || label.contains("減価償却") || label.contains("資本的支出")
            || label.contains("営業費用") || label.contains("営業外")
            || label.contains("セグメント間") || label.contains("セグメント資産")
            || label.contains("金融収益")
    }

    static func isGenericSalesLabel(_ label: String) -> Bool {
        let stripped = stripLeadingEnumeration(label)
        if stripped.contains("売上原価") || stripped.contains("売上総利益") { return false }
        if stripped.contains("セグメント間") { return false }
        if salesRowPreferred.contains(where: { isSalesLabel(stripped, marker: $0) }) { return true }
        if isBareRevenueSalesLabel(stripped) { return true }
        return stripped == "売上高" || stripped.hasPrefix("売上高")
    }

    /// 4324 の「収益(注)１」など、売上行マーカーが「収益」だけの注記付きラベル。
    /// `収益認識` や `その他の源泉から認識した収益` は採らない。
    static func isBareRevenueSalesLabel(_ label: String) -> Bool {
        let stripped = stripLeadingEnumeration(label)
        if stripped == "収益" { return true }
        return stripped.hasPrefix("収益(") || stripped.hasPrefix("収益（")
    }

    static func isSalesLabel(_ label: String, marker: String) -> Bool {
        let stripped = stripLeadingEnumeration(label)
        return stripped == marker || stripped.hasPrefix(marker)
            || label == marker || label.hasPrefix(marker)
    }

    /// `(1) 外部顧客に対する売上高` の番号を落として売上行マーカーと照合する。
    static func stripLeadingEnumeration(_ label: String) -> String {
        var compact = RevenueRecognitionCandidates.compactCell(label)
        // 丸数字（オムロン S100LLFL の「①外部顧客に対する売上高」）。
        if let first = compact.unicodeScalars.first, (0x2460...0x2473).contains(first.value) {
            compact = String(compact.unicodeScalars.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let first = compact.first, first == "(" || first == "（" else {
            return compact
        }
        guard let close = compact.firstIndex(where: { $0 == ")" || $0 == "）" }) else {
            return compact
        }
        return compact[compact.index(after: close)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isProfitMetricLabel(_ label: String) -> Bool {
        if label.contains("研究開発") { return false }
        return profitRowPreferred.contains { label.contains($0) }
            || label.contains("税引前当期純利益")
            || label.contains("セグメント損失") || label.contains("営業損失")
    }

    /// ヘッダー単位が無い表（キヤノン注23 の smoke 抽出など）は、表合計と連結売上の比が
    /// 円 / 千円 / 百万円の一方だけに入るときだけその単位を使う。複数・どれでもなければ
    /// `other` のまま fail closed（推測百万円は掛けない）。
    static func inferredDeclaredUnit(
        tableTotal: Double?,
        consolidatedSales: Double?
    ) -> String {
        AmountUnit.inferredLlmDeclaredUnit(
            tableTotal: tableTotal, consolidatedSales: consolidatedSales, tolerance: denominatorTolerance)
    }

    static func isSingleSegmentDisclosure(
        constraint: RevenueRecognitionTableStructure.AxisConstraint,
        table: RevenueRecognitionCandidates.ParsedTable
    ) -> Bool {
        if constraint == .productOnly { return false }
        if constraint == .geographyOnly { return false }
        if table.precedingCaption?.contains("製品") == true
            || table.precedingCaption?.contains("サービス") == true
        {
            return false
        }
        return (table.precedingCaption ?? "").contains("単一セグメント")
    }

    /// 製品・サービス別表、報告セグメントの列マトリクス、地域のみ、の順で Jev に出す。
    /// セグメント注記は製品表・報告セグメント・所在地表が混在するので、全体の axisConstraint
    /// をそのまま使うと製品表が geography_only で落ちる。
    /// `segment` 軸では報告セグメント行列だけを残し、製品表は出さない。
    static func preferredTables(
        _ all: [RevenueRecognitionCandidates.ParsedTable],
        axis: String = breakdownAxisProductService
    ) -> [RevenueRecognitionCandidates.ParsedTable] {
        let salesTables = all.filter { !isNonSalesMetricTable($0) && !isWholeCompanyOnlyTable($0) }
        let tables = salesTables.isEmpty ? all : salesTables
        if axis == breakdownAxisSegment {
            let matrices = tables.filter { isSegmentColumnMatrix($0) && !isDedicatedProductTable($0) }
            if !matrices.isEmpty { return matrices }
            return tables.filter { !isDedicatedProductTable($0) }
        }
        // 行が売上と利益の指標で、列がセグメントの表は製品表ではない（8591 S100LU21 の前期表は
        // 「貸倒引当金繰入(戻入)額」などの行で製品表に数えられ、当期表より先に残っていた）。
        let product = tables.filter { isDedicatedProductTable($0) && !isMetricRowMatrix($0) }
        if !product.isEmpty { return product }
        let matrices = tables.filter { isSegmentColumnMatrix($0) }
        if !matrices.isEmpty { return matrices }
        let geography = tables.filter {
            RevenueRecognitionTableStructure.tableAxis(of: $0) == .geography
        }
        if !geography.isEmpty { return geography }
        return tables
    }

    /// 左端の列にセグメント名、その下に「(1) 外部顧客に対する売上高」「事業利益」などの指標が
    /// 縦に並ぶ表（6981 S100LPV9）を、セグメントを行・期間を列にした表へ畳む。
    /// 各セグメントの外部顧客への売上高の行だけを残す。2 ブロック以上がどれも売上行を持つときだけ。
    /// ラベル1列の積み上げ表（6758 S100LM4N の米国基準「売上高及び営業収入」）。事業ごとに
    /// 見出し → 外部顧客に対するもの → セグメント間取引 → 計 が並び、末尾の
    /// 「全社（共通）及びセグメント間取引消去」は各事業の「計」の和を連結合計へつなぐ調整
    /// （△186,953）であり、外部顧客の和とはつながらない。各事業の外部顧客の行と、
    /// 連結合計 − 外部顧客の和（全社（共通）の外部顧客分 11,034）の調整行だけの表に組み直す。
    /// どの金額列でも「計」の和 + 調整 = 連結合計 が成り立ち、外部顧客の和 + 調整 は成り立たない
    /// ときだけ。それ以外の形はそのまま返す。
    static func rebasingStackedExternalBlocks(_ table: BreakdownTable) -> BreakdownTable {
        let grid = BreakdownExtractor.markdownToGrid(table.markdown)
        let width = grid.map(\.count).max() ?? 0
        guard width >= 2 else { return table }
        let rows = grid.map { $0 + Array(repeating: "", count: width - $0.count) }
        func label(_ row: [String]) -> String { RevenueRecognitionCandidates.compactCell(row[0]) }
        func amounts(_ row: [String]) -> [Double?] {
            row.dropFirst().map { cell in
                RevenueRecognitionCandidates.isAmountCell(cell)
                    ? RevenueRecognitionCandidates.parseAmount(cell) : nil
            }
        }
        func hasAmount(_ row: [String]) -> Bool { amounts(row).contains { $0 != nil } }
        func isHeading(_ text: String) -> Bool { text.hasSuffix("：") || text.hasSuffix(":") }

        guard let firstHeading = rows.firstIndex(where: { isHeading(label($0)) && !hasAmount($0) })
        else { return table }
        struct Block { var name: String; var external: [Double?]?; var total: [Double?]? }
        var blocks: [Block] = []
        var open: Block?
        var reconciling: (label: String, values: [Double?])?
        var grandTotal: (label: String, values: [Double?])?
        for row in rows[firstHeading...] {
            let text = label(row)
            if !hasAmount(row) {
                guard isHeading(text), reconciling == nil else { return table }
                if let block = open, block.external != nil || block.total != nil { return table }
                open = Block(name: String(text.dropLast()), external: nil, total: nil)
                continue
            }
            if var block = open {
                if text.contains("外部顧客"), block.external == nil {
                    block.external = amounts(row)
                } else if text.hasPrefix("セグメント間"), block.external != nil, block.total == nil {
                    // 内部取引は捨てる（計の検算にだけ使う）。
                } else if text == "計", block.external != nil {
                    block.total = amounts(row)
                    blocks.append(block)
                    open = nil
                    continue
                } else {
                    return table
                }
                open = block
                continue
            }
            if reconciling == nil, grandTotal == nil,
               text.contains("消去") || text.contains("調整") || text.contains("全社")
            {
                reconciling = (text, amounts(row))
            } else if reconciling != nil, grandTotal == nil, text.contains("合計") {
                grandTotal = (text, amounts(row))
            } else {
                return table
            }
        }
        guard open == nil, blocks.count >= 2, let reconciling, let grandTotal else { return table }

        var rebased: [Double?] = []
        var checkedColumns = 0
        for column in 0..<(width - 1) {
            guard let total = grandTotal.values[column], let adjustment = reconciling.values[column]
            else {
                rebased.append(nil)
                continue
            }
            let externals = blocks.compactMap { $0.external?[column] }
            let totals = blocks.compactMap { $0.total?[column] }
            guard externals.count == blocks.count, totals.count == blocks.count else { return table }
            let tolerance = max(1.0, abs(total) * 0.0005)
            let externalSum = externals.reduce(0, +)
            guard abs(totals.reduce(0, +) + adjustment - total) <= tolerance,
                  abs(externalSum + adjustment - total) > tolerance
            else { return table }
            rebased.append(total - externalSum)
            checkedColumns += 1
        }
        guard checkedColumns > 0 else { return table }

        func cells(_ values: [Double?]) -> [String] {
            values.map { value in value.map(formattedAmount) ?? "" }
        }
        var collapsed: [[String]] = Array(rows.prefix(firstHeading))
        for block in blocks {
            collapsed.append([block.name] + cells(block.external ?? []))
        }
        collapsed.append([reconciling.label] + cells(rebased))
        collapsed.append([grandTotal.label] + cells(grandTotal.values))
        var copy = table
        copy.markdown = BreakdownExtractor.gridToMarkdown(collapsed)
        return copy
    }

    private static func formattedAmount(_ value: Double) -> String {
        let magnitude = Int64(abs(value).rounded())
        var digits = String(magnitude)
        var grouped = ""
        while digits.count > 3 {
            grouped = "," + String(digits.suffix(3)) + grouped
            digits = String(digits.dropLast(3))
        }
        return (value < 0 ? "△" : "") + digits + grouped
    }

    static func collapsingSegmentBlocks(_ table: BreakdownTable) -> BreakdownTable {
        let grid = BreakdownExtractor.markdownToGrid(table.markdown)
        let width = grid.map(\.count).max() ?? 0
        guard width >= 3 else { return table }
        let rows = grid.map { $0 + Array(repeating: "", count: width - $0.count) }
        // 最初のブロック見出し（金額なし）は見出し行に数えられがちなので、最初に金額が出る行の
        // 1 行上をブロックの始まりにする。
        guard let firstAmountRow = rows.firstIndex(where: { row in
            row.dropFirst(2).contains { RevenueRecognitionCandidates.isAmountCell($0) }
        }), firstAmountRow >= 2 else { return table }
        let headerCount = firstAmountRow - 1
        var blocks: [(name: String, salesRow: [String]?)] = []
        for row in rows.dropFirst(headerCount) {
            let name = RevenueRecognitionCandidates.compactCell(row[0])
            let label = RevenueRecognitionCandidates.compactCell(row[1])
            let hasAmount = row.dropFirst(2).contains { RevenueRecognitionCandidates.isAmountCell($0) }
            if !name.isEmpty {
                // 見出し行は金額を持たない。左端に名前があって金額もある行は普通の表。
                guard !hasAmount, name != label else { return table }
                blocks.append((name, nil))
                continue
            }
            guard !blocks.isEmpty else { return table }
            if blocks[blocks.count - 1].salesRow == nil,
               label.contains("外部顧客"), isGenericSalesLabel(label)
            {
                blocks[blocks.count - 1].salesRow = row
            }
        }
        // 「連結」だけの続き表（改ページで分かれた全社ブロック）も同じ形に畳み、候補から外せるようにする。
        let wholeCompanyOnly = blocks.count == 1
            && RevenueRecognitionCandidates.isAggregateColumnHeader(blocks[0].name)
        guard blocks.count >= 2 || wholeCompanyOnly,
              blocks.allSatisfy({ $0.salesRow != nil })
        else { return table }
        let collapsed = Array(rows.prefix(headerCount)) + blocks.map { block in
            [block.name, block.name] + Array(block.salesRow!.dropFirst(2))
        }
        var copy = table
        copy.markdown = BreakdownExtractor.gridToMarkdown(collapsed)
        return copy
    }

    /// 報告セグメントの列が2表に分かれ、後ろの表の最後に合計列がある（8591 オリックスの
    /// 国内7セグメント表と海外3セグメント＋合計表）。行ラベルが行ごとに一致する隣り合う同じ期間の
    /// 表を横につなぐ。後ろの表は空にして、表番号（単位の参照先）はずらさない。
    static func mergingSplitSegmentMatrices(_ tables: [BreakdownTable]) -> [BreakdownTable] {
        guard tables.count >= 2 else { return tables }
        var merged = tables
        var index = 0
        while index + 1 < merged.count {
            let left = BreakdownExtractor.markdownToGrid(merged[index].markdown)
            let right = BreakdownExtractor.markdownToGrid(merged[index + 1].markdown)
            if merged[index].period != nil, merged[index].period == merged[index + 1].period,
               let joined = joinedSplitMatrix(left, right)
            {
                merged[index].markdown = BreakdownExtractor.gridToMarkdown(joined)
                merged[index + 1].markdown = ""
                index += 2
                continue
            }
            index += 1
        }
        return merged
    }

    static func joinedSplitMatrix(_ left: [[String]], _ right: [[String]]) -> [[String]]? {
        guard left.count >= 6, left.count == right.count else { return nil }
        let leftWidth = left.map(\.count).max() ?? 0
        let rightWidth = right.map(\.count).max() ?? 0
        guard leftWidth >= 3, rightWidth >= 3 else { return nil }
        let leftRows = left.map { $0 + Array(repeating: "", count: leftWidth - $0.count) }
        let rightRows = right.map { $0 + Array(repeating: "", count: rightWidth - $0.count) }
        for (l, r) in zip(leftRows, rightRows) {
            guard RevenueRecognitionCandidates.compactCell(l[0])
                == RevenueRecognitionCandidates.compactCell(r[0]) else { return nil }
        }
        let headerCount = RevenueRecognitionCandidates.dataStartRow(leftRows)
        guard headerCount > 0, headerCount < leftRows.count else { return nil }
        func lastHeader(_ rows: [[String]], _ column: Int) -> String {
            rows.prefix(headerCount).map { RevenueRecognitionCandidates.compactCell($0[column]) }
                .filter { !$0.isEmpty && !$0.hasPrefix("(") && !$0.hasPrefix("（") }
                .last ?? ""
        }
        // 前の表は合計列を持たず、後ろの表の最後の列だけが合計。
        let leftHasTotal = (1..<leftWidth).contains {
            RevenueRecognitionCandidates.isAggregateColumnHeader(lastHeader(leftRows, $0))
        }
        guard !leftHasTotal,
              RevenueRecognitionCandidates.isAggregateColumnHeader(
                lastHeader(rightRows, rightWidth - 1))
        else { return nil }
        return zip(leftRows, rightRows).map { l, r in l + Array(r.dropFirst()) }
    }

    /// 行が「連結」「消去又は全社」など全社・調整だけの表（6981 S100R773 の連結ブロック）。
    static func isWholeCompanyOnlyTable(_ table: RevenueRecognitionCandidates.ParsedTable) -> Bool {
        !table.items.isEmpty && table.items.allSatisfy {
            RevenueRecognitionCandidates.isAggregateColumnHeader($0.label)
        }
    }

    static func isMetricRowMatrix(_ table: RevenueRecognitionCandidates.ParsedTable) -> Bool {
        let labels = table.items.map { stripLeadingEnumeration($0.label) }
        return labels.contains(where: isGenericSalesLabel) && labels.contains(where: isProfitMetricLabel)
    }

    static let nonSalesMetricHeads = [
        "営業利益", "営業損益", "セグメント利益", "セグメント損益", "セグメント損失",
        "当期償却額", "当期末残高", "のれんの償却額", "減損損失", "税金等調整前当期純利益",
        "セグメント資産",
    ]
    static let salesMarkers = [
        "売上", "顧客との契約", "外部顧客", "営業収益", "経常収益", "収益合計", "セグメント収益",
    ]

    /// 売上の行が無く、利益・のれん償却・残高の行だけの表（4901 S100LV2D のセグメント損益と
    /// 調整表、7062 S100YLVZ ののれん償却額及び未償却残高）。売上内訳の候補にしない。
    static func isNonSalesMetricTable(_ table: RevenueRecognitionCandidates.ParsedTable) -> Bool {
        let labels = table.grid.dropFirst(table.headerRowCount).compactMap { row -> String? in
            guard let first = row.first else { return nil }
            let compact = RevenueRecognitionCandidates.compactCell(first)
                .replacingOccurrences(of: " ", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "：:"))
            return compact.isEmpty ? nil : compact
        }
        let hasNonSalesHead = labels.contains { label in
            nonSalesMetricHeads.contains { label.hasPrefix($0) }
        }
        guard hasNonSalesHead else { return false }
        return !labels.contains { label in salesMarkers.contains { label.contains($0) } }
    }

    static func isDedicatedProductTable(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> Bool {
        if SegmentInfoPublishGuards.hasProductOrBusinessLabels(table) { return true }
        return RevenueRecognitionTableStructure.tableAxis(of: table) == .productOrBusiness
    }

    private static func buildSnapshotRows(
        table: RevenueRecognitionCandidates.ParsedTable,
        column: RevenueRecognitionCandidates.AmountColumn,
        choice: SegmentInfoChoice,
        transposed: Bool,
        fiscalYearEnd: String?
    ) -> (
        built: [RevenueRecognitionCandidates.BuiltRow],
        profits: [String: Double],
        groupSumReview: Bool,
        parallelUnresolved: Bool,
        transposedWhole: Double?
    ) {
        if transposed {
            let sales = resolveMetricRow(
                choice.salesRow, rows: metricRows(in: table),
                preferred: { preferredSalesRow(in: $0, fiscalYearEnd: fiscalYearEnd) })
            let profit = resolveMetricRow(
                choice.profitRow, rows: metricRows(in: table), preferred: preferredProfitRow(in:))
            let salesRowIndex = sales?.row
                ?? preferredSalesRow(in: metricRows(in: table), fiscalYearEnd: fiscalYearEnd)?.row
            guard let salesRowIndex else {
                return ([], [:], false, false, nil)
            }
            let transposed = transposeSegmentColumns(
                table: table, salesRow: salesRowIndex,
                wholeCompanyColumn: column.column, profitRow: profit?.row)
            return (transposed.rows, transposed.profits, false, false, transposed.wholeCompanyAmount)
        }

        var (built, groupSumReview) = RevenueRecognitionCandidates.buildRows(
            table: table, column: column.column)
        let parallelUnresolved = RevenueRecognitionCandidates.parallelDimensionsUnresolved(
            table: table, column: column.column)
        var transposedWhole: Double?
        if built.isEmpty && !parallelUnresolved {
            let fallback = RevenueRecognitionCandidates.transposeMetricRow(
                table: table, wholeCompanyColumn: column.column)
            built = fallback.rows
            transposedWhole = fallback.wholeCompanyAmount
            groupSumReview = false
        }
        return (built, [:], groupSumReview, parallelUnresolved, transposedWhole)
    }

    /// 選んだ表が空行なら、製品表・他のマトリクスから組める行を探す。
    /// それでも空なら呼び出し側がスナップショットを作らない（空 LLM で facts を隠さない）。
    private static func assembleRowsRecoveringOtherTables(
        selectedTable: RevenueRecognitionCandidates.ParsedTable,
        selectedColumn: RevenueRecognitionCandidates.AmountColumn,
        choice: SegmentInfoChoice,
        parsed: [RevenueRecognitionCandidates.ParsedTable],
        columns: [RevenueRecognitionCandidates.AmountColumn],
        fiscalYearEnd: String?
    ) -> (
        table: RevenueRecognitionCandidates.ParsedTable,
        column: RevenueRecognitionCandidates.AmountColumn,
        built: [RevenueRecognitionCandidates.BuiltRow],
        profits: [String: Double],
        groupSumReview: Bool,
        parallelUnresolved: Bool,
        transposedWhole: Double?,
        recovered: Bool
    ) {
        func assemble(
            table: RevenueRecognitionCandidates.ParsedTable,
            column: RevenueRecognitionCandidates.AmountColumn
        ) -> (
            built: [RevenueRecognitionCandidates.BuiltRow],
            profits: [String: Double],
            groupSumReview: Bool,
            parallelUnresolved: Bool,
            transposedWhole: Double?
        ) {
            return buildSnapshotRows(
                table: table, column: column, choice: choice,
                transposed: isSegmentColumnMatrix(table), fiscalYearEnd: fiscalYearEnd)
        }

        let first = assemble(table: selectedTable, column: selectedColumn)
        if !first.built.isEmpty {
            return (
                selectedTable, selectedColumn, first.built, first.profits,
                first.groupSumReview, first.parallelUnresolved, first.transposedWhole, false)
        }

        var seen: Set<Int> = [selectedTable.tableIndex]
        // 前期の表は最後に回す（8591 S100YG5L で前期のセグメント表から組んでいた）。
        let preferred = preferredTables(parsed)
        let recovery = preferred.filter { $0.period != "前期" } + preferred.filter { $0.period == "前期" }
            + parsed
        for candidate in recovery where !seen.contains(candidate.tableIndex) {
            seen.insert(candidate.tableIndex)
            guard let recoveryColumn = amountColumn(for: candidate, among: columns) else { continue }
            let next = assemble(table: candidate, column: recoveryColumn)
            if !next.built.isEmpty {
                return (
                    candidate, recoveryColumn, next.built, next.profits,
                    next.groupSumReview, next.parallelUnresolved, next.transposedWhole, true)
            }
        }
        return (
            selectedTable, selectedColumn, first.built, first.profits,
            first.groupSumReview, first.parallelUnresolved, first.transposedWhole, false)
    }

    static func amountColumn(
        for table: RevenueRecognitionCandidates.ParsedTable,
        among columns: [RevenueRecognitionCandidates.AmountColumn]
    ) -> RevenueRecognitionCandidates.AmountColumn? {
        let scoped = columns.filter { $0.tableIndex == table.tableIndex }
        guard !scoped.isEmpty else { return nil }
        let current = scoped.filter {
            let header = RevenueRecognitionCandidates.compactCell($0.header)
            return header.contains("当") || header.contains("合計") || header.contains("連結")
        }
        return current.last ?? scoped.last
    }

    /// 専用タグ省略の前に、製品・サービス別（または事業別）の組立可能表があるか。
    static func hasUsableProductOrBusinessTable(_ tables: [BreakdownTable]) -> Bool {
        if tables.contains(where: { $0.heading == BreakdownExtractor.productOrServiceHeading }) {
            return true
        }
        let parsed = RevenueRecognitionCandidates.parse(tables: tables)
        return parsed.contains(where: isDedicatedProductTable)
    }

    /// Jev が選んだ1表に閉じると、空行・前期・非製品表で製品表が見えなくなる。
    /// 組立不能・前期（当期あり）・製品表があるのに選んだ表が製品でないときは閉じない。
    static func shouldIsolateKeptTable(
        index: Int,
        tables: [BreakdownTable],
        fiscalYearEnd: String?
    ) -> Bool {
        guard tables.indices.contains(index) else { return false }
        let parsed = RevenueRecognitionCandidates.parse(tables: tables)
        guard let selected = parsed.first(where: { $0.tableIndex == index }) else { return false }
        if SegmentInfoPublishGuards.isPriorEraTable(
            selected, among: parsed, fiscalYearEnd: fiscalYearEnd)
        {
            let current = parsed.contains {
                $0.tableIndex != selected.tableIndex
                    && !SegmentInfoPublishGuards.isPriorEraTable(
                        $0, among: parsed, fiscalYearEnd: fiscalYearEnd)
            }
            if current { return false }
        }
        if hasUsableProductOrBusinessTable(tables), !isDedicatedProductTable(selected) {
            return false
        }
        if !isSegmentColumnMatrix(selected),
           parsed.contains(where: {
               $0.tableIndex != selected.tableIndex && isSegmentColumnMatrix($0)
           })
        {
            return false
        }
        return canAssembleBusinessRows(selected)
    }

    static func canAssembleBusinessRows(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> Bool {
        if isDedicatedProductTable(table) { return true }
        if isSegmentColumnMatrix(table) {
            return preferredSalesRow(in: metricRows(in: table)) != nil
        }
        let columns = table.columnHeaders.keys.sorted()
        for column in columns {
            let (built, _) = RevenueRecognitionCandidates.buildRows(table: table, column: column)
            if !built.isEmpty { return true }
        }
        return false
    }

    private static func resolveMetricRow(
        _ choice: RevenueRecognitionColumnChoice?,
        rows: [SegmentInfoMetricRow],
        preferred: ([SegmentInfoMetricRow]) -> SegmentInfoMetricRow?
    ) -> SegmentInfoMetricRow? {
        let keys = Set(rows.map(\.key))
        if let selected = choice?.selected, selected != RevenueRecognitionColumnNormalizer.noneOfThese,
           let hit = rows.first(where: { $0.key == selected })
        {
            return hit
        }
        if let selected = choice?.selected, selected == RevenueRecognitionColumnNormalizer.noneOfThese {
            let confidence = choice?.confidence ?? 0
            let pNone = choice?.pNone ?? 0
            if confidence >= RevenueRecognitionColumnNormalizer.noneOfTheseMinConfidence
                && pNone >= RevenueRecognitionColumnNormalizer.noneOfTheseMinPNone
            {
                return nil
            }
        }
        if let selected = choice?.selected, keys.contains(selected),
           let hit = rows.first(where: { $0.key == selected })
        {
            return hit
        }
        return preferred(rows)
    }

    static func transposeSegmentColumns(
        table: RevenueRecognitionCandidates.ParsedTable,
        salesRow: Int,
        wholeCompanyColumn: Int,
        profitRow: Int?
    ) -> (rows: [RevenueRecognitionCandidates.BuiltRow], profits: [String: Double], wholeCompanyAmount: Double?) {
        guard salesRow < table.grid.count else { return ([], [:], nil) }
        let row = table.grid[salesRow]
        let wholeCompanyAmount = RevenueRecognitionCandidates.consolidatedWholeCompanyAmount(
            table: table, row: row, selectedColumn: wholeCompanyColumn)
        var built: [RevenueRecognitionCandidates.BuiltRow] = []
        var profits: [String: Double] = [:]
        let profitCells = profitRow.flatMap { profit in
            profit < table.grid.count ? table.grid[profit] : nil
        }
        for (column, header) in table.columnHeaders.sorted(by: { $0.key < $1.key }) {
            if column == wholeCompanyColumn, isSkippedTotalColumn(header) { continue }
            // 消去・調整の列は合計列ではないので reconciling として残す（利益の差異調整。7751 消去 911）。
            if isSkippedTotalColumn(header), !isReconcilingColumnHeader(header) { continue }
            if isPeriodColumnHeader(header) { continue }
            if RevenueRecognitionCandidates.isPeriodHeadingLabel(header) { continue }
            guard column < row.count, let amount = RevenueRecognitionCandidates.parseAmount(row[column])
            else { continue }
            let name = RevenueRecognitionCandidates.compactCell(header)
            guard !name.isEmpty else { continue }
            if SegmentInfoPublishGuards.isNumericOrCodeLabel(name) { continue }
            let kind = isReconcilingColumnHeader(header) ? "reconciling" : "segment"
            let profit = profitCells.flatMap { cells in
                column < cells.count ? RevenueRecognitionCandidates.parseAmount(cells[column]) : nil
            }
            // 売上も利益も「-」の調整列は載せる差異が無いので空行にしない（2802 の調整額）。
            if kind == "reconciling", amount == 0, (profit ?? 0) == 0 { continue }
            built.append(RevenueRecognitionCandidates.BuiltRow(
                categoryGroup: name, category: nil, amount: amount,
                isPartial: false, rowKind: kind))
            if let profit { profits[name] = profit }
        }
        return (built, profits, wholeCompanyAmount)
    }

    private static func finalizeRows(
        built: [RevenueRecognitionCandidates.BuiltRow],
        profits: [String: Double],
        multiplier: Double,
        consolidatedSales: Double?,
        initialDenominator: Double,
        initialDenomTag: String,
        needsReview: inout Bool,
        warnings: inout [String],
        denominator: inout Double,
        denominatorTag: inout String
    ) -> [BreakdownRow] {
        var rows: [BreakdownRow] = []
        for row in built {
            let yen = row.amount * multiplier
            let profitYen = profits[row.categoryGroup]
                ?? row.category.flatMap { profits[$0] }
            let rawLabel = row.category ?? row.categoryGroup
            let kind = rowKindForLabel(rawLabel, fallback: row.rowKind)
            rows.append(BreakdownRow(
                labelRaw: rawLabel,
                label: RevenueRecognitionCandidates.displayLabel(
                    categoryGroup: row.categoryGroup, category: row.category),
                amount: yen,
                share: nil,
                profit: profitYen.map { $0 * multiplier },
                rowKind: kind,
                categoryGroup: row.categoryGroup,
                category: row.category
            ))
        }

        if let consolidatedSales, consolidatedSales != 0 {
            rows = demotingTrailingParentSubtotals(
                rows, consolidatedSales: consolidatedSales, unit: multiplier)
        }
        let segmentSum = rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + $1.amount }
        let reconcilingSum = rows.filter { $0.rowKind == "reconciling" }.reduce(0.0) { $0 + $1.amount }
        var denom = initialDenominator
        var denomTag = initialDenomTag
        if let consolidatedSales, consolidatedSales != 0 {
            let segmentShare = segmentSum / consolidatedSales
            if !denominatorTolerance.contains(segmentShare) {
                let internalSum = segmentSum + reconcilingSum
                let subtotalCandidates = rows.filter { $0.rowKind == "subtotal" }
                if let closest = subtotalCandidates.min(by: {
                    abs($0.amount - internalSum) < abs($1.amount - internalSum)
                }), closest.amount != 0, abs(closest.amount - internalSum) / abs(closest.amount) <= 0.05 {
                    denom = closest.amount
                    denomTag = "llm_table_subtotal"
                    warnings.append("llm_denominator_from_internal_subtotal")
                } else if abs(initialDenominator) > 0,
                    denominatorTolerance.contains(segmentSum / initialDenominator)
                {
                    denom = initialDenominator
                    if denomTag != "income_statement.sales",
                       !warnings.contains("llm_denominator_from_internal_subtotal")
                    {
                        warnings.append("llm_denominator_from_internal_subtotal")
                    }
                } else {
                    needsReview = true
                    warnings.append("llm_row_sum_mismatch")
                }
            } else {
                denom = consolidatedSales
            }
        }
        denominator = denom
        denominatorTag = denomTag
        return rows.map { row in
            var copy = row
            copy.share = denom == 0 ? nil : copy.amount / denom
            return copy
        }
    }

    /// 子の直後に親の小計が来る表（「オフィスプリンティング分野」「オフィスサービス分野」の後に
    /// 「オフィス分野」）。セグメント合計が売上の許容幅を超え、直前の連続した 2 行以上の合計に
    /// 一致する行を小計に落とすと許容幅に収まるときだけ、その行を `subtotal` にする（7752 S100LKDZ）。
    /// ラベルは見ない。合計が既に許容幅にあるときは何もしない。
    static func demotingTrailingParentSubtotals(
        _ rows: [BreakdownRow], consolidatedSales: Double, unit: Double
    ) -> [BreakdownRow] {
        func segmentSum(_ rows: [BreakdownRow]) -> Double {
            rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + $1.amount }
        }
        guard !denominatorTolerance.contains(segmentSum(rows) / consolidatedSales) else { return rows }
        var result = rows
        for index in result.indices where result[index].rowKind == "segment" {
            var childSum = 0.0
            var childCount = 0
            var cursor = index - 1
            while cursor >= 0, result[cursor].rowKind == "segment" {
                childSum += result[cursor].amount
                childCount += 1
                cursor -= 1
                guard childCount >= 2 else { continue }
                if abs(childSum - result[index].amount) <= Double(childCount) * unit,
                   result[index].amount != 0
                {
                    break
                }
            }
            guard childCount >= 2,
                  abs(childSum - result[index].amount) <= Double(childCount) * unit,
                  result[index].amount != 0
            else { continue }
            result[index].rowKind = "subtotal"
        }
        guard denominatorTolerance.contains(segmentSum(result) / consolidatedSales) else {
            return rows
        }
        return result
    }

    private static func flagGeographyLabels(
        _ rows: [BreakdownRow], needsReview: inout Bool, warnings: inout [String]
    ) {
        let segmentLabels = rows.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        let labelsExcludingOther = segmentLabels.filter { !$0.contains("その他") }
        let allLabelsLookLikeGeography = !labelsExcludingOther.isEmpty && labelsExcludingOther.allSatisfy { label in
            Xbrl.segmentGeographyLabelKeywordsJa.contains { label.contains($0) }
        }
        let hasSpecificGeographyLabel = labelsExcludingOther.contains { label in
            Xbrl.segmentSpecificGeographyLabelKeywordsJa.contains { label.contains($0) }
        }
        if allLabelsLookLikeGeography, hasSpecificGeographyLabel {
            needsReview = true
            warnings.append("business_label_looks_like_geography")
        }
    }

    /// LLM が「その他（消去分を含む）」を reconciling に誤分類しても、残事業バケットとして
    /// segment に直す（野村HD、ユーザー確認 2026-07-25）。
    static func resolvedRowKind(label: String, rowKind: String) -> String {
        guard rowKind == "reconciling", label.contains("その他") else { return rowKind }
        if label.contains("消去分を含む") || label.contains("全社") { return "segment" }
        if label.contains("消去") || label.contains("調整") { return rowKind }
        return "segment"
    }

    static func rowKindForLabel(_ label: String, fallback: String) -> String {
        if RevenueRecognitionCandidates.isTotalLabel(label) { return "subtotal" }
        if fallback == "reconciling" || fallback == "subtotal" {
            return resolvedRowKind(label: label, rowKind: fallback)
        }
        let compact = RevenueRecognitionCandidates.compactCell(label)
        if compact.contains("消去") || compact.contains("調整") {
            return resolvedRowKind(label: compact, rowKind: "reconciling")
        }
        return fallback
    }

    private static func consensusMetricRow(
        _ rows: [RevenueRecognitionColumnChoice?]
    ) -> RevenueRecognitionColumnChoice? {
        let present = rows.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        let aggregate = JevChoiceAggregate.combine(present.map(JevChoiceAggregate.fromColumn))
        guard aggregate.isConfident else { return nil }
        return JevChoiceAggregate.columnChoice(from: aggregate)
    }

    private static func jevPayload(
        docID: String, samples: [RevenueRecognitionColumnChoice],
        aggregate: JevChoiceAggregate.Result,
        resolved: RevenueRecognitionColumnNormalizer.ResolvedColumn?
    ) -> SegmentNoteJevAuditPayload {
        SegmentNoteJevAuditPayload(
            code: "", docID: docID, axis: breakdownAxisProductService,
            model: aggregate.model.isEmpty
                ? (samples.first?.model ?? "") : aggregate.model,
            threshold: RevenueRecognitionColumnNormalizer.jevPolicy.auditThreshold,
            applied: false, needsReview: false, sentences: [],
            calls: RevenueRecognitionColumnNormalizer.publishedColumnCalls(
                samples: samples.map(JevChoiceAggregate.fromColumn),
                options: samples.first?.options ?? aggregate.options,
                resolved: resolved))
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
}

struct OpenRouterSegmentInfoDecider: SegmentInfoDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    func choose(
        columns: [RevenueRecognitionCandidates.AmountColumn],
        metricRows: [SegmentInfoMetricRow],
        tables: [RevenueRecognitionCandidates.ParsedTable],
        fiscalYearEnd: String?,
        docID: String
    ) async -> SegmentInfoChoice {
        let columnOptions = columns.map(\.key) + [RevenueRecognitionColumnNormalizer.noneOfThese]
        let unavailable = RevenueRecognitionColumnChoice(
            selected: nil, confidence: nil, model: model, options: columnOptions)
        guard let body = Self.requestJSON(
            model: model, columns: columns, metricRows: metricRows, tables: tables,
            fiscalYearEnd: fiscalYearEnd, docID: docID)
        else {
            return SegmentInfoLLMNormalizer.choiceByFillingMetricRows(
                column: unavailable, metricRows: metricRows, fiscalYearEnd: fiscalYearEnd)
        }
        guard let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body,
            retries: RevenueRecognitionColumnNormalizer.jevPolicy.transportRetries,
            onFailure: "SegmentInfoLLMNormalizer: Jev呼び出し失敗")
        else {
            return SegmentInfoLLMNormalizer.choiceByFillingMetricRows(
                column: unavailable, metricRows: metricRows, fiscalYearEnd: fiscalYearEnd)
        }
        let answers = OpenRouterDecisionsCodec.answers(from: data)
        func parsed(_ question: String, options: [String]) -> RevenueRecognitionColumnChoice {
            let answer = answers[question]
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
        }
        let column = parsed(RevenueRecognitionColumnNormalizer.question, options: columnOptions)
        let rowOptions = metricRows.map(\.key) + [RevenueRecognitionColumnNormalizer.noneOfThese]
        let sales = metricRows.isEmpty
            ? nil : parsed(SegmentInfoLLMNormalizer.salesRowQuestion, options: rowOptions)
        let profit = metricRows.isEmpty
            ? nil : parsed(SegmentInfoLLMNormalizer.profitRowQuestion, options: rowOptions)
        return SegmentInfoChoice(column: column, salesRow: sales, profitRow: profit)
    }

    static func requestJSON(
        model: String,
        columns: [RevenueRecognitionCandidates.AmountColumn],
        metricRows: [SegmentInfoMetricRow],
        tables: [RevenueRecognitionCandidates.ParsedTable],
        fiscalYearEnd: String?,
        docID: String
    ) -> Data? {
        let fy = fiscalYearEnd ?? "不明"
        var columnCriteria: [String: String] = [:]
        for column in columns {
            let caption = column.caption ?? "none"
            let header = column.header.isEmpty ? "none" : column.header
            let unit = column.unit ?? "none"
            columnCriteria[column.key] = """
                table t\(column.tableIndex) (caption above the table: \(caption), unit: \(unit)), \
                column \(column.column) (column header: \(header))
                """
        }
        columnCriteria[RevenueRecognitionColumnNormalizer.noneOfThese] =
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
        let columnInstructions = """
            The state lists セグメント情報 and/or 製品・サービス別情報 table(s) from a Japanese \
            annual securities report (有価証券報告書) for the fiscal year ending \(fy). Which \
            single column holds the CURRENT fiscal year (当連結会計年度 / 当事業年度, the year \
            ending \(fy)) amounts for the whole company? If the table's columns are reportable \
            segments or products (事業 / 製品 names) plus 合計 or 連結, choose that total column, \
            not a segment column. If rows are products or businesses and columns are 前期 / 当期, \
            choose the current-year column. Prior-year columns are wrong.
            """
        var questions: [String: Any] = [
            RevenueRecognitionColumnNormalizer.question: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: columnInstructions, criteria: columnCriteria),
        ]
        if !metricRows.isEmpty {
            var salesCriteria: [String: String] = [:]
            var profitCriteria: [String: String] = [:]
            for row in metricRows {
                salesCriteria[row.key] = "table t\(row.tableIndex) row \(row.row) label: \(row.label)"
                profitCriteria[row.key] = "table t\(row.tableIndex) row \(row.row) label: \(row.label)"
            }
            salesCriteria[RevenueRecognitionColumnNormalizer.noneOfThese] =
                "No row is external-customer sales / revenue."
            profitCriteria[RevenueRecognitionColumnNormalizer.noneOfThese] =
                "Operating / segment profit is not disclosed in this table."
            questions[SegmentInfoLLMNormalizer.salesRowQuestion] =
                OpenRouterDecisionsCodec.choiceQuestion(
                    instructions: """
                        Which row holds external-customer sales or equivalent revenue \
                        (外部顧客向け / 外部顧客への売上高 / 経常収益 / 顧客との契約から生じる収益)? \
                        Do not pick セグメント間取引, 売上原価, 営業利益, 総資産, or 研究開発費.
                        """,
                    criteria: salesCriteria)
            questions[SegmentInfoLLMNormalizer.profitRowQuestion] =
                OpenRouterDecisionsCodec.choiceQuestion(
                    instructions: """
                        Which row holds operating profit or segment profit \
                        (営業利益 / セグメント利益 / 実質業務純益)? If profit is not in the table, \
                        choose none_of_these. Do not pick 研究開発費.
                        """,
                    criteria: profitCriteria)
        }
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
