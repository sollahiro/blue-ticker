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
            return String(format: "%.1f", value) + "%"
        case .netDe:
            return String(format: "%.1f倍", value)
        }
    }
}

struct ScreenView: View {
    @State private var selectedSectors: Set<String> = []
    @State private var ranges: [ScreenMetric: [Double]] = [:]
    @State private var extraMetrics: [ScreenMetric] = []

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
                NavigationLink(value: ScreenQuery(sectors: screenSectors, filters: metricFilters)) {
                    Text("検索")
                }
                .foregroundStyle(Theme.text)
            }
        }
        .navigationDestination(for: ScreenQuery.self) { query in
            ScreenResultsView(sectors: query.sectors, filters: query.filters)
        }
    }

    /// 未選択と全選択は同じ（業種フィルタなし）。複数はサーバーが 1 業種なので呼び出し側で OR する。
    private var screenSectors: [String] {
        if selectedSectors.isEmpty || selectedSectors.count == TSESector.catalog.count {
            return []
        }
        return selectedSectors.sorted()
    }

    private var metricFilters: [ScreenMetricFilter] {
        (ScreenMetric.alwaysShown + extraMetrics).compactMap { metric in
            let values = ranges[metric] ?? [metric.sliderMin, metric.sliderMax]
            let lo = values[0]
            let hi = values[1]
            let sendMin = lo > metric.sliderMin + metric.step / 2
            let sendMax = hi < metric.sliderMax - metric.step / 2
            guard sendMin || sendMax else { return nil }
            return ScreenMetricFilter(
                key: metric.rawValue,
                min: sendMin ? lo : nil,
                max: sendMax ? hi : nil)
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
        let outer = RoundedRectangle(cornerRadius: Theme.groupedCornerRadius, style: .continuous)
        let inner = RoundedRectangle(cornerRadius: Theme.groupedInnerCornerRadius, style: .continuous)
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
        .clipShape(inner)
        .padding(Theme.groupedContentInset)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Theme.elevated)
        .containerShape(outer)
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
    var sectors: [String]
    var filters: [ScreenMetricFilter]

    @State private var items: [ScreenItem] = []
    @State private var matched = 0
    @State private var errorMessage: String?
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(
                    "検索できません",
                    systemImage: "slider.horizontal.3",
                    description: Text(errorMessage)
                )
            } else if items.isEmpty {
                ContentUnavailableView(
                    "該当する会社はありません",
                    systemImage: "slider.horizontal.3"
                )
            } else {
                List {
                    ForEach(items) { item in
                        NavigationLink(value: CompanyRef(item)) {
                            ScreenResultRow(item: item, metrics: shownMetrics)
                        }
                        .listRowBackground(Theme.elevated)
                    }
                    if matched > items.count {
                        Text("上位 \(items.count) 件を表示（該当 \(matched) 件）")
                            .font(.footnote)
                            .foregroundStyle(Theme.textMuted)
                            .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .navigationTitle("検索結果")
        .bltChrome()
        .task {
            guard !loaded else { return }
            await run()
        }
    }

    private func run() async {
        do {
            let response = try await APIClient.shared.screen(sectors: sectors, filters: filters)
            items = response.items
            matched = response.matched
            errorMessage = nil
        } catch APIClientError.http(let status, let message) where status == 404 {
            items = []
            matched = 0
            errorMessage = message.isEmpty ? "Screen 索引は未生成です" : message
        } catch {
            items = []
            matched = 0
            errorMessage = error.localizedDescription
        }
        loaded = true
    }

    /// 並びは ROIC 固定。スライダーで送った指標は条件の並び（既定3つ → 追加）で出す。
    private var shownMetrics: [ScreenMetric] {
        let requested = Set(filters.map(\.key))
        var ordered: [ScreenMetric] = []
        var seen = Set<ScreenMetric>()
        func add(_ metric: ScreenMetric) {
            if seen.insert(metric).inserted {
                ordered.append(metric)
            }
        }
        for metric in ScreenMetric.alwaysShown {
            if metric == .roic || requested.contains(metric.rawValue) {
                add(metric)
            }
        }
        for metric in ScreenMetric.optional where requested.contains(metric.rawValue) {
            add(metric)
        }
        return ordered
    }
}

private struct ScreenResultRow: View {
    var item: ScreenItem
    var metrics: [ScreenMetric]

    private var visibleMetrics: [ScreenMetric] {
        metrics.filter { item.value(for: $0) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompanyRowView(company: CompanyRef(item))
            if !visibleMetrics.isEmpty {
                ScreenMetricValuesView(item: item, metrics: visibleMetrics)
                    .padding(.leading, 48)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ScreenMetricValuesView: View {
    var item: ScreenItem
    var metrics: [ScreenMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(metricRows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(metricRows[index]) { metric in
                        if let value = item.value(for: metric) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(metric.title)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textMuted)
                                Text(metric.format(value))
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(metric.band.color(for: value))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            .frame(minWidth: 72, alignment: .leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var metricRows: [[ScreenMetric]] {
        stride(from: 0, to: metrics.count, by: 3).map { start in
            Array(metrics[start..<min(start + 3, metrics.count)])
        }
    }
}

private extension ScreenItem {
    func value(for metric: ScreenMetric) -> Double? {
        switch metric {
        case .sales: sales
        case .salesGrowth: salesGrowth
        case .grossMargin: grossProfitMargin
        case .operatingMargin: operatingMargin
        case .roic: roic
        case .roe: roe
        case .netDe: netDe
        }
    }
}
