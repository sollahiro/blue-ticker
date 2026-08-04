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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(company.name).font(.headline)
                        Text("\(company.code) · \(company.sector) · \(company.market)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        .navigationTitle("Blue Ticker")
        .navigationDestination(for: CompanySearchResult.self) { company in
            CubeView(company: company, client: client)
        }
        .searchable(text: $query, prompt: "銘柄コード・社名")
        .onChange(of: query) { _, newValue in
            search(newValue)
        }
        .onAppear {
            // スクリーンショット検証用の一時的なデバッグフック(later removed)。
            if let seed = ProcessInfo.processInfo.environment["BLT_DEBUG_SEED_QUERY"] {
                query = seed
            }
        }
    }

    private func search(_ query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            errorMessage = nil
            return
        }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                results = try await client.searchCompanies(query: query)
            } catch {
                results = []
                errorMessage = "検索に失敗しました: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }
}

#Preview {
    NavigationStack {
        SearchView()
    }
}
