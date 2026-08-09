import Charts
import SwiftUI

/// 側面: 正面(または上面)で選択中の項目の5年推移(どう推移してきたか)。
struct SideFaceView: View {
    var metric: WaterfallMetric
    var response: WaterfallResponse

    private var points: [(period: String, value: Double?)] {
        response.series(for: metric)
    }

    /// 事業利益はアクセントカラーで統一(正面 FrontFaceView・上面 TopFaceView と同じ)。
    /// 影響要因は符号が期によって変わりうる単一の線のため、緑/赤ではなく中立色にする。
    private var seriesColor: Color {
        metric == .businessProfit ? .accentColor : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(metric.displayName) の推移")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            let available = points.filter { $0.value != nil }
            if available.isEmpty {
                ContentUnavailableView(
                    "推移データがありません", systemImage: "chart.xyaxis.line",
                    description: Text("この項目の時系列は算出できません。"))
            } else {
                Chart(points, id: \.period) { point in
                    if let value = point.value {
                        LineMark(x: .value("期", point.period), y: .value(metric.displayName, value))
                            .symbol(.circle)
                        PointMark(x: .value("期", point.period), y: .value(metric.displayName, value))
                            .annotation(position: .top) {
                                Text(String(format: "%.0f", value))
                                    .font(.caption2)
                            }
                    }
                }
                .foregroundStyle(seriesColor)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 8)
            }
        }
    }
}
