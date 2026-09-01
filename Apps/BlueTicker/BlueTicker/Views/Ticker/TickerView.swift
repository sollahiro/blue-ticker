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
                    detail: "Sankey は未実装です。ページ枠だけ先に置いています。"
                )
                .tag(TickerPage.flow)
                TickerStubView(
                    title: "インタビュー",
                    detail: "構想段階です。サーバーに載せず、クライアント責務のままです。"
                )
                .tag(TickerPage.interview)
                TickerStubView(
                    title: "レポート",
                    detail: "有報一覧・ニュースの置き場です。v1 はページ枠のみです。"
                )
                .tag(TickerPage.report)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            pageDots
        }
        .background(Theme.shell.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.text)
                }
                .accessibilityLabel("戻る")
            }
            .withoutSharedBackground()
            ToolbarItem(placement: .principal) {
                BrandMark()
            }
            .withoutSharedBackground()
        }
        .toolbarBackground(Theme.shell, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var isWatched: Bool {
        watched.contains { $0.code == company.code }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            CompanyIconView(company, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.displayName(company.name, fallback: company.code))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(company.code)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if !company.sector.isEmpty {
                    Text(company.sector)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.sectorColor(company.sector))
                        .foregroundStyle(.white)
                }
                watchButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var watchButton: some View {
        Button(action: toggleWatch) {
            Text(isWatched ? "追加済み" : "リストに追加")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isWatched ? Color.clear : Theme.accent)
                .foregroundStyle(isWatched ? Theme.accent : .black)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.accent, lineWidth: isWatched ? 1.5 : 0)
                }
        }
        .buttonStyle(.plain)
    }

    private var pageDots: some View {
        HStack(spacing: 10) {
            ForEach(TickerPage.allCases) { item in
                let current = page == item
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        page = item
                    }
                } label: {
                    Circle()
                        .fill(current ? Theme.accent : Theme.textMuted.opacity(0.45))
                        .frame(width: current ? 10 : 6, height: current ? 10 : 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .animation(.easeInOut(duration: 0.2), value: page)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
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
