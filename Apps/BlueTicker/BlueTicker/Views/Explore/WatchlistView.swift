import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct WatchlistView: View {
    @Query(sort: \WatchedCompany.sortOrder) private var companies: [WatchedCompany]
    @Environment(\.modelContext) private var modelContext

    /// 業種フィルタ。nil はすべて。
    @State private var selectedSector: TOPIX17Sector?
    /// ドラッグ中のタイルの銘柄コード。ゴミ箱の表示と並べ替えの目印。
    @State private var draggingCode: String?
    @State private var trashTargeted = false

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
                    HStack {
                        Text("あなたの追加した企業")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textMuted)
                        Spacer()
                        if !sectorCounts.isEmpty {
                            sectorMenu
                        }
                    }
                    .padding(.horizontal, 4)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(visibleCompanies) { item in
                            NavigationLink(value: CompanyRef(item)) {
                                CompanyTile(company: CompanyRef(item))
                            }
                            .buttonStyle(.plain)
                            .opacity(draggingCode == item.code ? 0.4 : 1)
                            .onDrag {
                                draggingCode = item.code
                                return NSItemProvider(object: item.code as NSString)
                            }
                            .onDrop(
                                of: [.plainText],
                                delegate: TileDropDelegate(target: item.code, dragging: $draggingCode) { from, to in
                                    withAnimation(.snappy) { move(from, to: to) }
                                }
                            )
                            .accessibilityAction(named: "リストから外す") {
                                remove(item)
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
        .onDrop(of: [.plainText], delegate: DragEndDropDelegate(dragging: $draggingCode))
        .safeAreaInset(edge: .bottom) {
            if draggingCode != nil {
                trashZone
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: draggingCode != nil)
        .onChange(of: sectorCounts.map(\.sector)) { _, sectors in
            if let selectedSector, !sectors.contains(selectedSector) {
                self.selectedSector = nil
            }
        }
        .onAppear {
            WatchedCompany.repairSortOrderIfNeeded(companies)
            WatchedCompany.removeDuplicateCodes(companies, in: modelContext)
        }
    }

    /// 業種フィルタ適用後のタイル。並びは全体の `sortOrder` のまま。
    private var visibleCompanies: [WatchedCompany] {
        guard let selectedSector else { return companies }
        return companies.filter { TOPIX17Sector(tseSector: $0.sector) == selectedSector }
    }

    /// 登録の多い業種順（同数は業種の定義順）。TOPIX-17 に振り分けられない銘柄は数えない。
    private var sectorCounts: [(sector: TOPIX17Sector, count: Int)] {
        var counts: [TOPIX17Sector: Int] = [:]
        for item in companies {
            if let sector = TOPIX17Sector(tseSector: item.sector) {
                counts[sector, default: 0] += 1
            }
        }
        let order = TOPIX17Sector.allCases
        return counts
            .map { (sector: $0.key, count: $0.value) }
            .sorted {
                $0.count != $1.count
                    ? $0.count > $1.count
                    : (order.firstIndex(of: $0.sector) ?? 0) < (order.firstIndex(of: $1.sector) ?? 0)
            }
    }

    private var sectorMenu: some View {
        Menu {
            Picker("業種", selection: $selectedSector) {
                Text("すべて（\(companies.count)）").tag(TOPIX17Sector?.none)
                ForEach(sectorCounts, id: \.sector) { entry in
                    Label("\(entry.sector.title)（\(entry.count)）", systemImage: entry.sector.symbol)
                        .tag(TOPIX17Sector?.some(entry.sector))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedSector?.title ?? "すべての業種")
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.text)
        }
        .accessibilityLabel("業種で絞り込む")
    }

    private var trashZone: some View {
        Image(systemName: trashTargeted ? "trash.fill" : "trash")
            .font(.title2.weight(.semibold))
            .foregroundStyle(trashTargeted ? Color.white : Theme.text)
            .frame(width: 64, height: 64)
            .background(trashTargeted ? Color.red : Theme.card, in: Circle())
            .scaleEffect(trashTargeted ? 1.15 : 1)
            .animation(.snappy, value: trashTargeted)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onDrop(
                of: [.plainText],
                delegate: TrashDropDelegate(isTargeted: $trashTargeted, dragging: $draggingCode) { code in
                    if let item = companies.first(where: { $0.code == code }) {
                        withAnimation(.snappy) { remove(item) }
                    }
                }
            )
            .accessibilityLabel("ゴミ箱。ここへドラッグするとリストから外します")
    }

    /// `code` のタイルを `target` の位置へ動かし、全体の並びを振り直す。
    private func move(_ code: String, to target: String) {
        var ordered = companies
        guard let from = ordered.firstIndex(where: { $0.code == code }),
              let to = ordered.firstIndex(where: { $0.code == target }),
              from != to
        else { return }
        ordered.insert(ordered.remove(at: from), at: to)
        for (index, item) in ordered.enumerated() {
            item.sortOrder = index
        }
    }

    /// タイルをゴミ箱へドラッグして外す（アクセシビリティからも呼ぶ）。（行のスワイプ削除の代わり）。
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

/// タイルの上へ入ったら、ドラッグ中のタイルをその位置へ動かす。
private struct TileDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let move: (String, String) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        move(dragging, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// ゴミ箱の上で離したら外す。
private struct TrashDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var dragging: String?
    let remove: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }
    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        if let code = dragging { remove(code) }
        dragging = nil
        return true
    }
}

/// 画面のどこで離してもドラッグ状態（ゴミ箱の表示）を終える。
private struct DragEndDropDelegate: DropDelegate {
    @Binding var dragging: String?

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
