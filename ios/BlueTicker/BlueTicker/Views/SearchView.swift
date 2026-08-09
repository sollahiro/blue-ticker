import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var results: [CompanySearchResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    private let client = APIClient.local

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            ForEach(results) { company in
                NavigationLink(value: company) {
                    HStack(spacing: 12) {
                        CompanyIconView(url: company.iconURL, name: company.name)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(company.name).font(.headline)
                            Text("\(company.code) · \(company.sector) · \(company.market)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            } else if results.isEmpty && !query.isEmpty && errorMessage == nil {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Prism")
        .navigationDestination(for: CompanySearchResult.self) { company in
            CubeView(company: company, client: client)
        }
        .searchable(text: $query, prompt: "銘柄コード・社名")
        // クエリが変わるたびに直前の検索を自動キャンセルする(.task(id:) の標準挙動)。
        // 古い応答が新しい結果を上書きする競合を防ぐ(手動 Task 起動+onChange だと発生する)。
        .task(id: query) {
            await search(query)
        }
        .onAppear {
            #if DEBUG
                // スクリーンショット検証用の一時的なデバッグフック(later removed)。リリースビルドには含まれない。
                if let seed = ProcessInfo.processInfo.environment["BLT_DEBUG_SEED_QUERY"] {
                    query = seed
                }
            #endif
        }
    }

    @MainActor
    private func search(_ query: String) async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            errorMessage = nil
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            results = try await client.searchCompanies(query: query)
        } catch {
            // クエリ変更による自動キャンセル(URLSession は URLError(.cancelled) を投げる)は
            // 古い検索の後始末であり、ユーザーへエラー表示しない。
            if (error as? URLError)?.code == .cancelled || error is CancellationError { return }
            results = []
            errorMessage = "検索に失敗しました: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

#Preview {
    NavigationStack {
        SearchView()
    }
}
