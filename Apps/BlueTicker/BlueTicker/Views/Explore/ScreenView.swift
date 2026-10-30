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

/// 条件検索の状態。業種の選択は結果一覧の業種タブで変え、条件一覧の件数もこの選択で数える。
@MainActor
@Observable
final class ScreenSession {
    var selectedSectors: Set<TOPIX17Sector> = []
    var presetMatched: [ScreenPreset: Int] = [:]
    var countsLoading = true
    var loadedSectors: [String]?

    /// 未選択と全選択は同じ（業種フィルタなし）。選んだ 17 業種は配下の 33 業種名に展開し、
    /// サーバーの IN 検索（スナップショットは端末内の集合）が OR する。
    var screenSectors: [String] {
        if selectedSectors.isEmpty || selectedSectors.count == TOPIX17Sector.allCases.count {
            return []
        }
        return selectedSectors.flatMap(\.tseSectors).sorted()
    }

    func toggle(_ sector: TOPIX17Sector) {
        if selectedSectors.contains(sector) {
            selectedSectors.remove(sector)
        } else {
            selectedSectors.insert(sector)
        }
    }

    /// 選択中の業種で 6 プリセットの件数を数える。数え済みなら何もしない。
    func refreshCounts() async {
        let sectors = screenSectors
        if loadedSectors == sectors {
            countsLoading = false
            return
        }
        // 保存済みのスナップショットがあれば通信せずに数える（debounce も要らない）。
        if let rows = await ScreenSnapshotStore.shared.cachedRows() {
            applyLocalCounts(rows, sectors: sectors)
            return
        }
        countsLoading = true
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        let complete = await loadPresetCounts(sectors: sectors)
        guard !Task.isCancelled, complete else { return }
        loadedSectors = sectors
    }

    /// 表示のたびに検証子で取り直す（間隔内は送らない）。新しい本文が来たら数え直す。
    func revalidateSnapshot() async {
        guard await ScreenSnapshotStore.shared.needsRevalidation(),
            let fresh = await ScreenSnapshotStore.shared.revalidate()
        else { return }
        applyLocalCounts(fresh, sectors: screenSectors)
    }

    private func applyLocalCounts(_ rows: [ScreenSnapshot.Row], sectors: [String]) {
        var next: [ScreenPreset: Int] = [:]
        for preset in ScreenPreset.allCases {
            next[preset] = preset.search(rows, sectors: sectors, limit: 0).matched
        }
        presetMatched = next
        countsLoading = false
        loadedSectors = sectors
    }

    /// 件数はまずスナップショット（`GET /v1/screen/snapshot` を 1 回）を取って端末内で数える。
    /// 取れないときだけ既存 `GET /v1/screen` の `matched`（`limit=1`）に戻す。こちらは業種数に関わらず
    /// 6 プリセットで 6 リクエスト（業種の複数選択はサーバーの IN 検索が 1 本で受ける）。
    /// プリセットは直列（HAPIS 同時接続を増やさない。業種変更の debounce と合わせる）。
    /// 戻り値は全プリセットの件数が揃ったか。欠けたときは確定させず、次の表示で取り直す。
    private func loadPresetCounts(sectors: [String]) async -> Bool {
        if let rows = await ScreenSnapshotStore.shared.rowsFetchingIfNeeded() {
            guard !Task.isCancelled else { return false }
            applyLocalCounts(rows, sectors: sectors)
            return true
        }
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
        presetMatched = next
        countsLoading = false
        return next.count == ScreenPreset.allCases.count
    }
}

extension ScreenPreset {
    var tint: Color {
        switch self {
        case .quality: Theme.accent
        case .growth: Theme.growthTint
        case .healthyGrowth: Theme.positive
        case .highCf: Theme.highCfTint
        case .improving: Theme.improvingTint
        case .highPayout: Theme.payoutTint
        }
    }
}

/// トップの検索バーが空のときに出す条件一覧。`List` の中に置く。押すと `ScreenPreset` で結果一覧へ進む。
/// 件数は置く側が `refreshCounts` / `revalidateSnapshot` で数える。
struct ScreenPresetSection: View {
    @Bindable var session: ScreenSession

    var body: some View {
        Section {
            ForEach(ScreenPreset.allCases) { preset in
                NavigationLink(value: preset) {
                    presetRow(preset)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text("条件から探す")
                    .foregroundStyle(Theme.textMuted)
                ForEach(TOPIX17Sector.allCases.filter { session.selectedSectors.contains($0) }) { sector in
                    Image(systemName: sector.symbol)
                        .imageScale(.small)
                        .foregroundStyle(Theme.positive)
                        .accessibilityLabel(sector.title)
                }
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

    private func presetRow(_ preset: ScreenPreset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SectorTag(sector: preset.title, selected: true, tint: preset.tint)
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
}

/// 結果一覧の上に置く 17 業種タブ。横にスライドして複数選ぶ。選んだ業種はアイコンだけに縮む。
/// 1 つ以上選んでいる間だけ先頭に「全解除」を出す。
struct SectorFilterBar: View {
    @Bindable var session: ScreenSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !session.selectedSectors.isEmpty {
                    Button {
                        session.selectedSectors.removeAll()
                    } label: {
                        Label("全解除", systemImage: "xmark")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(Theme.text)
                            .background(Theme.idleTab, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale))
                }
                ForEach(TOPIX17Sector.allCases) { sector in
                    chip(sector)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .animation(.snappy(duration: 0.22), value: session.selectedSectors)
        }
        .scrollClipDisabled()
    }

    private func chip(_ sector: TOPIX17Sector) -> some View {
        let selected = session.selectedSectors.contains(sector)
        return Button {
            session.toggle(sector)
        } label: {
            Group {
                if selected {
                    Image(systemName: sector.symbol)
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 18)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .foregroundStyle(Theme.positive)
                        .background(Theme.sectorFill, in: Capsule())
                        .overlay { Capsule().stroke(Theme.positive, lineWidth: 1.5) }
                } else {
                    SectorTag(sector: sector.title, selected: false, symbol: sector.symbol)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sector.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 条件検索結果一覧。上に業種タブ、下に指標付きの行。業種を変えるとその場で引き直す。
struct ScreenResultsView: View {
    var preset: ScreenPreset
    @Bindable var session: ScreenSession

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
                    } header: {
                        Text(preset.descriptionText)
                            .foregroundStyle(Theme.textMuted)
                            .textCase(nil)
                    } footer: {
                        Text(preset.reasonText)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            SectorFilterBar(session: session)
        }
        .bltChrome(preset.title)
        .task(id: session.screenSectors) {
            await run(sectors: session.screenSectors)
        }
    }

    /// スナップショットがあれば端末内で引く（REST と同じ 50 件）。無ければ `GET /v1/screen`。
    private func run(sectors: [String]) async {
        if let rows = await ScreenSnapshotStore.shared.rowsFetchingIfNeeded() {
            guard !Task.isCancelled else { return }
            let result = preset.search(rows, sectors: sectors, limit: 50)
            items = result.rows.map(ScreenItem.init)
            matched = result.matched
            errorMessage = nil
            loaded = true
            return
        }
        if loaded {
            // 業種の連打で通信を重ねない。
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
        }
        do {
            let response = try await APIClient.shared.screen(
                sectors: sectors, filters: preset.filters, sort: preset.sortMetric)
            guard !Task.isCancelled else { return }
            items = response.items
            matched = response.matched
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch APIClientError.http(let status, let message) where status == 404 {
            items = []
            matched = 0
            errorMessage = message.isEmpty ? "Screen 索引は未生成です" : message
        } catch {
            guard !Task.isCancelled else { return }
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
        let label = Text(title)
            .font(.caption2)
            .foregroundStyle(Theme.textMuted)
        let number = value
            .font(.subheadline.monospacedDigit().weight(.semibold))
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label.fixedSize()
                number.fixedSize()
            }
            VStack(alignment: .leading, spacing: 1) {
                label
                number.fixedSize(horizontal: false, vertical: true)
            }
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
            let arrow = Text("→").foregroundStyle(Theme.textMuted)
            return Text("\(partial)\(arrow)\(piece)")
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
