import SwiftUI

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

extension View {
    /// 名称検索と条件検索で同じ履歴面を開く。
    func bltHistoryToolbar() -> some View {
        self
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: HistoryRoute()) {
                        Label("履歴", systemImage: "clock")
                    }
                }
            }
            .navigationDestination(for: HistoryRoute.self) { _ in
                HistoryView()
            }
    }
}
