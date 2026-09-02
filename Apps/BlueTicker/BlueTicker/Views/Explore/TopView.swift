import SwiftUI

struct TopView: View {
    @State private var query = ""
    @State private var searchResults: [CompanyHit] = []
    @State private var trend: [FeedTrendItem] = []
    @State private var updates: [FeedUpdateItem] = []
    @State private var trendReady = false
    @State private var updatesReady = false
    @State private var trendError: String?
    @State private var updatesError: String?
    @State private var searchError: String?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchGeneration = 0

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
                if !trendReady {
                    ProgressView()
                        .listRowBackground(Theme.elevated)
                } else if let trendError {
                    Text(trendError)
                        .foregroundStyle(Theme.textMuted)
                        .listRowBackground(Theme.elevated)
                } else if trend.isEmpty {
                    Text("ランキングはありません")
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
                if !updatesReady {
                    ProgressView()
                        .listRowBackground(Theme.elevated)
                } else if let updatesError {
                    Text(updatesError)
                        .foregroundStyle(Theme.textMuted)
                        .listRowBackground(Theme.elevated)
                } else if updates.isEmpty {
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
        .navigationTitle("名称検索")
        .bltChrome()
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) {
            nameSearchBar
        }
        .onChange(of: query) { _, newValue in
            scheduleSearch(newValue, debounce: .milliseconds(280))
        }
        .task { await loadFeeds() }
    }

    private var nameSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
            TextField("会社名を入力してください", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .foregroundStyle(Theme.text)
                .onSubmit { scheduleSearch(query) }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("クリア")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.elevated, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.shell)
    }

    private func loadFeeds() async {
        async let trendLoad = APIClient.shared.feedTrend()
        async let updatesLoad = APIClient.shared.feedUpdates()
        do {
            trend = try await trendLoad.items
            trendError = nil
        } catch {
            trend = []
            trendError = "トレンドを取得できませんでした"
        }
        trendReady = true
        do {
            updates = try await updatesLoad.items
            updatesError = nil
        } catch {
            updates = []
            updatesError = "有報一覧を取得できませんでした"
        }
        updatesReady = true
    }

    private func scheduleSearch(_ raw: String, debounce: Duration? = nil) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration
        if trimmed.isEmpty {
            searchResults = []
            searchError = nil
            isSearching = false
            searchTask = nil
            return
        }
        searchTask = Task {
            if let debounce {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
            }
            await runSearch(trimmed, generation: generation)
        }
    }

    private func runSearch(_ raw: String, generation: Int) async {
        guard generation == searchGeneration else { return }
        isSearching = true
        defer {
            if generation == searchGeneration {
                isSearching = false
            }
        }
        do {
            let results = try await APIClient.shared.searchCompanies(query: raw)
            guard generation == searchGeneration, !Task.isCancelled else { return }
            searchResults = results
            searchError = results.isEmpty ? "該当する会社はありません" : nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == searchGeneration, !Task.isCancelled else { return }
            searchResults = []
            searchError = error.localizedDescription
        }
    }
}
