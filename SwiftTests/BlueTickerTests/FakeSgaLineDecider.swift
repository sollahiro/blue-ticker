// Summary `sga` の Jev 行選択スタブ（CI はネットワークに出ない）。

import Foundation
@testable import BlueTickerCore

actor FakeSgaLineDecider: SgaLineDeciding {
    var pickKey: String?
    var pickLabelContains: String?
    var fail: Bool
    var disagreement: Bool
    var model: String
    private var call = 0

    init(
        pickKey: String? = nil,
        pickLabelContains: String? = nil,
        fail: Bool = false,
        disagreement: Bool = false,
        model: String = "typesafe/jev-1.13"
    ) {
        self.pickKey = pickKey
        self.pickLabelContains = pickLabelContains
        self.fail = fail
        self.disagreement = disagreement
        self.model = model
    }

    func chooseSgaLine(
        rows: [SgaLineCandidate],
        grossProfit: SgaSpanAnchor,
        operatingProfit: SgaSpanAnchor,
        docID: String
    ) async -> SgaLineChoice {
        let options = rows.map(\.key) + [SgaLineJevPicker.noneOfThese]
        if fail {
            return SgaLineChoice(selected: nil, probability: nil, options: options, model: model)
        }
        if disagreement {
            let keys = rows.map(\.key)
            let selected = keys.isEmpty ? SgaLineJevPicker.noneOfThese : keys[call % keys.count]
            call += 1
            return SgaLineChoice(
                selected: selected, probability: 0.9, options: options, model: model)
        }
        let selected: String?
        if let pickKey {
            selected = pickKey
        } else if let needle = pickLabelContains {
            selected = rows.first { $0.label.contains(needle) }?.key
                ?? SgaLineJevPicker.noneOfThese
        } else {
            selected = SgaLineJevPicker.noneOfThese
        }
        return SgaLineChoice(
            selected: selected, probability: 0.95, options: options, model: model)
    }
}
