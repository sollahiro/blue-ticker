import Charts
import SwiftUI

enum BreakdownMetric: String, CaseIterable, Identifiable {
    case businessProfit
    case roic
    case roe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .businessProfit: "事業利益"
        case .roic: "ROIC"
        case .roe: "ROE"
        }
    }
}

struct BreakdownView: View {
    var code: String
    @State private var response: FinancialsResponse?
    @State private var errorMessage: String?
    @State private var metric: BreakdownMetric = .businessProfit
    @State private var selectedYearID: String?

    var body: some View {
        Group {
            if let response {
                content(response)
            } else if let errorMessage {
                TickerStubView(title: "分解", detail: errorMessage)
            } else {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private func content(_ response: FinancialsResponse) -> some View {
        let years = Format.chronological(response.years)
        let selectedYear = years.first { $0.id == selectedYearID }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("事業利益は売上総利益 − 販管費です。開示の営業利益行ではありません。")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                HStack(spacing: 8) {
                    ForEach(BreakdownMetric.allCases) { item in
                        Button(item.title) { metric = item }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(metric == item ? Theme.accent : Theme.idleTab)
                            .foregroundStyle(metric == item ? Theme.shell : Theme.text)
                    }
                }
                if metric == .businessProfit {
                    yearBars(years)
                } else {
                    ratioChart(years)
                }
                if let selectedYear {
                    factorChart(selectedYear)
                } else {
                    Text(factorPrompt)
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
        .padding(16)
    }

    private func yearBars(_ years: [FinancialsYear]) -> some View {
        let peak = years.map(metricValue).map(abs).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(years) { year in
                let selected = year.id == selectedYearID
                Button {
                    selectedYearID = year.id
                } label: {
                    HStack(spacing: 8) {
                        Text(Format.fy(year.fyEnd))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 48, alignment: .leading)
                        SignedBar(value: metricValue(year), peak: peak)
                            .frame(height: 18)
                        Text(metricLabel(year))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.text)
                            .frame(width: 88, alignment: .trailing)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(selected ? Theme.accent.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func ratioChart(_ years: [FinancialsYear]) -> some View {
        let labels = years.map { Format.fy($0.fyEnd) }
        return Chart {
            RuleMark(x: .value("zero", 0))
                .foregroundStyle(Theme.text)
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(Array(years.enumerated()), id: \.element.id) { index, year in
                LineMark(
                    x: .value(metric.title, metricValue(year)),
                    y: .value("年度", index)
                )
                .foregroundStyle(Theme.accent)
                .interpolationMethod(.catmullRom)
                PointMark(
                    x: .value(metric.title, metricValue(year)),
                    y: .value("年度", index)
                )
                .foregroundStyle(year.id == selectedYearID ? Theme.text : Theme.accent)
                .symbolSize(year.id == selectedYearID ? 80 : 40)
            }
        }
        .chartYScale(domain: .automatic(reversed: true))
        .chartXAxis {
            AxisMarks(position: .bottom) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Theme.textMuted.opacity(0.35))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(Format.percent(number, digits: 1))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: Array(years.indices)) { value in
                AxisValueLabel {
                    if let index = value.as(Int.self), labels.indices.contains(index) {
                        Text(labels[index])
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return }
                        let y = location.y - geo[plot].origin.y
                        let index: Int?
                        if let i: Int = proxy.value(atY: y) {
                            index = i
                        } else if let d: Double = proxy.value(atY: y) {
                            index = Int(d.rounded())
                        } else {
                            index = nil
                        }
                        guard let index, years.indices.contains(index) else { return }
                        selectedYearID = years[index].id
                    }
            }
        }
        .frame(height: CGFloat(max(160, years.count * 36)))
        .padding(.top, 4)
    }

    private var factorPrompt: String {
        switch metric {
        case .businessProfit:
            return "年を選ぶと売上要因・利益率要因・販管費要因を表示します。"
        case .roic:
            return "年を選ぶと利益率要因・回転率要因を表示します。"
        case .roe:
            return "年を選ぶと純利益率要因・回転率要因・レバレッジ要因を表示します。"
        }
    }

    private func factorChart(_ year: FinancialsYear) -> some View {
        let spec = factorSpec(year)
        let peak = spec.factors.map { abs($0.value ?? 0) }.max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(Format.fy(year.fyEnd)) の要因分解")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
            ForEach(spec.factors) { factor in
                HStack(spacing: 8) {
                    Text(factor.name)
                        .font(.caption)
                        .foregroundStyle(Theme.text)
                        .frame(width: 88, alignment: .leading)
                    MagnitudeBar(value: factor.value ?? 0, peak: peak)
                        .frame(height: 16)
                    Text(spec.format(factor.value))
                        .font(.caption.monospacedDigit())
                        .frame(width: 88, alignment: .trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            if let summary = spec.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.top, 8)
    }

    private struct FactorRow: Identifiable {
        var name: String
        var value: Double?
        var id: String { name }
    }

    private struct FactorSpec {
        var factors: [FactorRow]
        var format: (Double?) -> String
        var summary: String?
    }

    private func factorSpec(_ year: FinancialsYear) -> FactorSpec {
        switch metric {
        case .businessProfit:
            return FactorSpec(
                factors: [
                    FactorRow(name: "売上要因", value: year.salesChangeImpact),
                    FactorRow(name: "利益率要因", value: year.grossMarginChangeImpact),
                    FactorRow(name: "販管費要因", value: year.sgaChangeImpact),
                ],
                format: Format.autoYen,
                summary: year.businessProfitChange.map { "事業利益 前年差 \(Format.autoYen($0))" }
            )
        case .roic:
            return FactorSpec(
                factors: [
                    FactorRow(name: "利益率要因", value: year.roicMarginEffect),
                    FactorRow(name: "回転率要因", value: year.roicTurnoverEffect),
                ],
                format: Format.percentPoints,
                summary: year.roicDelta.map { "ROIC 前年差 \(Format.percentPoints($0))" }
            )
        case .roe:
            return FactorSpec(
                factors: [
                    FactorRow(name: "純利益率要因", value: year.roeNetMarginEffect),
                    FactorRow(name: "回転率要因", value: year.roeAssetTurnoverEffect),
                    FactorRow(name: "レバレッジ要因", value: year.roeLeverageEffect),
                ],
                format: Format.percentPoints,
                summary: year.roeDelta.map { "ROE 前年差 \(Format.percentPoints($0))" }
            )
        }
    }

    private func metricValue(_ year: FinancialsYear) -> Double {
        switch metric {
        case .businessProfit: year.businessProfit ?? 0
        case .roic: year.roic ?? 0
        case .roe: year.roe ?? 0
        }
    }

    private func metricLabel(_ year: FinancialsYear) -> String {
        switch metric {
        case .businessProfit:
            return Format.autoYen(year.businessProfit)
        case .roic:
            return Format.percent(year.roic, digits: 2)
        case .roe:
            return Format.percent(year.roe, digits: 2)
        }
    }

    private func load() async {
        do {
            let loaded = try await APIClient.shared.waterfall(code: code)
            response = loaded
            errorMessage = nil
            if selectedYearID == nil {
                selectedYearID = Format.chronological(loaded.years).last?.id
            }
        } catch APIClientError.http(let status, let message) where status == 404 {
            errorMessage = message.isEmpty ? "財務データは未集計です" : message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 年次バー。0 を中央に置き、マイナスは左、プラスは右へ伸ばす。
private struct SignedBar: View {
    var value: Double
    var peak: Double

    var body: some View {
        GeometryReader { geo in
            let mid = geo.size.width / 2
            let magnitude = peak > 0 ? CGFloat(abs(value) / peak) * mid : 0
            let barWidth = value == 0 ? 0 : max(magnitude, 4)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.idleTab.opacity(0.55))
                    .frame(width: geo.size.width, height: geo.size.height)
                Rectangle()
                    .fill(Theme.text)
                    .frame(width: 1, height: geo.size.height)
                    .offset(x: mid)
                if value > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.positive)
                        .frame(width: barWidth, height: geo.size.height)
                        .offset(x: mid)
                } else if value < 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.negative)
                        .frame(width: barWidth, height: geo.size.height)
                        .offset(x: mid - barWidth)
                }
            }
        }
    }
}

/// 要因分解。符号に関わらず右へ伸ばし、色でプラス／マイナスを示す。
private struct MagnitudeBar: View {
    var value: Double
    var peak: Double

    var body: some View {
        GeometryReader { geo in
            let width = peak > 0 ? max(CGFloat(abs(value) / peak) * geo.size.width, value == 0 ? 0 : 4) : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.idleTab.opacity(0.55))
                    .frame(width: geo.size.width, height: geo.size.height)
                RoundedRectangle(cornerRadius: 2)
                    .fill(value >= 0 ? Theme.positive : Theme.negative)
                    .frame(width: width, height: geo.size.height)
            }
        }
    }
}
