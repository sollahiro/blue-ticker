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
        salesDenominatorTag: String? = nil
    ) async -> (snapshot: BreakdownSnapshot?, audit: LLMBreakdownAudit?) {
        guard !result.tables.isEmpty else { return (nil, nil) }
        let parsed = RevenueRecognitionCandidates.parse(tables: result.tables)
        let columns = RevenueRecognitionCandidates.amountColumns(in: parsed)
        guard !columns.isEmpty else { return (nil, nil) }

        let scopedTables = dropPriorEraTables(
            preferredTables(parsed), among: parsed, fiscalYearEnd: fiscalYearEnd)
        let scopedColumns = columns.filter { column in
            scopedTables.contains { $0.tableIndex == column.tableIndex }
        }
        let tablesForChoice = scopedTables.isEmpty ? parsed : scopedTables
        let columnsForChoice = scopedColumns.isEmpty ? columns : scopedColumns
        let constraint = RevenueRecognitionTableStructure.axisConstraint(tables: tablesForChoice)
        // 報告セグメントが地域のみで、使える製品・事業表が無い（製品90％省略の文は製品表ではない）。
        // 製品表は preferredTables が先に残す。日本事業などの事業ユニットは対象外。
        // business に日本/アジアを載せない。地域は geography 軸。
        if constraint == .geographyOnly {
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
        let choice = await decider.choose(
            columns: offered, metricRows: metricRows, tables: offeredTables,
            fiscalYearEnd: fiscalYearEnd, docID: docID)
        var resolved = RevenueRecognitionColumnNormalizer.resolveSelection(
            choice.column, columns: offered)
        resolved = RevenueRecognitionColumnNormalizer.preferProductAxis(
            resolved, columns: offered, tables: tablesForChoice, constraint: constraint)

        let columnJev = jevPayload(
            docID: docID, choice: choice.column, resolvedKey: resolved?.key ?? choice.column.selected,
            question: RevenueRecognitionColumnNormalizer.question)
        let pNoneNote = choice.column.pNone.map { String($0) } ?? "nil"
        var notes =
            "jev_column=\(choice.column.selected ?? "nil") confidence=\(choice.column.confidence.map { String($0) } ?? "nil") p_none=\(pNoneNote)"
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
        var warnings: [String] = []
        var needsReview = belowThreshold || groupSumReview || resolved.forceReview
            || parallelUnresolved
        if belowThreshold { warnings.append(warningLowConfidence) }
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
        stampJev(&audit, applied: !belowThreshold, needsReview: needsReview)

        let snapshot = BreakdownSnapshot(
            axis: breakdownAxisProductService,
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
            !isSkippedTotalColumn(header)
        }
        guard segmentLike.count >= 2 else { return false }
        return !metricRows(in: table).isEmpty
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
        let compact = RevenueRecognitionCandidates.compactCell(label)
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
    /// 百万円または円の一方だけに入るときだけその単位を使う。両方・どちらでもなければ
    /// `other` のまま fail closed（推測百万円は掛けない）。
    static func inferredDeclaredUnit(
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
    static func preferredTables(
        _ tables: [RevenueRecognitionCandidates.ParsedTable]
    ) -> [RevenueRecognitionCandidates.ParsedTable] {
        let product = tables.filter(isDedicatedProductTable)
        if !product.isEmpty { return product }
        let matrices = tables.filter { isSegmentColumnMatrix($0) }
        if !matrices.isEmpty { return matrices }
        let geography = tables.filter {
            RevenueRecognitionTableStructure.tableAxis(of: $0) == .geography
        }
        if !geography.isEmpty { return geography }
        return tables
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
        let recovery = preferredTables(parsed) + parsed
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
            if isSkippedTotalColumn(header) { continue }
            if isPeriodColumnHeader(header) { continue }
            if RevenueRecognitionCandidates.isPeriodHeadingLabel(header) { continue }
            guard column < row.count, let amount = RevenueRecognitionCandidates.parseAmount(row[column])
            else { continue }
            let name = RevenueRecognitionCandidates.compactCell(header)
            guard !name.isEmpty else { continue }
            if SegmentInfoPublishGuards.isNumericOrCodeLabel(name) { continue }
            let kind: String
            if name.contains("消去") && !name.contains("その他") {
                kind = "reconciling"
            } else if name.contains("調整") && !name.contains("その他") {
                kind = "reconciling"
            } else {
                kind = "segment"
            }
            built.append(RevenueRecognitionCandidates.BuiltRow(
                categoryGroup: name, category: nil, amount: amount,
                isPartial: false, rowKind: kind))
            if let profitCells, column < profitCells.count,
               let profit = RevenueRecognitionCandidates.parseAmount(profitCells[column])
            {
                profits[name] = profit
            }
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

    private static func jevPayload(
        docID: String, choice: RevenueRecognitionColumnChoice, resolvedKey: String?, question: String
    ) -> SegmentNoteJevAuditPayload {
        SegmentNoteJevAuditPayload(
            code: "", docID: docID, axis: breakdownAxisProductService,
            model: choice.model, threshold: RevenueRecognitionColumnNormalizer.confidenceThreshold,
            applied: false, needsReview: false, sentences: [],
            calls: [
                SegmentNoteJevCallPayload(
                    question: question,
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
        do {
            let data = try await client.decide(requestJSON: body)
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
        } catch {
            printError("SegmentInfoLLMNormalizer: Jev呼び出し失敗: \(error)\n")
            return SegmentInfoLLMNormalizer.choiceByFillingMetricRows(
                column: unavailable, metricRows: metricRows, fiscalYearEnd: fiscalYearEnd)
        }
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
