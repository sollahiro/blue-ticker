import SwiftUI

/// 業種ごとの指標ランキング。指標チップで切り替え、会社の行をタップすると銘柄面へ進む。
struct BenchmarkRankingView: View {
    var group: BenchmarkGroup
    @Binding var path: NavigationPath

    private enum Phase {
        case loading
        case loaded([BenchmarkCompany])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var metric: BenchmarkMetric?

    private var selected: BenchmarkMetric { metric ?? group.metrics[0] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch phase {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("読み込めませんでした", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("再読み込み") { Task { await load() } }
                    }
                    .padding(.top, 40)
                case .loaded(let companies):
                    loadedBody(companies)
                }
                VersionMarkFooter()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .bltChrome(group.title)
        .task { await load() }
    }

    @ViewBuilder
    private func loadedBody(_ companies: [BenchmarkCompany]) -> some View {
        Text("\(companies.count)社")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 4)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(group.metrics) { item in
                    SectorTag(sector: item.title, selected: item.key == selected.key)
                        .onTapGesture { metric = item }
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
        .scrollClipDisabled()
        ranking(companies, metric: selected)
    }

    private func ranking(_ companies: [BenchmarkCompany], metric: BenchmarkMetric) -> some View {
        let rows = companies.compactMap { company -> (BenchmarkCompany, Double)? in
            guard let value = company.kpis[metric.key]?.value else { return nil }
            return (company, value)
        }
        .sorted { metric.higherIsBetter ? $0.1 > $1.1 : $0.1 < $1.1 }
        let maxValue = max(rows.map { abs($0.1) }.max() ?? 1, .ulpOfOne)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.title).font(.headline)
                Text(metric.caption)
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
            if rows.isEmpty {
                Text("この指標のデータはありません")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                    .padding(8)
            }
            ForEach(Array(rows.enumerated()), id: \.element.0.id) { index, row in
                if index > 0 {
                    Divider().overlay(Color.white.opacity(0.08))
                }
                rankingRow(rank: index + 1, company: row.0, value: row.1, maxValue: maxValue, metric: metric)
            }
        }
        .padding(Theme.cardContentInset)
        .bltCardSurface()
    }

    private func rankingRow(
        rank: Int, company: BenchmarkCompany, value: Double, maxValue: Double, metric: BenchmarkMetric
    ) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .frame(width: 18)
            CompanyIconView(company.ref)
            VStack(alignment: .leading, spacing: 4) {
                Text(Format.displayName(company.name, fallback: company.code))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(company.code)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(metric.band.color(for: value))
                                .frame(width: max(6, geo.size.width * min(abs(value) / maxValue, 1)))
                        }
                }
                .frame(height: 6)
            }
            Text(metric.formatted(value))
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(minWidth: 64, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.idleTab)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { path.append(company.ref) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func load() async {
        phase = .loading
        do {
            let response = try await APIClient.shared.benchmark(group: group.id)
            phase = .loaded(response.companies)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
