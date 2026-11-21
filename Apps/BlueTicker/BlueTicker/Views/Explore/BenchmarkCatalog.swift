import SwiftUI

/// 比較タブに出す指標。`key` は API の `kpis` のキー。
struct BenchmarkMetric: Identifiable {
    enum Kind: Hashable {
        case percent
        case yen
    }

    var key: String
    var title: String
    var caption: String
    var kind: Kind
    /// 値が大きいほど順位が上。
    var higherIsBetter: Bool
    /// 優良・不良を帯の色で示す指標だけ持つ。金額は規模なので色分けしない。
    var band: MetricBand = .none

    var id: String { key }

    func formatted(_ value: Double) -> String {
        switch kind {
        case .percent: Format.percent(value)
        case .yen: Format.autoYen(value)
        }
    }
}

/// 比較できる業種。公開すると決めた業種だけをここに置く（アプリに固定）。
/// TOPIX-17 とは別の区分。細かくなりうるので `TOPIX17Sector` には寄せない。
struct BenchmarkGroup: Identifiable {
    /// API の業種グループ（`/v1/benchmark/{id}`）。
    var id: String
    var title: String
    /// SF Symbols。
    var symbol: String
    var metrics: [BenchmarkMetric]
}

enum BenchmarkCatalog {
    static let bank = BenchmarkGroup(
        id: "bank",
        title: "銀行",
        symbol: "building.columns",
        metrics: [
            BenchmarkMetric(
                key: "ldr", title: "預貸率", caption: "貸出金 ÷ 預金（期末）。高いほど預金を貸出に回している",
                kind: .percent, higherIsBetter: true,
                band: .higherBetter(lowBelow: 45, midFrom: 60, midTo: 60, highFrom: 75)),
            BenchmarkMetric(
                key: "ohr", title: "経費率（OHR）", caption: "経費 ÷ 業務粗利益。低いほど効率的",
                kind: .percent, higherIsBetter: false,
                band: .lowerBetter(highBelow: 55, midFrom: 65, midTo: 65, lowFrom: 75)),
            BenchmarkMetric(
                key: "deposits", title: "預金", caption: "期末残高", kind: .yen, higherIsBetter: true),
            BenchmarkMetric(
                key: "loans", title: "貸出金", caption: "期末残高", kind: .yen, higherIsBetter: true),
            BenchmarkMetric(
                key: "net_interest_income", title: "資金利益", caption: "貸出・有価証券の利ざや収益",
                kind: .yen, higherIsBetter: true),
            BenchmarkMetric(
                key: "net_fees_and_commissions", title: "役務取引等利益", caption: "手数料ビジネスの利益",
                kind: .yen, higherIsBetter: true),
            BenchmarkMetric(
                key: "gross_business_profit", title: "業務粗利益",
                caption: "資金・役務・特定取引・その他の合計", kind: .yen, higherIsBetter: true),
        ])

    /// 業種選択画面に出す順。
    static let groups: [BenchmarkGroup] = [bank]

    static func group(id: String) -> BenchmarkGroup? {
        groups.first { $0.id == id }
    }
}
