// 収益分解の Jev 列選択スタブ（CI はネットワークに出ない）。

import Foundation
@testable import BlueTickerCore

actor FakeRevenueRecognitionColumnDecider: RevenueRecognitionColumnDeciding {
    var selected: String?
    var containing: String?
    var confidence: Double
    var model: String

    init(
        selected: String? = nil, containing: String? = nil, confidence: Double = 0.9,
        model: String = "typesafe/jev-1.13"
    ) {
        self.selected = selected
        self.containing = containing
        self.confidence = confidence
        self.model = model
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
            selected: pick, confidence: confidence, model: model, options: options)
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
        func score(_ table: RevenueRecognitionCandidates.ParsedTable) -> (Int, Int, Int) {
            let inItem = table.items.contains {
                $0.label.contains(needle) || $0.group.contains(needle)
            } ? 1 : 0
            let inHeader = table.columnHeaders.values.contains { $0.contains(needle) } ? 1 : 0
            return (inItem, inHeader, table.items.count)
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
        func rank(_ column: RevenueRecognitionCandidates.AmountColumn) -> (Int, Int, Int, Int) {
            let table = byIndex[column.tableIndex]
            let hasDisaggTotal =
                table?.totals.contains { total in
                    RevenueRecognitionCandidates.totalMarkers.contains { total.label.contains($0) }
                        || total.label.contains("合計")
                } == true ? 1 : 0
            let current =
                column.header.contains("当") || (column.caption?.contains("当") == true) ? 1 : 0
            let items = table?.items.count ?? 0
            let headerRank =
                (column.header.contains("合計") || column.header.contains("連結"))
                ? 2
                : (column.header.contains("売上") || column.header.contains("金額") ? 1 : 0)
            return (hasDisaggTotal, current, items, headerRank)
        }
        return (usable.max { rank($0) < rank($1) } ?? columns.last)?.key
    }
}
