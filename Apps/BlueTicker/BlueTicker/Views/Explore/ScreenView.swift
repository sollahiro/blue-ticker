import SwiftUI

enum ScreenDisplayMetric: String, CaseIterable, Identifiable {
    case roic
    case operatingMargin = "operating_margin"
    case salesCagr3y = "sales_cagr_3y"
    case netDe = "net_de"
    case cfoMargin = "cfo_margin"
    case fcf
    case operatingMarginCagr3y = "operating_margin_cagr_3y"
    case roicCagr3y = "roic_cagr_3y"
    case payoutRatio = "payout_ratio"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .roic: "ROIC"
        case .operatingMargin: "営業利益率"
        case .salesCagr3y: "売上CAGR"
        case .netDe: "ネットD/E"
        case .cfoMargin: "営業CFマージン"
        case .fcf: "FCF"
        case .operatingMarginCagr3y: "営業利益率 年変化"
        case .roicCagr3y: "ROIC 年変化"
        case .payoutRatio: "配当性向3年平均"
        }
    }

    var band: MetricBand {
        switch self {
        case .operatingMargin, .cfoMargin:
            return .higherBetter(lowBelow: 3, midFrom: 5, midTo: 10, highFrom: 15)
        case .roic:
            return .higherBetter(lowBelow: 4, midFrom: 6, midTo: 8, highFrom: 10)
        case .salesCagr3y:
            return .higherBetter(lowBelow: 0, midFrom: 5, midTo: 10, highFrom: 15)
        case .netDe:
            return .lowerBetter(highBelow: 0, midFrom: 0, midTo: 1.0, lowFrom: 1.5)
        case .fcf:
            return .higherBetter(lowBelow: 0, midFrom: 0, midTo: 0, highFrom: 0)
        case .operatingMarginCagr3y, .roicCagr3y:
            return .higherBetter(lowBelow: 0, midFrom: 1, midTo: 2, highFrom: 3)
        case .payoutRatio:
            // 配当性向は高低どちらが良いとも言えないため色で序列を付けない。
            return .none
        }
    }

    func format(_ value: Double?) -> String {
        switch self {
        case .operatingMargin, .roic, .salesCagr3y, .cfoMargin, .payoutRatio:
            return Format.percent(value)
        case .netDe:
            guard let value else { return "—" }
            return String(format: "%.1f倍", value)
        case .fcf:
            return Format.autoYen(value)
        case .operatingMarginCagr3y, .roicCagr3y:
            guard let value else { return "—" }
            return String(format: "%+.1fpp/年", value)
        }
    }
}

extension ScreenPreset {
    /// 結果行の指標グリッド。高還元の平均・推移は `ScreenPayoutHeadline` が担うので、
    /// ここでは下段 3 指標だけ。core4 以外はフィルタ・ソートに使ったときしかサーバーが返さない。
    var displayMetrics: [ScreenDisplayMetric] {
        switch self {
        case .quality: [.roic, .operatingMargin, .netDe, .salesCagr3y]
        case .growth: [.salesCagr3y, .operatingMargin, .roic, .netDe]
        case .healthyGrowth: [.salesCagr3y, .roic, .netDe, .operatingMargin]
        case .highCf: [.cfoMargin, .fcf, .roic, .netDe]
        case .improving: [.operatingMarginCagr3y, .roicCagr3y, .roic, .operatingMargin]
        case .highPayout: [.operatingMargin, .roic, .netDe]
        }
    }

    /// 短い 4 指標は 1 行。項目名・数値が大きいプリセットは 2 行のまま。
    var metricColumnsPerRow: Int {
        switch self {
        case .quality, .growth: 4
        case .highPayout: 3
        case .healthyGrowth, .highCf, .improving: 2
        }
    }
}

@Observable
final class ScreenSession {
    var selectedSectors: Set<String> = []
    var presetMatched: [ScreenPreset: Int] = [:]
    var countsLoading = true
    var loadedSectors: [String]?
}

struct ScreenView: View {
    @Bindable var session: ScreenSession

    var body: some View {
        Form {
            Section {
                sectorChips
                    .listRowBackground(Theme.elevated)
            } header: {
                HStack {
                    Text("業種を選ぶ")
                        .foregroundStyle(Theme.textMuted)
                    Spacer()
                    Button("全選択") { session.selectedSectors = Set(TSESector.catalog) }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                        .disabled(session.selectedSectors.count == TSESector.catalog.count)
                    Button("全解除") { session.selectedSectors.removeAll() }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                        .disabled(session.selectedSectors.isEmpty)
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
                HStack {
                    Text("こんな企業を探す")
                        .foregroundStyle(Theme.textMuted)
                    Spacer()
                    if session.countsLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.textMuted)
                            .accessibilityLabel("件数を読み込み中")
                    }
                }
                .textCase(nil)
            }
        }
        .bltChrome("条件検索")
        .bltHistoryToolbar()
        .navigationDestination(for: ScreenQuery.self) { query in
            ScreenResultsView(sectors: query.sectors, preset: query.preset)
        }
        .task(id: screenSectors) {
            let sectors = screenSectors
            if session.loadedSectors == sectors {
                session.countsLoading = false
                return
            }
            session.countsLoading = true
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let complete = await loadPresetCounts()
            guard !Task.isCancelled, complete else { return }
            session.loadedSectors = sectors
        }
    }

    /// 未選択と全選択は同じ（業種フィルタなし）。複数業種はサーバーの IN 検索が OR する。
    private var screenSectors: [String] {
        if session.selectedSectors.isEmpty || session.selectedSectors.count == TSESector.catalog.count {
            return []
        }
        return session.selectedSectors.sorted()
    }

    private func presetTint(_ preset: ScreenPreset) -> Color {
        switch preset {
        case .quality: Theme.accent
        case .growth: Theme.growthTint
        case .healthyGrowth: Theme.positive
        case .highCf: Theme.highCfTint
        case .improving: Theme.improvingTint
        case .highPayout: Theme.payoutTint
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
                if let matched = session.presetMatched[preset] {
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

    /// 件数は既存 `GET /v1/screen` の `matched`（`limit=1`）。業種数に関わらず 6 プリセットで
    /// 6 リクエスト（業種の複数選択はサーバーの IN 検索が 1 本で受ける）。
    /// プリセットは直列（HAPIS 同時接続を増やさない。業種変更の debounce と合わせる）。
    /// 戻り値は全プリセットの件数が揃ったか。欠けたときは呼び出し側が確定させず、次のタブ表示で取り直す。
    private func loadPresetCounts() async -> Bool {
        let sectors = screenSectors
        var next: [ScreenPreset: Int] = [:]
        for preset in ScreenPreset.allCases {
            guard !Task.isCancelled else { return false }
            do {
                let response = try await APIClient.shared.screen(
                    sectors: sectors, filters: preset.filters, limit: 1, sort: preset.sortMetric)
                next[preset] = response.matched
            } catch {
                continue
            }
        }
        guard !Task.isCancelled else { return false }
        session.presetMatched = next
        session.countsLoading = false
        return next.count == ScreenPreset.allCases.count
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
        let selected = session.selectedSectors.contains(sector)
        return Button {
            if selected {
                session.selectedSectors.remove(sector)
            } else {
                session.selectedSectors.insert(sector)
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
                                ScreenResultRow(item: item, preset: preset)
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
        .bltChrome(preset.title)
        .task {
            guard !loaded else { return }
            await run()
        }
    }

    private func run() async {
        do {
            let response = try await APIClient.shared.screen(
                sectors: sectors, filters: preset.filters, sort: preset.sortMetric)
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
    var preset: ScreenPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompanyRowView(company: CompanyRef(item))
            if preset == .highPayout {
                ScreenPayoutHeadline(item: item)
            }
            ScreenMetricValuesView(
                item: item,
                metrics: preset.displayMetrics,
                columns: preset.metricColumnsPerRow
            )
        }
        .padding(.vertical, 2)
    }
}

private struct ScreenPayoutHeadline: View {
    var item: ScreenItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            payoutLine(
                title: "配当性向3年平均",
                value: Text(Format.percent(item.payoutRatio))
                    .foregroundStyle(item.payoutRatio == nil ? Theme.textMuted : Theme.accent)
            )
            payoutLine(title: "3年推移", value: payoutTrend)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "配当性向3年平均 \(Format.percent(item.payoutRatio))、3年推移 \(trendText)"
        )
    }

    private func payoutLine(title: String, value: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
            value
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var years: [Double?] {
        let series = item.payoutRatio3y ?? []
        return (0..<3).map { $0 < series.count ? series[$0] : nil }
    }

    private var trendText: String {
        years.map { Format.percent($0) }.joined(separator: "→")
    }

    private var payoutTrend: Text {
        years.enumerated().reduce(Text("")) { partial, pair in
            let (index, value) = pair
            let piece = Text(Format.percent(value))
                .foregroundStyle(value == nil ? Theme.textMuted : Theme.accent)
            if index == 0 { return piece }
            return partial + Text("→").foregroundStyle(Theme.textMuted) + piece
        }
    }
}

/// 条件検索の結果行指標。項目名はグレー、数値は色付き。
private struct ScreenMetricLabelValue: View {
    var title: String
    var value: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ScreenMetricValuesView: View {
    var item: ScreenItem
    var metrics: [ScreenDisplayMetric]
    var columns: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(metricRows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(metricRows[index]) { metric in
                        let value = item.value(for: metric)
                        ScreenMetricLabelValue(
                            title: metric.title,
                            value: metric.format(value),
                            color: value.map { metric.band.color(for: $0) } ?? Theme.textMuted
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var metricRows: [[ScreenDisplayMetric]] {
        let width = max(columns, 1)
        return stride(from: 0, to: metrics.count, by: width).map { start in
            Array(metrics[start..<min(start + width, metrics.count)])
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
        case .cfoMargin: cfoMargin
        case .fcf: fcf
        case .operatingMarginCagr3y: operatingMarginCagr3y
        case .roicCagr3y: roicCagr3y
        case .payoutRatio: payoutRatio
        }
    }
}
