import SwiftUI

/// 上面: 選択中年度の事業利益増減の計算ロジック(なぜその数字になったか)。
/// カードをタップすると `onSelectMetric` でその構成要素を選び、呼び出し側が側面へ切り替える
/// (`docs/ios-app-concept.md` の「上面のカードを選ぶ→側面がその要素の推移に切り替わる」)。
/// 計算ロジックの見せ方は式表示/カード表示が未確定事項だったため、まずカード表示で実装している。
struct TopFaceView: View {
    var year: WaterfallYear
    var onSelectMetric: (WaterfallMetric) -> Void

    private struct Component {
        var metric: WaterfallMetric
        var value: Double
    }

    private var components: [Component]? {
        guard let sales = year.salesChangeImpact,
            let margin = year.grossMarginChangeImpact,
            let sga = year.sgaChangeImpact
        else { return nil }
        return [
            Component(metric: .salesImpact, value: sales),
            Component(metric: .marginImpact, value: margin),
            Component(metric: .sgaImpact, value: sga),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("事業利益前年差の内訳")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let components, let change = year.businessProfitChange {
                Text("前年差合計: \(String(format: "%+.0f", change)) 百万円")
                    .font(.headline)

                VStack(spacing: 8) {
                    ForEach(components, id: \.metric) { component in
                        Button {
                            onSelectMetric(component.metric)
                        } label: {
                            HStack {
                                Text(component.metric.displayName)
                                    .font(.body)
                                Spacer()
                                Text(String(format: "%+.0f", component.value))
                                    .font(.body.monospacedDigit())
                                    .foregroundStyle(component.value >= 0 ? .green : .red)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ContentUnavailableView(
                    "計算ロジックを表示できません", systemImage: "function",
                    description: Text("この期は増減分解を計算できません(最古期など)。"))
            }
        }
    }
}
