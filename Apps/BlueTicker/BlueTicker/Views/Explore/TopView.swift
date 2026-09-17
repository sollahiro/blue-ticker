import SwiftUI

struct TopView: View {
    /// 銘柄面に push しているあいだは `.searchable` を外す。常時ドロワーが空ヘッダとして残るため。
    var hidesSearch = false
    @State private var query = ""
    @State private var searchResults: [CompanyHit] = []
    @State private var updates: [FeedUpdateItem] = []
    @State private var updatesReady = false
    @State private var updatesError: String?
    @State private var searchError: String?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchGeneration = 0
    @State private var showHistory = false

    var body: some View {
        List {
            if showsSearchSection {
                Section("検索結果") {
                    if isSearching && searchResults.isEmpty && searchError == nil {
                        ProgressView()
                    }
                    if let searchError {
                        Text(searchError)
                            .foregroundStyle(Theme.textMuted)
                    }
                    ForEach(searchResults) { hit in
                        companyLink(CompanyRef(hit))
                    }
                }
            }

            Section("最近新しい有報がアップロードされました") {
                if !updatesReady {
                    ProgressView()
                } else if let updatesError {
                    Text(updatesError)
                        .foregroundStyle(Theme.textMuted)
                } else if updates.isEmpty {
                    Text("直近の有報はありません")
                        .foregroundStyle(Theme.textMuted)
                } else {
                    ForEach(updates.prefix(10)) { item in
                        companyLink(CompanyRef(item), submittedAt: item.submittedAt)
                    }
                }
            }
        }
        .modifier(NameSearchChrome(query: $query, enabled: showsSearchChrome))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("名称検索")
        .bltChrome()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("履歴") {
                    showHistory = true
                }
                .foregroundStyle(Theme.text)
            }
        }
        .navigationDestination(isPresented: $showHistory) {
            HistoryView()
        }
        .onChange(of: query) { _, newValue in
            scheduleSearch(newValue, debounce: .milliseconds(280))
        }
        .onSubmit(of: .search) {
            scheduleSearch(query)
        }
        .task { await loadFeeds() }
    }

    private var showsSearchSection: Bool {
        !searchResults.isEmpty || searchError != nil || isSearching
    }

    private var showsSearchChrome: Bool {
        !hidesSearch && !showHistory
    }

    private func companyLink(_ company: CompanyRef, submittedAt: String? = nil) -> some View {
        NavigationLink(value: company) {
            HStack(spacing: 8) {
                CompanyRowView(company: company)
                if let submittedAt {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("提出日")
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                        Text(Format.submittedDate(submittedAt))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.text)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("提出日 \(Format.submittedDate(submittedAt))")
                }
            }
        }
    }

    private func loadFeeds() async {
        do {
            updates = try await APIClient.shared.feedUpdates().items
            updatesError = nil
        } catch APIClientError.needsAccessLogin {
            updates = []
            updatesError = APIClientError.needsAccessLogin.errorDescription
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

struct HistoryView: View {
    @State private var items: [CompanyRef] = CompanyHistory.load()

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "履歴はありません",
                    systemImage: "clock",
                    description: Text("開いた銘柄がここに残ります。")
                )
            } else {
                List {
                    ForEach(items) { company in
                        NavigationLink(value: company) {
                            CompanyRowView(company: company)
                        }
                        .listRowBackground(Theme.elevated)
                    }
                }
            }
        }
        .navigationTitle("履歴")
        .bltChrome()
        .onAppear { items = CompanyHistory.load() }
    }
}

/// 名称検索のルートにいるときだけ標準検索欄を付ける。
/// 常時ドロワー（`.always`）は銘柄 push 後も空ヘッダとして残る。
private struct NameSearchChrome: ViewModifier {
    @Binding var query: String
    var enabled: Bool
    @State private var isPresented = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(
                text: $query,
                isPresented: $isPresented,
                prompt: "会社名を入力してください"
            )
            .onAppear { isPresented = true }
        } else {
            content
        }
    }
}

enum CompanyHistory {
    private static let key = "blt.company.history"
    private static let limit = 30

    static func load() -> [CompanyRef] {
        guard let data = UserDefaults.standard.data(forKey: key),
            let items = try? JSONDecoder().decode([CompanyRef].self, from: data)
        else {
            return []
        }
        return items
    }

    static func record(_ company: CompanyRef) {
        var items = load().filter { $0.code != company.code }
        items.insert(company, at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
