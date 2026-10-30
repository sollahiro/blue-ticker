import SwiftUI
import UIKit

/// Top feed（公開 RSS）。端末に保存済みの分をすぐ出し、裏で条件付き GET で再検証する。
/// ProgressView は保存が無い初回の取得中だけ。保存も取得結果も無ければセクションごと出さない。
@MainActor
@Observable
final class FeedSession {
    private(set) var items: [FeedRSS.Item] = []
    /// 保存が無いまま取得している間だけ `true`。
    private(set) var isFirstLoading = false
    private var restored = false
    private var hasSaved = false
    private var refreshing = false

    var showsSection: Bool { !items.isEmpty || isFirstLoading }

    /// 名称検索の表示時とフォアグラウンド復帰時に呼ぶ。再検証の間隔は `FeedRSSStore` が決める。
    /// 同時に呼ばれたら後の呼び出しは何もしない。
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer {
            refreshing = false
            isFirstLoading = false
        }
        let store = FeedRSSStore.shared
        if !restored {
            restored = true
            if let cached = await store.cachedItems() {
                items = cached
                hasSaved = true
            }
        }
        guard await store.needsRevalidation() else { return }
        isFirstLoading = !hasSaved
        if let fresh = await store.revalidate() {
            items = fresh
            hasSaved = true
        }
    }
}

/// トップから push する画面。銘柄は `CompanyRef`、条件検索結果は `ScreenPreset` で積む。
enum TopRoute: Hashable {
    case history
}

/// トップ。左上にロゴ、右上に検索と履歴。本文は最近有報が更新された企業のキュレーション。
/// 検索を押すと上部が検索バーに変わり、未入力なら条件一覧、入力中は会社名の候補を出す。
struct TopView: View {
    @Binding var query: String
    @Bindable var feed: FeedSession
    @Bindable var screen: ScreenSession
    @State private var searching = false
    @State private var searchResults: [CompanyHit] = []
    @State private var searchError: String?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchGeneration = 0

    var body: some View {
        Group {
            if searching {
                searchContent
                    .transition(.opacity)
            } else {
                curationContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bltChrome("")
        .toolbar(searching ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                YuhoLabLogo()
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    withAnimation(.snappy(duration: 0.22)) { searching = true }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("検索")
                NavigationLink(value: TopRoute.history) {
                    Image(systemName: "clock")
                }
                .accessibilityLabel("履歴")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if searching {
                TopSearchBar(query: $query, onCancel: endSearch)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .navigationDestination(for: TopRoute.self) { route in
            switch route {
            case .history: HistoryListView()
            }
        }
        .navigationDestination(for: ScreenPreset.self) { preset in
            ScreenResultsView(preset: preset, session: screen)
        }
        .onChange(of: query) { _, newValue in
            scheduleSearch(newValue, debounce: .milliseconds(280))
        }
        .task { await feed.refresh() }
        .task(id: screen.screenSectors) { await screen.refreshCounts() }
        .task { await screen.revalidateSnapshot() }
    }

    @ViewBuilder
    private var curationContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最近有報が更新された企業")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textMuted)
                    Spacer(minLength: 8)
                    if feed.isFirstLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.textMuted)
                            .accessibilityLabel("有報を読み込み中")
                    }
                }
                .padding(.horizontal, 4)
                if feed.items.isEmpty {
                    if !feed.isFirstLoading {
                        Text("まだ表示できる有報がありません")
                            .font(.footnote)
                            .foregroundStyle(Theme.textMuted)
                            .padding(.horizontal, 4)
                    }
                } else {
                    CurationCarousel(items: feed.items)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private var searchContent: some View {
        List {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScreenPresetSection(session: screen)
            } else {
                Section {
                    if isSearching && searchResults.isEmpty && searchError == nil {
                        ProgressView()
                    }
                    if let searchError {
                        Text(searchError)
                            .foregroundStyle(Theme.textMuted)
                    }
                    ForEach(searchResults) { hit in
                        NavigationLink(value: CompanyRef(hit)) {
                            CompanyRowView(company: CompanyRef(hit))
                        }
                    }
                } header: {
                    Text("検索候補")
                        .foregroundStyle(Theme.textMuted)
                        .textCase(nil)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .scrollContentBackground(.hidden)
    }

    private func endSearch() {
        withAnimation(.snappy(duration: 0.22)) {
            searching = false
        }
        query = ""
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

/// 左上の白抜きロゴ。アセット `YuhoLabLogo`（SVG。元ファイルの影フィルタは外してある）。読めないときは文字で出す。
struct YuhoLabLogo: View {
    var body: some View {
        Group {
            if let image = UIImage(named: "YuhoLabLogo") {
                Image(uiImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 22)
            } else {
                Text("有報LAB")
                    .font(.headline.weight(.heavy))
            }
        }
        .foregroundStyle(Theme.text)
        .accessibilityLabel("有報LAB")
        .accessibilityAddTraits(.isHeader)
    }
}

/// キュレーション。6 社ずつのページを横にめくり、触らなければ一定間隔で次へ送る。
/// 手でめくると送りの間隔はそこから数え直す。
struct CurationCarousel: View {
    var items: [FeedRSS.Item]
    @State private var page = 0

    private static let rowsPerPage = 6
    private static let rowHeight: CGFloat = 56
    private static let interval: Duration = .seconds(6)

    private var pages: [[FeedRSS.Item]] {
        stride(from: 0, to: items.count, by: Self.rowsPerPage).map { start in
            Array(items[start..<min(start + Self.rowsPerPage, items.count)])
        }
    }

    var body: some View {
        let chunks = pages
        VStack(spacing: 10) {
            TabView(selection: $page) {
                ForEach(chunks.indices, id: \.self) { index in
                    VStack(spacing: 0) {
                        ForEach(Array(chunks[index].enumerated()), id: \.element.id) { offset, item in
                            if offset > 0 {
                                Divider().overlay(Theme.elevated)
                            }
                            row(item)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.cardContentInset)
                    .padding(.vertical, 6)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: Self.rowHeight * CGFloat(Self.rowsPerPage) + 12 + CGFloat(Self.rowsPerPage - 1))
            .bltCardSurface()

            if chunks.count > 1 {
                HStack(spacing: 6) {
                    ForEach(chunks.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? Theme.text : Theme.idleTab)
                            .frame(width: index == page ? 16 : 6, height: 6)
                    }
                }
                .animation(.snappy(duration: 0.22), value: page)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(chunks.count) ページ中 \(page + 1) ページ目")
            }
        }
        .onChange(of: pages.count) { _, count in
            if page >= count { page = 0 }
        }
        .task(id: "\(page)/\(pages.count)") {
            guard pages.count > 1 else { return }
            try? await Task.sleep(for: Self.interval)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                page = (page + 1) % pages.count
            }
        }
    }

    private func row(_ item: FeedRSS.Item) -> some View {
        let company = CompanyRef(item)
        return NavigationLink(value: company) {
            HStack(spacing: 12) {
                CompanyIconView(company, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.displayName(company.name, fallback: company.code))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(company.code)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 8)
                if !item.submittedAt.isEmpty {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("提出日")
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                        Text(Format.submittedDate(item.submittedAt))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.text)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("提出日 \(Format.submittedDate(item.submittedAt))")
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityHidden(true)
            }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 検索ボタンでトップ上部に出る検索バー。出たらすぐ入力でき、右の円形バツで検索を閉じる。
struct TopSearchBar: View {
    @Binding var query: String
    var onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityHidden(true)
                TextField("会社名・銘柄コード", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { focused = false }
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

            Button {
                focused = false
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("検索を閉じる")
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .task { focused = true }
    }
}
