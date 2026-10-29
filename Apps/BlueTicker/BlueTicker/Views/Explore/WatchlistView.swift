import SwiftData
import SwiftUI

struct WatchlistView: View {
    @Query(sort: \WatchedCompany.sortOrder) private var companies: [WatchedCompany]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List {
            if companies.isEmpty {
                Section {
                    ContentUnavailableView(
                        "リストは空です",
                        systemImage: "star",
                        description: Text("銘柄画面から追加できます。")
                    )
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(companies) { item in
                        NavigationLink(value: CompanyRef(item)) {
                            CompanyRowView(company: CompanyRef(item))
                        }
                        .listRowBackground(Theme.elevated)
                    }
                    .onDelete(perform: delete)
                } header: {
                    Text("あなたの追加した企業")
                        .foregroundStyle(Theme.textMuted)
                        .textCase(nil)
                }
            }

            #if DEBUG
                Section("開発ラボ") {
                    NavigationLink("サーバー / HAPIS") {
                        SettingsView()
                    }
                    ForEach(Self.debugTickers) { company in
                        NavigationLink(value: company) {
                            Text(Format.displayName(company.name, fallback: company.code))
                        }
                    }
                }
            #endif

            Section {
                VersionMarkFooter()
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
        }
        .bltChrome("リスト")
        .onAppear {
            WatchedCompany.repairSortOrderIfNeeded(companies)
            WatchedCompany.removeDuplicateCodes(companies, in: modelContext)
        }
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

    #if DEBUG
        /// 通信なしで銘柄面まで行く。リストやフィードには入れない。
        /// 社名の長さだけ変えて、ピルの1行・2行を見る。
        static let debugTickers: [CompanyRef] = [
            CompanyRef(code: "7751", name: "キヤノン", sector: "電気機器"),
            CompanyRef(code: "7203", name: "トヨタ自動車", sector: "輸送用機器"),
            CompanyRef(code: "9076", name: "守谷輸送機工業", sector: "倉庫・運輸関連"),
            CompanyRef(code: "9983", name: "ファーストリテイリング", sector: "小売業"),
            CompanyRef(code: "6544", name: "ジャパンエレベーターサービスホールディングス", sector: "サービス業"),
        ]
    #endif
}
