import Foundation
import SwiftUI

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

/// トップ右上の時計から開く、最近調べた企業の一覧。
struct HistoryListView: View {
    @State private var history: [CompanyRef] = []

    var body: some View {
        List {
            if history.isEmpty {
                ContentUnavailableView(
                    "履歴はありません",
                    systemImage: "clock",
                    description: Text("調べた企業がここに並びます。")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(history) { company in
                        NavigationLink(value: company) {
                            CompanyRowView(company: company)
                        }
                    }
                } header: {
                    Text("最近あなたが調べた企業")
                        .foregroundStyle(Theme.textMuted)
                        .textCase(nil)
                }
            }
        }
        .bltChrome("履歴")
        .onAppear { history = CompanyHistory.load() }
    }
}
