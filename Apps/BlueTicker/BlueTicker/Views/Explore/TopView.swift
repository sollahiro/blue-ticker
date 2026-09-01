import SwiftUI

struct TopView: View {
    @State private var query = ""
    @State private var searchResults: [CompanyHit] = []
    @State private var trend: [FeedTrendItem] = []
    @State private var updates: [FeedUpdateItem] = []
    @State private var searchError: String?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            if !searchResults.isEmpty || searchError != nil || isSearching {
                Section("検索結果") {
                    if isSearching && searchResults.isEmpty && searchError == nil {
                        ProgressView()
                            .listRowBackground(Theme.elevated)
                    }
                    if let searchError {
                        Text(searchError)
                            .foregroundStyle(Theme.textMuted)
                            .listRowBackground(Theme.elevated)
                    }
                    ForEach(searchResults) { hit in
                        NavigationLink(value: CompanyRef(hit)) {
                            CompanyRowView(company: CompanyRef(hit))
                        }
                        .listRowBackground(Theme.elevated)
                    }
                }
            }

            Section("最近よく調べられています") {
                if trend.isEmpty {
                    Text("トレンドを取得できませんでした")
                        .foregroundStyle(Theme.textMuted)
                        .listRowBackground(Theme.elevated)
                } else {
                    ForEach(trend.prefix(8)) { item in
                        NavigationLink(value: CompanyRef(item)) {
                            CompanyRowView(company: CompanyRef(item))
                        }
                        .listRowBackground(Theme.elevated)
                    }
                }
            }

            Section("最近新しい有報がアップロードされました") {
                if updates.isEmpty {
                    Text("直近の有報はありません")
                        .foregroundStyle(Theme.textMuted)
                        .listRowBackground(Theme.elevated)
                } else {
                    ForEach(updates.prefix(8)) { item in
                        NavigationLink(value: CompanyRef(item)) {
                            CompanyRowView(company: CompanyRef(item))
                        }
                        .listRowBackground(Theme.elevated)
                    }
                }
            }
        }
        .navigationTitle("トップ")
        .bltChrome()
        .searchable(text: $query, prompt: "会社名を入力してください")
        .onSubmit(of: .search) {
            Task { await runSearch(query) }
        }
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                searchResults = []
                searchError = nil
                isSearching = false
                return
            }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                await runSearch(trimmed)
            }
        }
        .task { await loadFeeds() }
    }

    private func loadFeeds() async {
        trend = (try? await APIClient.shared.feedTrend())?.items ?? []
        updates = (try? await APIClient.shared.feedUpdates())?.items ?? []
    }

    private func runSearch(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            searchError = nil
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await APIClient.shared.searchCompanies(query: trimmed)
            searchError = searchResults.isEmpty ? "該当する会社はありません" : nil
        } catch {
            searchResults = []
            searchError = error.localizedDescription
        }
    }
}
