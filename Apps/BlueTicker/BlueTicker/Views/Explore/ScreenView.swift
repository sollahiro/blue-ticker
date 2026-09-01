import SwiftUI

enum ScreenMetric: String, CaseIterable, Identifiable {
    case sales
    case grossMargin = "gross_profit_margin"
    case operatingMargin = "operating_margin"
    case roic
    case roe
    case netDe = "net_de"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sales: "売上高"
        case .grossMargin: "粗利率"
        case .operatingMargin: "営業利益率"
        case .roic: "ROIC"
        case .roe: "ROE"
        case .netDe: "ネットD/E"
        }
    }

    var sliderMin: Double {
        switch self {
        case .sales: 0
        case .grossMargin: 0
        case .operatingMargin: -20
        case .roic: -20
        case .roe: -20
        case .netDe: -2
        }
    }

    var sliderMax: Double {
        switch self {
        case .sales: 20_000_000
        case .grossMargin: 80
        case .operatingMargin: 50
        case .roic: 50
        case .roe: 50
        case .netDe: 8
        }
    }

    var step: Double {
        switch self {
        case .sales: 10_000
        case .grossMargin, .operatingMargin, .roic, .roe: 0.5
        case .netDe: 0.1
        }
    }

    var band: MetricBand {
        switch self {
        case .sales:
            return .none
        case .grossMargin:
            return .higherBetter(lowBelow: 15, midFrom: 20, midTo: 40, highFrom: 50)
        case .operatingMargin:
            return .higherBetter(lowBelow: 3, midFrom: 5, midTo: 10, highFrom: 15)
        case .roic:
            return .higherBetter(lowBelow: 4, midFrom: 6, midTo: 8, highFrom: 10)
        case .roe:
            return .higherBetter(lowBelow: 5, midFrom: 8, midTo: 10, highFrom: 15)
        case .netDe:
            return .lowerBetter(highBelow: 0, midFrom: 0, midTo: 1.0, lowFrom: 1.5)
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .sales:
            return Format.okuYen(value)
        case .grossMargin, .operatingMargin, .roic, .roe:
            return String(format: "%.1f%%", value)
        case .netDe:
            return String(format: "%.1f倍", value)
        }
    }
}

struct ScreenView: View {
    @State private var selectedSectors: Set<String> = []
    @State private var ranges: [ScreenMetric: [Double]] = [:]
    @State private var didQuery = false

    var body: some View {
        Form {
            Section {
                sectorChips
                    .listRowBackground(Theme.elevated)
            } header: {
                Text("業種")
                    .foregroundStyle(Theme.textMuted)
            } footer: {
                Text("横にスライドして複数選べます。")
                    .foregroundStyle(Theme.textMuted)
            }

            Section {
                legend
                    .listRowBackground(Theme.elevated)
                ForEach(ScreenMetric.allCases) { metric in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(metric.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                        DualRangeSlider(
                            rangeMin: metric.sliderMin,
                            rangeMax: metric.sliderMax,
                            step: metric.step,
                            values: rangeBinding(metric),
                            formatValue: metric.format,
                            band: metric.band
                        )
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Theme.elevated)
                }
            } header: {
                Text("指標")
                    .foregroundStyle(Theme.textMuted)
            }

            Section {
                Button("絞り込む") {
                    didQuery = true
                }
                .foregroundStyle(Theme.accent)
                .listRowBackground(Theme.elevated)
                if didQuery {
                    Text("横断検索は未接続です。Screen REST が公開されるまで結果は返しません。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                        .listRowBackground(Theme.elevated)
                }
            } footer: {
                Text("ソートは ROIC 降順、件数は 50 件で固定です。売上増加率は横断検索の対象外です。")
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .navigationTitle("条件")
        .bltChrome()
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(Theme.bandLowColor, "改善を要する")
            legendItem(Theme.bandMidColor, "標準")
            legendItem(Theme.bandHighColor, "優良")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(Theme.textMuted)
    }

    private func legendItem(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
        }
    }

    private var sectorChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TSESector.catalog, id: \.self) { sector in
                    let selected = selectedSectors.contains(sector)
                    Button {
                        if selected {
                            selectedSectors.remove(sector)
                        } else {
                            selectedSectors.insert(sector)
                        }
                    } label: {
                        Text(sector)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.sectorColor(sector).opacity(selected ? 1 : 0.45))
                            .foregroundStyle(.white)
                            .overlay {
                                if selected {
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Theme.accent, lineWidth: 2)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private func rangeBinding(_ metric: ScreenMetric) -> Binding<[Double]> {
        Binding(
            get: { ranges[metric] ?? [metric.sliderMin, metric.sliderMax] },
            set: { ranges[metric] = $0 }
        )
    }
}
