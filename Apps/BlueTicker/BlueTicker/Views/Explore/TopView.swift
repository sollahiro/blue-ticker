import SwiftUI

@Observable
final class FeedSession {
    var updates: [FeedUpdateItem] = []
    var ready = false
    var error: String?

    /// 成功したら以後は取り直さない。失敗は次に名称検索へ戻ったときに再試行する。
    /// タブ移動で `.task` が cancel されただけなら状態を触らず、次回にそのまま読み直す。
    func loadIfNeeded() async {
        guard !ready || error != nil else { return }
        ready = false
        do {
            updates = try await APIClient.shared.feedUpdates().items
            error = nil
        } catch is CancellationError {
            return
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
        .bltHistoryToolbar()
        .safeAreaBar(edge: .bottom) {
            NameSearchField(query: $query)
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

/// 名称検索のルートに付ける。`tabViewBottomAccessory` はタブに固定されキーボードに隠れ、
/// `.searchable` のドロワーは上に寄る。`safeAreaBar` はタブの上に置き、キーボードにも追従する。
/// タブを選んだだけではキーボードを出さず、欄をタップしてから入力する。
/// 編集中は Safari のアドレス欄と同じく欄を縮め、欄内クリアと欄外の円形バツを分ける。
struct NameSearchField: View {
    @Binding var query: String
    @FocusState private var focused: Bool
    @State private var editing = false
    @State private var fieldIdentity = 0
    @State private var keepEditing = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityHidden(true)
                Group {
                    if editing {
                        TextField("会社名を入力してください", text: $query)
                            .id(fieldIdentity)
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
                    Button(action: clearQuery) {
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

            if editing {
                Button(action: stopEditing) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("キャンセル")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(.snappy(duration: 0.22), value: editing)
        .onAppear { stopEditing() }
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                editing = true
                keepEditing = false
            } else if keepEditing {
                focused = true
            } else {
                editing = false
            }
        }
    }

    private func clearQuery() {
        keepEditing = true
        query = ""
        fieldIdentity += 1
    }

    private func stopEditing() {
        keepEditing = false
        focused = false
        editing = false
    }
}
