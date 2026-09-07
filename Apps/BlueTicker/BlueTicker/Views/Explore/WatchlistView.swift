import SwiftData
import SwiftUI

struct WatchlistView: View {
    @Query(sort: \WatchedCompany.addedAt, order: .reverse) private var companies: [WatchedCompany]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if companies.isEmpty {
                ContentUnavailableView(
                    "リストは空です",
                    systemImage: "star",
                    description: Text("銘柄画面から追加できます。")
                )
            } else {
                List {
                    ForEach(companies) { item in
                        NavigationLink(value: CompanyRef(item)) {
                            CompanyRowView(company: CompanyRef(item))
                        }
                        .listRowBackground(Theme.elevated)
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle("リスト")
        .bltChrome()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(companies[index])
        }
    }
}
