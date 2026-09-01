import SwiftData
import SwiftUI

enum TickerPage: Int, CaseIterable, Identifiable {
    case summary, breakdown, flow, interview, report

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .summary: "概要"
        case .breakdown: "分解"
        case .flow: "フロー"
        case .interview: "インタビュー"
        case .report: "レポート"
        }
    }
}

struct TickerView: View {
    var company: CompanyRef
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var watched: [WatchedCompany]
    @State private var page: TickerPage = .summary

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $page) {
                SummaryView(code: company.code)
                    .tag(TickerPage.summary)
                BreakdownView(code: company.code)
                    .tag(TickerPage.breakdown)
                TickerStubView(
                    title: "フロー",
                    detail: "Sankey は未実装です。タブだけ先に置いています。"
                )
                .tag(TickerPage.flow)
                TickerStubView(
                    title: "インタビュー",
                    detail: "構想段階です。サーバーに載せず、クライアント責務のままです。"
                )
                .tag(TickerPage.interview)
                TickerStubView(
                    title: "レポート",
                    detail: "有報一覧・ニュースの置き場です。v1 はタブ枠のみです。"
                )
                .tag(TickerPage.report)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            tickerTabs
        }
        .background(Theme.shell.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var isWatched: Bool {
        watched.contains { $0.code == company.code }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                BrandMark()
                Spacer()
                Button("探す") { dismiss() }
                    .foregroundStyle(Theme.text)
            }
            HStack(alignment: .center, spacing: 10) {
                CompanyIconView(company, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(company.name.isEmpty ? company.code : company.name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.text)
                    Text(company.code)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                }
                if !company.sector.isEmpty {
                    Text(company.sector)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.sectorColor(company.sector))
                        .foregroundStyle(.white)
                }
                Spacer()
                Button(isWatched ? "リスト済" : "リストへ") {
                    toggleWatch()
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Theme.accent)
                .foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var tickerTabs: some View {
        HStack(spacing: 6) {
            ForEach(TickerPage.allCases) { item in
                Button {
                    page = item
                } label: {
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(page == item ? Theme.accent : Theme.idleTab)
                        .foregroundStyle(page == item ? Theme.shell : Theme.text)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Theme.shell)
    }

    private func toggleWatch() {
        if let existing = watched.first(where: { $0.code == company.code }) {
            modelContext.delete(existing)
        } else {
            modelContext.insert(
                WatchedCompany(
                    code: company.code,
                    name: company.name,
                    sector: company.sector,
                    iconURL: company.iconURL
                )
            )
        }
    }
}

struct TickerStubView: View {
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.text)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card)
        .padding(16)
    }
}
