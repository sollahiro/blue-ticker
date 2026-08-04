import Charts
import SwiftUI

/// 正面: 選択中年度の事業利益増減ウォーターフォール（何が起きたか）。
/// バー下のラベルをタップすると `onSelectMetric` でその項目を選び、呼び出し側が側面へ切り替える。
struct FrontFaceView: View {
    var year: WaterfallYear
    var onSelectMetric: (WaterfallMetric) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(year.financialPeriod ?? year.fyEnd ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let bars = year.businessProfitWaterfallBars() {
                Chart(bars) { bar in
                    BarMark(
                        x: .value("項目", bar.label),
                        yStart: .value("開始", bar.cumulativeStart),
                        yEnd: .value("終了", bar.cumulativeStart + bar.value)
                    )
                    .foregroundStyle(color(for: bar))
                    .annotation(position: .top) {
                        Text(formatted(bar.value))
                            .font(.caption2)
                    }
                }
                .chartXAxis(.hidden)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 8)

                HStack(spacing: 0) {
                    ForEach(bars) { bar in
                        Button {
                            onSelectMetric(bar.metric)
                        } label: {
                            Text(bar.label)
                                .font(.caption2)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(color(for: bar))
                    }
                }
            } else {
                ContentUnavailableView(
                    "前年データがありません",
                    systemImage: "chart.bar.xaxis",
                    description: Text("この期は増減分解を計算できません(最古期など)。"))
            }
        }
    }

    private func color(for bar: WaterfallBar) -> Color {
        switch bar.kind {
        case .start, .end: return .accentColor
        case .delta: return bar.value >= 0 ? .green : .red
        }
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%+.0f", value)
    }
}
