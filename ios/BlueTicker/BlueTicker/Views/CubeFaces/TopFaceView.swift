import SwiftUI

/// 上面: 直近の前年比較(トランジション)を年度分だけ列として並べた俯瞰(なぜその数字になったか、を年度をまたいで比較する)。
/// 1列 = 1組の前年比較。列内は上から「前期事業利益(start)→売上要因→利益率変化→販管費(delta)→当期事業利益(end)」
/// を縦に並べたもの(正面 FrontFaceView の水平バーと同じ `businessProfitWaterfallBars()` を再利用)。
/// 円の大きさは金額の大きさ、色は符号(プラス=緑/マイナス=赤)を表す。タップすると `onSelectMetric` で
/// その項目を選び、呼び出し側が側面へ切り替える。
struct TopFaceView: View {
    var response: WaterfallResponse
    var onSelectMetric: (WaterfallMetric) -> Void

    private struct Transition {
        var period: String
        var bars: [WaterfallBar]
    }

    private var transitions: [Transition] {
        response.years.reversed().compactMap { year in
            guard let bars = year.businessProfitWaterfallBars() else { return nil }
            return Transition(period: year.financialPeriod ?? year.fyEnd ?? "-", bars: bars)
        }
    }

    private var maxAbsValue: Double {
        transitions.flatMap(\.bars).map { abs($0.value) }.max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("前年比較の一覧(タップで推移面へ)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if transitions.isEmpty {
                ContentUnavailableView(
                    "計算ロジックを表示できません", systemImage: "function",
                    description: Text("前年差を計算できる年度がありません。"))
            } else {
                HStack(alignment: .center, spacing: 12) {
                    ForEach(transitions, id: \.period) { transition in
                        VStack(spacing: 10) {
                            ForEach(transition.bars) { bar in
                                Button {
                                    onSelectMetric(bar.metric)
                                } label: {
                                    Circle()
                                        .fill(bar.value >= 0 ? .green : .red)
                                        .frame(width: diameter(for: bar.value), height: diameter(for: bar.value))
                                }
                                .buttonStyle(.plain)
                            }
                            Text(transition.period)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// 面積(=円の見た目の大きさ)が金額に比例するよう、直径は平方根スケールにする。
    private func diameter(for value: Double) -> CGFloat {
        let maxDiameter: CGFloat = 32
        let minDiameter: CGFloat = 6
        guard maxAbsValue > 0 else { return minDiameter }
        let ratio = abs(value) / maxAbsValue
        return max(minDiameter, maxDiameter * CGFloat(ratio.squareRoot()))
    }
}
