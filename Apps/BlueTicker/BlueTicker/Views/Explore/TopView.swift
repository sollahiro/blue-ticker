import SwiftUI

@Observable
final class FeedSession {
    var updates: [FeedUpdateItem] = []
    var ready = false
    var error: String?

    func loadIfNeeded() async {
        guard !ready else { return }
        do {
            updates = try await APIClient.shared.feedUpdates().items
            error = nil
        } catch APIClientError.needsAccessLogin {
            updates = []
            error = APIClientError.needsAccessLogin.errorDescription
        } catch {
            updates = []
            self.error = "有報一覧を取得できませんでした"
        }
        ready = true
    }
}

struct TopView: View {
    @Binding var query: String
    @Binding var path: NavigationPath
    @Bindable var feed: FeedSession
    @State private var searchResults: [CompanyHit] = []
    @State private var searchError: String?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchGeneration = 0

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

            Section {
                if let error = feed.error {
                    Text(error)
                        .foregroundStyle(Theme.textMuted)
                } else if feed.ready && feed.updates.isEmpty {
                    Text("直近の有報はありません")
                        .foregroundStyle(Theme.textMuted)
                } else {
                    ForEach(feed.updates.prefix(10)) { item in
                        companyLink(CompanyRef(item), submittedAt: item.submittedAt)
                    }
                }
            } header: {
                HStack {
                    Text("最近新しい有報がアップロードされました")
                        .foregroundStyle(Theme.textMuted)
                    Spacer(minLength: 8)
                    if !feed.ready {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.textMuted)
                            .accessibilityLabel("有報を読み込み中")
                    }
                }
                .textCase(nil)
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .bltChrome("名称検索")
        .safeAreaBar(edge: .bottom) {
            NameSearchField(query: $query)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("履歴") {
                    path.append(HistoryRoute())
                }
            }
        }
        .navigationDestination(for: HistoryRoute.self) { _ in
            HistoryView()
        }
        .onChange(of: query) { _, newValue in
            scheduleSearch(newValue, debounce: .milliseconds(280))
        }
        .task { await feed.loadIfNeeded() }
    }

    private var showsSearchSection: Bool {
        !searchResults.isEmpty || searchError != nil || isSearching
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

struct HistoryRoute: Hashable {}

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
        .bltChrome("履歴")
        .onAppear { items = CompanyHistory.load() }
    }
}

/// 名称検索のルートに付ける。`tabViewBottomAccessory` はタブに固定されキーボードに隠れ、
/// `.searchable` のドロワーは上に寄る。`safeAreaBar` はタブの上に置き、キーボードにも追従する。
/// タブを選んだだけではキーボードを出さず、欄をタップしてから入力する。
struct NameSearchField: View {
    @Binding var query: String
    @FocusState private var focused: Bool
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
            Group {
                if editing {
                    TextField("会社名を入力してください", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .foregroundStyle(Theme.text)
                        .focused($focused)
                        .onSubmit { stopEditing() }
                        .onAppear { focused = true }
                } else {
                    Text(query.isEmpty ? "会社名を入力してください" : query)
                        .foregroundStyle(query.isEmpty ? Theme.textMuted : Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !editing else { return }
                editing = true
            }
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
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive())
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .onAppear { stopEditing() }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { editing = false }
        }
    }

    private func stopEditing() {
        focused = false
        editing = false
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
