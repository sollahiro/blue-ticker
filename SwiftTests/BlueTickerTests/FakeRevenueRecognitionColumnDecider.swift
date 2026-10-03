// 収益分解の Jev 列選択スタブ（CI はネットワークに出ない）。

import Foundation
@testable import BlueTickerCore

actor FakeRevenueRecognitionColumnDecider: RevenueRecognitionColumnDeciding {
    var selected: String?
    var confidence: Double
    var model: String

    init(selected: String? = nil, confidence: Double = 0.9, model: String = "typesafe/jev-1.13") {
        self.selected = selected
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
        let pick = selected ?? Self.preferWholeCompany(columns)
        return RevenueRecognitionColumnChoice(
            selected: pick, confidence: confidence, model: model, options: options)
    }

    /// 構成比列を避け、合計 / 連結 / 売上高 / 金額 / 当期 を優先する。
    static func preferWholeCompany(
        _ columns: [RevenueRecognitionCandidates.AmountColumn]
    ) -> String? {
        let usable = columns.filter {
            let header = $0.header
            return !header.contains("％") && !header.contains("%") && !header.contains("構成比")
        }
        if let column = usable.last(where: { $0.header.contains("合計") || $0.header.contains("連結") }) {
            return column.key
        }
        if let column = usable.last(where: {
            $0.header.contains("当") || $0.header.contains("売上") || $0.header.contains("金額")
        }) {
            return column.key
        }
        return usable.last?.key ?? columns.last?.key
    }
}
