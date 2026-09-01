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
    @State private var selectedYear: FinancialsYear?

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
        ScrollView {
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
                yearBars(response.years)
                if let selectedYear {
                    factorChart(selectedYear)
                } else {
                    Text(factorPrompt)
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(16)
        }
        .background(Theme.card)
        .padding(16)
    }

    private func yearBars(_ years: [FinancialsYear]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(years) { year in
                Button {
                    selectedYear = year
                } label: {
                    HStack {
                        Text(Format.fy(year.fyEnd))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 48, alignment: .leading)
                        bar(for: year)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func bar(for year: FinancialsYear) -> some View {
        let value = metricValue(year)
        let width = barWidth(value, among: response?.years ?? [])
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.positive)
                    .frame(width: max(width, 4), height: 18)
                Text(metricLabel(year))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.text)
            }
            if metric == .businessProfit, let margin = year.businessProfitMargin {
                Text(String(format: "%.2f%%", margin))
                    .font(.caption2)
                    .foregroundStyle(Theme.margin)
            }
        }
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
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(Format.fy(year.fyEnd)) の要因分解")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
            ForEach(spec.factors, id: \.name) { factor in
                HStack {
                    Text(factor.name)
                        .font(.caption)
                        .foregroundStyle(Theme.text)
                        .frame(width: 88, alignment: .leading)
                    RoundedRectangle(cornerRadius: 2)
                        .fill((factor.value ?? 0) >= 0 ? Theme.positive : Theme.negative)
                        .frame(width: factorBarWidth(factor.value, unit: spec.unit), height: 16)
                    Text(spec.format(factor.value))
                        .font(.caption.monospacedDigit())
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
        var unit: FactorUnit
        var format: (Double?) -> String
        var summary: String?
    }

    private enum FactorUnit {
        case millionYen
        case percentPoints
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
                unit: .millionYen,
                format: Format.millionYen,
                summary: year.businessProfitChange.map { "事業利益 前年差 \(Format.millionYen($0))" }
            )
        case .roic:
            return FactorSpec(
                factors: [
                    FactorRow(name: "利益率要因", value: year.roicMarginEffect),
                    FactorRow(name: "回転率要因", value: year.roicTurnoverEffect),
                ],
                unit: .percentPoints,
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
                unit: .percentPoints,
                format: Format.percentPoints,
                summary: year.roeDelta.map { "ROE 前年差 \(Format.percentPoints($0))" }
            )
        }
    }

    private func factorBarWidth(_ value: Double?, unit: FactorUnit) -> CGFloat {
        let magnitude = abs(value ?? 0)
        switch unit {
        case .millionYen:
            return max(magnitude.squareRoot() * 4, 4)
        case .percentPoints:
            return max(magnitude * 12, 4)
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
            return Format.okuYen(year.businessProfit)
        case .roic:
            return year.roic.map { String(format: "%.2f%%", $0) } ?? "—"
        case .roe:
            return year.roe.map { String(format: "%.2f%%", $0) } ?? "—"
        }
    }

    private func barWidth(_ value: Double, among years: [FinancialsYear]) -> CGFloat {
        let peak = years.map(metricValue).map(abs).max() ?? 1
        guard peak > 0 else { return 4 }
        return CGFloat(abs(value) / peak) * 180
    }

    private func load() async {
        do {
            response = try await APIClient.shared.waterfall(code: code)
            errorMessage = nil
            selectedYear = response?.years.first
        } catch APIClientError.http(let status, let message) where status == 404 {
            errorMessage = message.isEmpty ? "財務データは未集計です" : message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
