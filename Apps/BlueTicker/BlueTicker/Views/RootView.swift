import SwiftUI

struct RootView: View {
    @State private var showSettings = false
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                TopView()
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
                    .exploreToolbar(onOpenSettings: openSettings)
            }
            .tabItem { Label("トップ", systemImage: "house") }
            .tag(0)

            NavigationStack {
                ScreenView()
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
                    .exploreToolbar(onOpenSettings: openSettings)
            }
            .tabItem { Label("条件", systemImage: "slider.horizontal.3") }
            .tag(1)

            NavigationStack {
                WatchlistView()
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
                    .exploreToolbar(onOpenSettings: openSettings)
            }
            .tabItem { Label("リスト", systemImage: "list.bullet") }
            .tag(2)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .toolbarBackground(Theme.shell, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .sheet(isPresented: $showSettings) {
            SettingsPlaceholder()
        }
    }

    private func ticker(_ company: CompanyRef) -> some View {
        TickerView(company: company, onOpenSettings: openSettings)
    }

    private func openSettings() {
        showSettings = true
    }
}

extension View {
    func exploreToolbar(onOpenSettings: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                BrandMark()
            }
            .withoutSharedBackground()
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .foregroundStyle(Theme.text)
                .accessibilityLabel("設定")
            }
        }
    }
}
