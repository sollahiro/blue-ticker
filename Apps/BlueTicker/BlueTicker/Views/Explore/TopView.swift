import SwiftUI

struct TopView: View {
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
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !searchResults.isEmpty || searchError != nil || isSearching {
                        sectionHeader("検索結果")
                        if isSearching && searchResults.isEmpty && searchError == nil {
                            rowBackground { ProgressView() }
                        }
                        if let searchError {
                            rowBackground {
                                Text(searchError)
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                        ForEach(searchResults) { hit in
                            companyLink(CompanyRef(hit))
                        }
                    }

                    sectionHeader("最近新しい有報がアップロードされました")
                    if !updatesReady {
                        rowBackground { ProgressView() }
                    } else if let updatesError {
                        rowBackground {
                            Text(updatesError)
                                .foregroundStyle(Theme.textMuted)
                        }
                    } else if updates.isEmpty {
                        rowBackground {
                            Text("直近の有報はありません")
                                .foregroundStyle(Theme.textMuted)
                        }
                    } else {
                        ForEach(updates.prefix(8)) { item in
                            companyLink(CompanyRef(item))
                        }
                    }
                }
                .padding(.bottom, 120)
            }
            .scrollClipDisabled()
            .contentMargins(.top, 0, for: .scrollContent)
            .safeAreaPadding(.bottom, 0)
            .ignoresSafeArea(.container, edges: .bottom)

            nameSearchBar
        }
        .background { InlineNavigationTitle() }
        .navigationTitle("名称検索")
        .bltChrome()
        .scrollDismissesKeyboard(.interactively)
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
        .task { await loadFeeds() }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 6)
    }

    private func companyLink(_ company: CompanyRef) -> some View {
        NavigationLink(value: company) {
            HStack(spacing: 8) {
                CompanyRowView(company: company)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.elevated)
        }
        .buttonStyle(.plain)
    }

    private func rowBackground<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.elevated)
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
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Theme.text.opacity(0.14), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func loadFeeds() async {
        do {
            updates = try await APIClient.shared.feedUpdates().items
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
                        NavigationLink {
                            TickerView(company: company)
                        } label: {
                            CompanyRowView(company: company)
                        }
                        .listRowBackground(Theme.elevated)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("履歴")
        .bltChrome()
        .onAppear { items = CompanyHistory.load() }
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

/// iOS 26 の NavigationStack が inline でも大きなタイトル用の空きを残すのを潰す。
private struct InlineNavigationTitle: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.apply()
    }

    final class Controller: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        func apply() {
            var current: UIViewController? = self
            while let controller = current {
                controller.navigationItem.largeTitleDisplayMode = .never
                controller.navigationController?.navigationBar.prefersLargeTitles = false
                current = controller.parent
            }
        }
    }
}
