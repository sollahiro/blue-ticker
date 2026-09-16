import SwiftData
import SwiftUI

struct WatchlistView: View {
    @Query(sort: \WatchedCompany.sortOrder) private var companies: [WatchedCompany]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.editMode) private var editMode

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
                        Group {
                            if isEditing {
                                NavigationLink {
                                    FundPositionEditView(item: item) {
                                        addAccount(from: item)
                                    }
                                } label: {
                                    CompanyRowView(
                                        company: CompanyRef(item),
                                        caption: item.listCaption
                                    )
                                }
                            } else {
                                NavigationLink(value: CompanyRef(item)) {
                                    CompanyRowView(
                                        company: CompanyRef(item),
                                        caption: item.listCaption
                                    )
                                }
                            }
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
        }
    }

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing == true
    }

    private func delete(at offsets: IndexSet) {
        let removed = offsets.map { companies[$0] }
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
        var ordered = companies
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, item) in ordered.enumerated() {
            item.sortOrder = index
        }
    }

    private func addAccount(from item: WatchedCompany) {
        modelContext.insert(
            item.duplicateAccountRow(sortOrder: WatchedCompany.nextSortOrder(among: companies))
        )
    }
}
