import SwiftUI

enum ScreenMetric: String, CaseIterable, Identifiable {
    case operatingMargin = "operating_margin"
    case roic
    case roe
    case sales
    case salesGrowth = "sales_growth"
    case grossMargin = "gross_profit_margin"
    case netDe = "net_de"

    var id: String { rawValue }

    static let alwaysShown: [ScreenMetric] = [.operatingMargin, .roic, .roe]
    static let optional: [ScreenMetric] = [.sales, .salesGrowth, .grossMargin, .netDe]

    var title: String {
        switch self {
        case .operatingMargin: "営業利益率"
        case .roic: "ROIC"
        case .roe: "ROE"
        case .sales: "売上高"
        case .salesGrowth: "売上増加率"
        case .grossMargin: "粗利率"
        case .netDe: "ネットD/E"
        }
    }

    var sliderMin: Double {
        switch self {
        case .sales: 0
        case .salesGrowth: -30
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
        case .salesGrowth: 80
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
        case .grossMargin, .operatingMargin, .roic, .roe, .salesGrowth: 0.5
        case .netDe: 0.1
        }
    }

    var band: MetricBand {
        switch self {
        case .sales:
            return .yellowThenGreen(greenFrom: 10_000)
        case .salesGrowth:
            return .higherBetter(lowBelow: -5, midFrom: 0, midTo: 8, highFrom: 15)
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
        case .grossMargin, .operatingMargin, .roic, .roe, .salesGrowth:
            return String(format: "%.1f%%", value)
        case .netDe:
            return String(format: "%.1f倍", value)
        }
    }
}

struct ScreenView: View {
    @State private var selectedSectors: Set<String> = []
    @State private var ranges: [ScreenMetric: [Double]] = [:]
    @State private var extraMetrics: [ScreenMetric] = []
    @State private var showResults = false

    private var availableOptional: [ScreenMetric] {
        ScreenMetric.optional.filter { !extraMetrics.contains($0) }
    }

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
                ForEach(ScreenMetric.alwaysShown) { metric in
                    metricBlock(metric) {
                        Text(metric.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                    }
                    .listRowBackground(Theme.control)
                }
                ForEach(extraMetrics) { metric in
                    extraMetricRow(metric)
                        .listRowBackground(Theme.control)
                }
                if !availableOptional.isEmpty {
                    addMetricRow
                        .listRowBackground(Theme.control)
                }
            } header: {
                Text("指標")
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .navigationTitle("条件検索")
        .bltChrome()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("検索") {
                    showResults = true
                }
                .foregroundStyle(Theme.text)
            }
        }
        .navigationDestination(isPresented: $showResults) {
            ScreenResultsView()
        }
    }

    private var addMetricRow: some View {
        Button {
            guard let next = availableOptional.first else { return }
            extraMetrics.append(next)
        } label: {
            HStack {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                Text("追加")
                    .font(.body.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
    }

    private func extraMetricRow(_ metric: ScreenMetric) -> some View {
        metricBlock(metric) {
            extraMetricTitle(metric)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                removeExtra(metric)
            } label: {
                Image(systemName: "xmark")
            }
            .tint(Theme.negative)
        }
    }

    private func extraMetricTitle(_ metric: ScreenMetric) -> some View {
        let choices = [metric] + availableOptional
        return Menu {
            ForEach(choices) { option in
                Button {
                    replaceExtra(metric, with: option)
                } label: {
                    if option == metric {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(metric.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.text)
            }
        }
        .buttonStyle(.plain)
    }

    private func metricBlock<Title: View>(
        _ metric: ScreenMetric,
        @ViewBuilder title: () -> Title
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title()
            DualRangeSlider(
                rangeMin: metric.sliderMin,
                rangeMax: metric.sliderMax,
                step: metric.step,
                values: rangeBinding(metric),
                formatValue: metric.format,
                band: metric.band
            )
        }
        .padding(.vertical, 8)
    }

    private var sectorChips: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.groupedCornerRadius, style: .continuous)
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(packedSectorRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { sector in
                            sectorChip(sector)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
        }
        .scrollClipDisabled()
        .clipShape(shape)
        .padding(Theme.groupedContentInset)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Theme.elevated)
        .containerShape(shape)
    }

    private var packedSectorRows: [[String]] {
        let catalog = TSESector.catalog
        let rowCount = 3
        let perRow = Int(ceil(Double(catalog.count) / Double(rowCount)))
        return (0..<rowCount).compactMap { row in
            let start = row * perRow
            guard start < catalog.count else { return nil }
            let end = min(start + perRow, catalog.count)
            return Array(catalog[start..<end])
        }
    }

    private func sectorChip(_ sector: String) -> some View {
        let selected = selectedSectors.contains(sector)
        return Button {
            if selected {
                selectedSectors.remove(sector)
            } else {
                selectedSectors.insert(sector)
            }
        } label: {
            SectorTag(sector: sector, selected: selected)
        }
        .buttonStyle(.plain)
    }

    private func rangeBinding(_ metric: ScreenMetric) -> Binding<[Double]> {
        Binding(
            get: { ranges[metric] ?? [metric.sliderMin, metric.sliderMax] },
            set: { ranges[metric] = $0 }
        )
    }

    private func replaceExtra(_ current: ScreenMetric, with metric: ScreenMetric) {
        guard let index = extraMetrics.firstIndex(of: current) else { return }
        extraMetrics[index] = metric
        if current != metric {
            ranges[current] = nil
        }
    }

    private func removeExtra(_ metric: ScreenMetric) {
        extraMetrics.removeAll { $0 == metric }
        ranges[metric] = nil
    }
}

private struct ScreenResultsView: View {
    var body: some View {
        ContentUnavailableView(
            "該当する会社はありません",
            systemImage: "slider.horizontal.3",
            description: Text("横断検索は未接続です。Screen REST が公開されるまで結果は返しません。")
        )
        .navigationTitle("検索結果")
        .bltChrome()
    }
}
