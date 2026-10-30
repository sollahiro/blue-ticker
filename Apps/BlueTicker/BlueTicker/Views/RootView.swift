import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var searchPath = NavigationPath()
    @State private var searchQuery = ""
    @State private var screenSession = ScreenSession()
    @State private var feedSession = FeedSession()
    @Query(sort: \WatchedCompany.sortOrder) private var watched: [WatchedCompany]

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $searchPath) {
                TopView(query: $searchQuery, feed: feedSession, screen: screenSession)
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
            }
            .toolbarTitleDisplayMode(.inline)
            .tabItem { Label("ホーム", systemImage: "house") }
            .tag(0)

            NavigationStack {
                WatchlistView()
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
            }
            .toolbarTitleDisplayMode(.inline)
            .tabItem { Label("リスト", systemImage: "list.bullet") }
            .tag(1)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .toolbarBackground(.hidden, for: .tabBar)
        .task(id: watched.map(\.code).joined(separator: ",")) {
            let codes = Array(Set(watched.map(\.code)))
            await APIClient.shared.setPinnedCodes(Set(codes))
            // 銘柄面など interactive GET を先に出す。先読みは 429 で止めて間引く。
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await APIClient.shared.prefetchAnalysis(codes: codes)
        }
        .task {
            // 条件検索のスナップショットを起動時に先読みする（タブを開いた時点で件数を出せるように）。
            // 保存が新しければ通信しない。
            guard await ScreenSnapshotStore.shared.needsRevalidation() else { return }
            _ = await ScreenSnapshotStore.shared.revalidate()
        }
        .onChange(of: scenePhase) { _, phase in
            // フォアグラウンド復帰でも、前回の取得から 1 時間を過ぎていれば RSS を再検証する。
            guard phase == .active else { return }
            Task { await feedSession.refresh() }
        }
    }

    private func ticker(_ company: CompanyRef) -> some View {
        TickerView(company: company)
    }
}
