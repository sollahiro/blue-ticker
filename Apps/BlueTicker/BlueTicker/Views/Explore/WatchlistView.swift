import SwiftData
import SwiftUI

struct WatchlistView: View {
    @Query(sort: \WatchedCompany.sortOrder) private var companies: [WatchedCompany]
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
                    ForEach(listRows) { item in
                        NavigationLink(value: CompanyRef(item)) {
                            CompanyRowView(
                                company: CompanyRef(item),
                                caption: item.listCaption
                            )
                        }
                        .listRowBackground(Theme.elevated)
                    }
                    .onDelete(perform: delete)
                    .onMove(perform: move)
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
        .onAppear {
            WatchedCompany.repairSortOrderIfNeeded(companies)
            WatchedCompany.pruneBlankRowsCoveredByHoldings(companies, in: modelContext)
        }
    }

    /// 同じ銘柄に保有があるとき、残ったウォッチ行は出さない。
    private var listRows: [WatchedCompany] {
        companies.filter { item in
            if item.isHolding { return true }
            return !companies.contains { $0.code == item.code && $0.isHolding }
        }
    }

    private func delete(at offsets: IndexSet) {
        let removed = offsets.map { listRows[$0] }
        let removedCodes = Set(removed.map(\.code))
        for item in removed {
            modelContext.delete(item)
        }
        let remaining = companies.filter { item in
            !removed.contains { $0.persistentModelID == item.persistentModelID }
        }
        for code in removedCodes where !remaining.contains(where: { $0.code == code }) {
            Task { await APIClient.shared.unpinCode(code) }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = listRows
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, item) in ordered.enumerated() {
            item.sortOrder = index
        }
    }
}
