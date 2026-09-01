import SwiftUI

struct RootView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                TopView()
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
                    .exploreToolbar()
            }
            .tabItem { Label("トップ", systemImage: "house") }
            .tag(0)

            NavigationStack {
                ScreenView()
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
                    .exploreToolbar()
            }
            .tabItem { Label("条件", systemImage: "slider.horizontal.3") }
            .tag(1)

            NavigationStack {
                WatchlistView()
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
                    .exploreToolbar()
            }
            .tabItem { Label("リスト", systemImage: "list.bullet") }
            .tag(2)

            NavigationStack {
                SettingsPlaceholder()
                    .exploreToolbar()
            }
            .tabItem { Label("設定", systemImage: "gearshape") }
            .tag(3)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .toolbarBackground(Theme.shell, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
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
