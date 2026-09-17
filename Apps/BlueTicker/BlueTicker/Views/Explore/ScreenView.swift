import SwiftUI

enum ScreenDisplayMetric: String, CaseIterable, Identifiable {
    case roic
    case operatingMargin = "operating_margin"
    case salesCagr3y = "sales_cagr_3y"
    case netDe = "net_de"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .roic: "ROIC"
        case .operatingMargin: "営業利益率"
        case .salesCagr3y: "売上CAGR"
        case .netDe: "ネットD/E"
        }
    }

    var band: MetricBand {
        switch self {
        case .operatingMargin:
            return .higherBetter(lowBelow: 3, midFrom: 5, midTo: 10, highFrom: 15)
        case .roic:
            return .higherBetter(lowBelow: 4, midFrom: 6, midTo: 8, highFrom: 10)
        case .salesCagr3y:
            return .higherBetter(lowBelow: 0, midFrom: 5, midTo: 10, highFrom: 15)
        case .netDe:
            return .lowerBetter(highBelow: 0, midFrom: 0, midTo: 1.0, lowFrom: 1.5)
        }
    }

    func format(_ value: Double?) -> String {
        switch self {
        case .operatingMargin, .roic, .salesCagr3y:
            return Format.percent(value)
        case .netDe:
            guard let value else { return "—" }
            return String(format: "%.1f倍", value)
        }
    }
}

struct ScreenView: View {
    @State private var selectedSectors: Set<String> = []
    @State private var presetMatched: [ScreenPreset: Int] = [:]

    var body: some View {
        Form {
            Section {
                sectorChips
                    .listRowBackground(Theme.elevated)
            } header: {
                HStack {
                    Text("業種")
                        .foregroundStyle(Theme.textMuted)
                    Spacer()
                    Button("全選択") { selectedSectors = Set(TSESector.catalog) }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                        .disabled(selectedSectors.count == TSESector.catalog.count)
                    Button("全解除") { selectedSectors.removeAll() }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                        .disabled(selectedSectors.isEmpty)
                }
                .textCase(nil)
            } footer: {
                Text("横にスライドして複数選べます。未選択は全業種です。")
                    .foregroundStyle(Theme.textMuted)
            }

            Section {
                ForEach(ScreenPreset.allCases) { preset in
                    NavigationLink(value: ScreenQuery(sectors: screenSectors, preset: preset)) {
                        presetRow(preset)
                    }
                    .listRowBackground(Theme.control)
                }
            } header: {
                Text("こんな企業を探す")
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .navigationTitle("条件検索")
        .bltChrome()
        .navigationDestination(for: ScreenQuery.self) { query in
            ScreenResultsView(sectors: query.sectors, preset: query.preset)
        }
        .task(id: screenSectors) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await loadPresetCounts()
        }
    }

    /// 未選択と全選択は同じ（業種フィルタなし）。複数はサーバーが 1 業種なので呼び出し側で OR する。
    private var screenSectors: [String] {
        if selectedSectors.isEmpty || selectedSectors.count == TSESector.catalog.count {
            return []
        }
        return selectedSectors.sorted()
    }

    private func presetTint(_ preset: ScreenPreset) -> Color {
        switch preset {
        case .quality: Theme.accent
        case .growth: Theme.growthTint
        case .healthyGrowth: Theme.positive
        }
    }

    private func presetRow(_ preset: ScreenPreset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SectorTag(sector: preset.title, selected: true, tint: presetTint(preset))
                Text(preset.descriptionText)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if let matched = presetMatched[preset] {
                    Text("\(matched)件")
                        .font(.footnote.monospacedDigit().weight(.semibold))
                        .foregroundStyle(matched == 0 ? Theme.textMuted : Theme.text)
                        .accessibilityLabel("\(matched)件")
                }
            }
            Text(preset.reasonText)
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.vertical, 6)
    }

    /// 件数は既存 `GET /v1/screen` の `matched`（`limit=1`）。未選択・全選択は 3 リクエスト。
    /// 業種を多く選ぶと業種×プリセットになるので、8 業種超は出さない。
    /// プリセットは直列（HAPIS 同時接続を増やさない。業種変更の debounce と合わせる）。
    private func loadPresetCounts() async {
        let sectors = screenSectors
        if sectors.count > 8 {
            presetMatched = [:]
            return
        }
        var next: [ScreenPreset: Int] = [:]
        for preset in ScreenPreset.allCases {
            guard !Task.isCancelled else { return }
            do {
                let response = try await APIClient.shared.screen(
                    sectors: sectors, filters: preset.filters, limit: 1)
                next[preset] = response.matched
            } catch {
                continue
            }
        }
        guard !Task.isCancelled else { return }
        presetMatched = next
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
}

private struct ScreenResultsView: View {
    var sectors: [String]
    var preset: ScreenPreset

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
                    systemImage: "building.2",
                    description: Text(errorMessage)
                )
            } else if items.isEmpty {
                ContentUnavailableView(
                    "該当する会社はありません",
                    systemImage: "building.2"
                )
            } else {
                List {
                    Section {
                        ForEach(items) { item in
                            NavigationLink(value: CompanyRef(item)) {
                                ScreenResultRow(item: item)
                            }
                            .listRowBackground(Theme.elevated)
                        }
                        if matched > items.count {
                            Text("上位 \(items.count) 件を表示（該当 \(matched) 件）")
                                .font(.footnote)
                                .foregroundStyle(Theme.textMuted)
                                .listRowBackground(Color.clear)
                        }
                    } footer: {
                        Text(preset.reasonText)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .navigationTitle(preset.title)
        .bltChrome()
        .task {
            guard !loaded else { return }
            await run()
        }
    }

    private func run() async {
        do {
            let response = try await APIClient.shared.screen(sectors: sectors, filters: preset.filters)
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
}

private struct ScreenResultRow: View {
    var item: ScreenItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompanyRowView(company: CompanyRef(item))
            ScreenMetricValuesView(item: item)
                .padding(.leading, 48)
        }
        .padding(.vertical, 2)
    }
}

private struct ScreenMetricValuesView: View {
    var item: ScreenItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(metricRows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(metricRows[index]) { metric in
                        let value = item.value(for: metric)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(metric.title)
                                .font(.caption2)
                                .foregroundStyle(Theme.textMuted)
                            Text(metric.format(value))
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(value.map { metric.band.color(for: $0) } ?? Theme.textMuted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(minWidth: 72, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var metricRows: [[ScreenDisplayMetric]] {
        let metrics = ScreenDisplayMetric.allCases
        return stride(from: 0, to: metrics.count, by: 2).map { start in
            Array(metrics[start..<min(start + 2, metrics.count)])
        }
    }
}

private extension ScreenItem {
    func value(for metric: ScreenDisplayMetric) -> Double? {
        switch metric {
        case .roic: roic
        case .operatingMargin: operatingMargin
        case .salesCagr3y: salesCagr3y
        case .netDe: netDe
        }
    }
}
