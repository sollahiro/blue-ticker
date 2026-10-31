import SwiftData
import SwiftUI

struct WatchlistView: View {
    @Query(sort: \WatchedCompany.sortOrder) private var companies: [WatchedCompany]
    @Environment(\.modelContext) private var modelContext

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if companies.isEmpty {
                    ContentUnavailableView(
                        "リストは空です",
                        systemImage: "bookmark",
                        description: Text("銘柄画面から追加できます。")
                    )
                    .padding(.top, 40)
                } else {
                    Text("あなたの追加した企業")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 4)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(companies) { item in
                            NavigationLink(value: CompanyRef(item)) {
                                CompanyTile(company: CompanyRef(item))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("リストから外す", systemImage: "trash", role: .destructive) {
                                    remove(item)
                                }
                            }
                        }
                    }
                }

                #if DEBUG
                    VStack(alignment: .leading, spacing: 10) {
                        Text("開発ラボ")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textMuted)
                        NavigationLink("サーバー / HAPIS") {
                            SettingsView()
                        }
                        ForEach(Self.debugTickers) { company in
                            NavigationLink(value: company) {
                                Text(Format.displayName(company.name, fallback: company.code))
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 12)
                #endif

                VersionMarkFooter()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .bltChrome("リスト")
        .onAppear {
            WatchedCompany.repairSortOrderIfNeeded(companies)
            WatchedCompany.removeDuplicateCodes(companies, in: modelContext)
        }
    }

    /// タイルは長押しのメニューから外す（行のスワイプ削除の代わり）。
    private func remove(_ item: WatchedCompany) {
        guard let index = companies.firstIndex(where: { $0.persistentModelID == item.persistentModelID }) else {
            return
        }
        delete(at: IndexSet(integer: index))
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
