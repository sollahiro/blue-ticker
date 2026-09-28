import SwiftData
import SwiftUI

struct RootView: View {
    @State private var tab = 0
    @State private var searchPath = NavigationPath()
    @State private var searchQuery = ""
    @State private var screenSession = ScreenSession()
    @State private var feedSession = FeedSession()
    @Query(sort: \WatchedCompany.sortOrder) private var watched: [WatchedCompany]

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $searchPath) {
                TopView(query: $searchQuery, feed: feedSession)
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
            }
            .toolbarTitleDisplayMode(.inline)
            .tabItem { Label("名称検索", systemImage: "magnifyingglass") }
            .tag(0)

            NavigationStack {
                ScreenView(session: screenSession)
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
            }
            .toolbarTitleDisplayMode(.inline)
            .tabItem { Label("条件検索", systemImage: "slider.horizontal.3") }
            .tag(1)

            NavigationStack {
                WatchlistView()
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
            }
            .toolbarTitleDisplayMode(.inline)
            .tabItem { Label("リスト", systemImage: "list.bullet") }
            .tag(2)

            NavigationStack {
                FundView()
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
            }
            .toolbarTitleDisplayMode(.inline)
            .tabItem { Label("ファンド", systemImage: "chart.pie.fill") }
            .tag(3)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .toolbarBackground(.hidden, for: .tabBar)
        .task(id: watched.map(\.code).joined(separator: ",")) {
            let codes = Array(Set(watched.map(\.code)))
            await APIClient.shared.setPinnedCodes(Set(codes))
            // Feed の interactive GET を先に出す。先読みは 429 で止めて間引く。
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await APIClient.shared.prefetchAnalysis(codes: codes)
        }
    }

    private func ticker(_ company: CompanyRef) -> some View {
        TickerView(company: company)
    }
}
