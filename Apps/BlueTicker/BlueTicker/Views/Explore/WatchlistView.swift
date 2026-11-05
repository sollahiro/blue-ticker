import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct WatchlistView: View {
    @Query(sort: \WatchedCompany.sortOrder) private var companies: [WatchedCompany]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    /// 業種フィルタ。nil はすべて。
    @State private var selectedSector: TOPIX17Sector?
    /// ドラッグ中のタイルの銘柄コード。ゴミ箱の表示と並べ替えの目印。
    @State private var draggingCode: String?
    @State private var trashTargeted = false
    @State private var activity = DragActivity()

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
                                ListHaptics.lift()
                                startWatchdog()
                                return NSItemProvider(object: item.code as NSString)
                            }
                            .onDrop(
                                of: [.plainText],
                                delegate: TileDropDelegate(target: item.code, dragging: $draggingCode, activity: activity) { from, to in
                                    withAnimation(.snappy(duration: 0.3)) { move(from, to: to) }
                                    ListHaptics.swap()
                                }
                            )
                            .accessibilityAction(named: "リストから外す") {
                                remove(item)
                            }
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    // 並びが変わったとき、他のタイルがなめらかに入れ替わる。
                    .animation(.snappy(duration: 0.3), value: visibleCompanies.map(\.code))
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
        .onDrop(of: [.plainText], delegate: DragEndDropDelegate(dragging: $draggingCode, activity: activity))
        .safeAreaInset(edge: .bottom) {
            if draggingCode != nil {
                trashZone
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: draggingCode != nil)
        // ドラッグ終了を取りこぼしたときの保険。画面に触れたら元の状態へ戻す。
        .simultaneousGesture(TapGesture().onEnded { endDrag() })
        .onChange(of: scenePhase) { _, _ in endDrag() }
        .onChange(of: trashTargeted) { _, targeted in
            if targeted { ListHaptics.swap() }
        }
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

    private func endDrag() {
        activity.suspended = nil
        if draggingCode != nil { draggingCode = nil }
        if trashTargeted { trashTargeted = false }
    }

    /// 取り消しや一瞬で離したときは終了が通知されない。ドロップ側の更新が途絶えたら状態を戻す。
    /// 画面内に指が戻ってきたら（`DragEndDropDelegate`）同じタイルで再開する。
    private func startWatchdog() {
        activity.suspended = nil
        activity.touch()
        activity.task?.cancel()
        activity.task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let code = draggingCode else { return }
                if Date.now.timeIntervalSince(activity.last) > 1.5 {
                    endDrag()
                    activity.suspended = code
                    return
                }
            }
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
                delegate: TrashDropDelegate(isTargeted: $trashTargeted, dragging: $draggingCode, activity: activity) { code in
                    if let item = companies.first(where: { $0.code == code }) {
                        withAnimation(.snappy) { remove(item) }
                        ListHaptics.delete()
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
    let activity: DragActivity
    let move: (String, String) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        activity.touch()
        guard let dragging, dragging != target else { return }
        move(dragging, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        activity.touch()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        activity.suspended = nil
        dragging = nil
        return true
    }
}

/// ゴミ箱の上で離したら外す。
private struct TrashDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var dragging: String?
    let activity: DragActivity
    let remove: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }
    func dropEntered(info: DropInfo) {
        activity.touch()
        isTargeted = true
    }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        activity.touch()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        activity.suspended = nil
        isTargeted = false
        if let code = dragging { remove(code) }
        dragging = nil
        return true
    }
}

/// 画面のどこで離してもドラッグ状態（ゴミ箱の表示）を終える。
private struct DragEndDropDelegate: DropDelegate {
    @Binding var dragging: String?
    let activity: DragActivity

    func dropEntered(info: DropInfo) { resumeIfSuspended() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        activity.touch()
        resumeIfSuspended()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        activity.suspended = nil
        dragging = nil
        return true
    }

    /// 更新の途絶で一度戻したあとも、指が画面に戻ってきたらドラッグ中の表示へ戻す。
    private func resumeIfSuspended() {
        activity.touch()
        guard dragging == nil, let code = activity.suspended else { return }
        activity.suspended = nil
        dragging = code
    }
}

/// ドロップ側の更新時刻。画面の再描画に使わないので参照型にしている。
@MainActor
private final class DragActivity {
    var last = Date.now
    /// 更新の途絶で一度戻したときのタイルの銘柄コード。
    var suspended: String?
    var task: Task<Void, Never>?

    func touch() { last = .now }
}

/// 並べ替えの Haptic。ドラッグ中の `sensoryFeedback` は鳴らないことがあるため UIKit を直接使う。
@MainActor
private enum ListHaptics {
    private static let impact = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let selection = UISelectionFeedbackGenerator()

    /// タイルを持ち上げた。
    static func lift() {
        impact.impactOccurred()
    }

    /// 場所が入れ替わった・ゴミ箱の上に入った。
    static func swap() {
        selection.selectionChanged()
        selection.prepare()
    }

    /// 削除した。
    static func delete() {
        heavy.impactOccurred()
    }
}
