import SwiftData
import SwiftUI

/// 星ボタン押下時にタブバーの list.bullet を揺らすための共有トリガ。
/// 追加はレイヤーごとのバウンス、削除は描画オフ（indefinite なので約0.7秒で戻す）。
@MainActor @Observable
final class WatchAnimation {
    var added = 0
    var drawOff = false
    private var drawOffTask: Task<Void, Never>?

    func addedToList() {
        drawOffTask?.cancel()
        drawOff = false
        added += 1
    }

    func removedFromList() {
        drawOffTask?.cancel()
        drawOff = true
        drawOffTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            drawOff = false
        }
    }
}

struct RootView: View {
    @State private var tab = 0
    @State private var watchAnimation = WatchAnimation()
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
            .tabItem {
                Label {
                    Text("リスト")
                } icon: {
                    Image(systemName: "list.bullet")
                        .symbolEffect(.bounce.byLayer, value: watchAnimation.added)
                        .symbolEffect(.drawOff.byLayer, isActive: watchAnimation.drawOff)
                }
            }
            .tag(2)

            NavigationStack {
                FundView()
                    .navigationDestination(for: CompanyRef.self, destination: ticker)
            }
            .toolbarTitleDisplayMode(.inline)
            .tabItem { Label("ファンド", systemImage: "chart.pie.fill") }
            .tag(3)
        }
        .environment(watchAnimation)
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
