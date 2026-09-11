import SwiftData
import SwiftUI

struct RootView: View {
    @State private var tab = 0
    @Query(sort: \WatchedCompany.addedAt, order: .reverse) private var watched: [WatchedCompany]

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                TopView()
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
                    .exploreToolbar()
            }
            .toolbarTitleDisplayMode(.inline)
            .tabItem { Label("名称検索", systemImage: "magnifyingglass") }
            .tag(0)

            NavigationStack {
                ScreenView()
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
                    .exploreToolbar()
            }
            .toolbarTitleDisplayMode(.inline)
            .tabItem { Label("条件検索", systemImage: "slider.horizontal.3") }
            .tag(1)

            NavigationStack {
                WatchlistView()
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
                    .exploreToolbar()
            }
            .toolbarTitleDisplayMode(.inline)
            .tabItem { Label("リスト", systemImage: "list.bullet") }
            .tag(2)

            NavigationStack {
                SettingsPlaceholder()
                    .exploreToolbar()
            }
            .toolbarTitleDisplayMode(.inline)
            .tabItem { Label("設定", systemImage: "gearshape") }
            .tag(3)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .toolbarBackground(.hidden, for: .tabBar)
        .task(id: watched.map(\.code).joined(separator: ",")) {
            let codes = watched.map(\.code)
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

extension View {
    func exploreToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                BrandMark()
            }
            .withoutSharedBackground()
        }
    }
}
