// 収益分解の Jev 列選択スタブ（CI はネットワークに出ない）。

import Foundation
@testable import BlueTickerCore

actor FakeRevenueRecognitionColumnDecider: RevenueRecognitionColumnDeciding, GeographyExtractionReviewing {
    var selected: String?
    var containing: String?
    var confidence: Double
    var pNone: Double?
    var probabilities: [String: Double]
    var model: String
    var reviewSelected: String?
    var reviewProbability: Double?

    init(
        selected: String? = nil, containing: String? = nil, confidence: Double = 0.9,
        pNone: Double? = nil, probabilities: [String: Double] = [:],
        model: String = "typesafe/jev-1.13",
        reviewSelected: String? = nil, reviewProbability: Double? = nil
    ) {
        self.selected = selected
        self.containing = containing
        self.confidence = confidence
        self.pNone = pNone
        self.probabilities = probabilities
        self.model = model
        self.reviewSelected = reviewSelected
        self.reviewProbability = reviewProbability
    }

    func chooseColumn(
        columns: [RevenueRecognitionCandidates.AmountColumn],
        tables: [RevenueRecognitionCandidates.ParsedTable],
        fiscalYearEnd: String?,
        docID: String
    ) async -> RevenueRecognitionColumnChoice {
        let options = columns.map(\.key) + [RevenueRecognitionColumnNormalizer.noneOfThese]
        let pick = selected
            ?? containing.flatMap { Self.keyContaining($0, columns: columns, tables: tables) }
            ?? Self.preferWholeCompany(columns, tables: tables)
        return RevenueRecognitionColumnChoice(
            selected: pick, confidence: confidence, pNone: pNone, probabilities: probabilities,
            model: model, options: options)
    }

    func reviewExtractedGeography(
        rows: [GeographyExtractionReviewRow],
        tableMarkdown: String,
        heading: String,
        caption: String?,
        warnings: [String],
        needsReview: Bool,
        docID: String
    ) async -> SegmentNoteConsultedChoice {
        SegmentNoteConsultedChoice(
            question: OpenRouterSegmentNoteDecider.reviewDecisionQuestion,
            selected: reviewSelected,
            probability: reviewProbability,
            options: GeographyBreakdownLLMNormalizer.reviewOptions,
            sentences: [])
    }

    /// 実 XBRL 回帰で、既知ラベルを含む分解表の全社列をスタブする。
    static func keyContaining(
        _ needle: String,
        columns: [RevenueRecognitionCandidates.AmountColumn],
        tables: [RevenueRecognitionCandidates.ParsedTable]
    ) -> String? {
        let matching = tables.filter { table in
            table.grid.contains { row in row.contains { $0.contains(needle) } }
        }
        func score(_ table: RevenueRecognitionCandidates.ParsedTable) -> (Int, Int, Int, Int) {
            let inItem = table.items.contains {
                $0.label.contains(needle) || $0.group.contains(needle)
            } ? 1 : 0
            let inHeader = table.columnHeaders.values.contains { $0.contains(needle) } ? 1 : 0
            let current =
                (table.precedingCaption?.contains("当連結会計年度") == true
                    || table.precedingCaption?.contains("当事業年度") == true) ? 1 : 0
            return (inItem, inHeader, current, table.items.count)
        }
        let bestIndex = matching.max(by: { score($0) < score($1) })?.tableIndex
        let scoped = columns.filter { $0.tableIndex == bestIndex }
        return preferWholeCompany(scoped.isEmpty ? columns : scoped, tables: tables)
    }

    /// 構成比列を避け、顧客契約合計がある表の当期／合計列を優先する。
    static func preferWholeCompany(
        _ columns: [RevenueRecognitionCandidates.AmountColumn],
        tables: [RevenueRecognitionCandidates.ParsedTable] = []
    ) -> String? {
        let byIndex = Dictionary(uniqueKeysWithValues: tables.map { ($0.tableIndex, $0) })
        let usable = columns.filter {
            let header = $0.header
            return !header.contains("％") && !header.contains("%") && !header.contains("構成比")
        }
        func rank(_ column: RevenueRecognitionCandidates.AmountColumn) -> (Int, Int, Int, Int, Int) {
            let table = byIndex[column.tableIndex]
            let hasDisaggTotal =
                table?.totals.contains { total in
                    RevenueRecognitionCandidates.totalMarkers.contains { total.label.contains($0) }
                        || total.label.contains("合計")
                } == true ? 1 : 0
            let compactHeader = RevenueRecognitionCandidates.compactCell(column.header)
            let headerPrior = compactHeader.contains("前連結会計年度")
                || compactHeader.contains("前事業年度") || compactHeader.contains("前期")
            let headerCurrent = compactHeader.contains("当連結会計年度")
                || compactHeader.contains("当事業年度") || compactHeader.contains("当期")
                || (compactHeader.contains("当") && !compactHeader.contains("前"))
            let caption = column.caption ?? table?.precedingCaption
            let current: Int
            if headerPrior && !headerCurrent {
                current = 0
            } else if headerCurrent {
                current = 1
            } else if let caption, caption.contains("前連結会計年度") || caption.contains("前事業年度")
                || caption.contains("前年度")
            {
                current = 0
            } else if let caption, caption.contains("当連結会計年度") || caption.contains("当事業年度")
                || caption.contains("当年度") || caption.contains("当期")
            {
                current = 1
            } else {
                current = column.header.contains("当") ? 1 : 0
            }
            let items = table?.items.count ?? 0
            let periodRank: Int
            switch table?.period {
            case "当期": periodRank = 2
            case "比較": periodRank = 1
            case "前期": periodRank = 0
            default: periodRank = current
            }
            let headerRank: Int
            if compactHeader.contains("連結金額") {
                headerRank = 4
            } else if compactHeader.contains("連結合計") || compactHeader.contains("連結計") {
                headerRank = 3
            } else if compactHeader.contains("連結") {
                headerRank = 2
            } else if compactHeader == "合計" {
                // 報告セグメント小計。連結金額がある表では分母にしない。
                headerRank = 1
            } else if compactHeader.contains("合計") || compactHeader.contains("売上")
                || compactHeader.contains("金額")
            {
                headerRank = 1
            } else {
                headerRank = 0
            }
            return (periodRank, current, hasDisaggTotal, headerRank, items)
        }
        return (usable.max { rank($0) < rank($1) } ?? columns.last)?.key
    }
}

extension FakeRevenueRecognitionColumnDecider: SegmentInfoDeciding {
    func choose(
        columns: [RevenueRecognitionCandidates.AmountColumn],
        metricRows: [SegmentInfoMetricRow],
        tables: [RevenueRecognitionCandidates.ParsedTable],
        fiscalYearEnd: String?,
        docID: String
    ) async -> SegmentInfoChoice {
        let column = await chooseColumn(
            columns: columns, tables: tables, fiscalYearEnd: fiscalYearEnd, docID: docID)
        var filled = SegmentInfoLLMNormalizer.choiceByFillingMetricRows(
            column: column, metricRows: metricRows, fiscalYearEnd: fiscalYearEnd)
        if let selected, selected == RevenueRecognitionColumnNormalizer.noneOfThese {
            filled.column = column
        }
        return filled
    }
}
