import SwiftData
import SwiftUI
import UIKit

struct WatchlistView: View {
    @Query(sort: \WatchedCompany.sortOrder) private var companies: [WatchedCompany]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// 銘柄面へ進む経路。タイルは `NavigationLink`（ボタン）にせず、タップで積む。
    /// ボタンにすると長押しがボタンに取られて、並べ替えが始まらない。
    @Binding var path: NavigationPath

    /// 業種フィルタ。nil はすべて。
    @State private var selectedSector: TOPIX17Sector?
    /// ドラッグ中のタイルの銘柄コード。ゴミ箱の表示と並べ替えの目印。
    @State private var draggingCode: String?
    @State private var trashTargeted = false
    /// 指の位置（画面座標）。
    @State private var dragPoint: CGPoint = .zero
    /// つかんだ位置とタイル中心のずれ。最初のドラッグ値が来るまで nil。
    @State private var dragGrab: CGSize?
    /// 指に付いてくるカード。元のタイルを消す（削除する）あとも描けるよう、持ち上げた時点で控える。
    @State private var floatingCompany: CompanyRef?
    @State private var floatSize: CGSize = .zero
    @State private var floatScale: CGFloat = 1
    @State private var floatOpacity: Double = 1
    /// 指を離したあと、カードが着地する（ゴミ箱へ消える）アニメーションの間。
    @State private var isSettling = false
    /// 直前に入れ替えた相手。同じ相手との入れ替わりを繰り返さない。
    @State private var lastSwapTarget: String?
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var trashFrame: CGRect = .zero
    @State private var contentOrigin: CGPoint = .zero

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
                            CompanyTile(company: CompanyRef(item))
                                .onTapGesture {
                                    path.append(CompanyRef(item))
                                }
                                .accessibilityAddTraits(.isButton)
                            // ドラッグ中の元の場所は空白にする（指に付いてくるカードは別に描く）。
                            .opacity(draggingCode == item.code ? 0 : 1)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                                tileFrames[item.code] = frame
                            }
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
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin in
                contentOrigin = origin
            }
            .overlay(alignment: .topLeading) { floatingTile }
            .background(
                LongPressDragBridge(
                    onBegan: gestureBegan,
                    onMoved: gestureMoved,
                    onEnded: gestureEnded
                )
            )
        }
        .scrollDisabled(draggingCode != nil)
        .bltChrome("リスト")
        .safeAreaInset(edge: .bottom) {
            if draggingCode != nil {
                trashZone
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: draggingCode != nil)
        .onChange(of: scenePhase) { _, _ in endDrag() }
        .onDisappear { endDrag() }
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

    private func gestureBegan(_ point: CGPoint) {
        guard draggingCode == nil, !isSettling else { return }
        guard let item = visibleCompanies.first(where: { tileFrames[$0.code]?.contains(point) == true }),
              let frame = tileFrames[item.code]
        else { return }
        ListHaptics.lift()
        floatingCompany = CompanyRef(item)
        floatSize = frame.size
        floatScale = 1
        floatOpacity = 1
        dragGrab = CGSize(width: point.x - frame.midX, height: point.y - frame.midY)
        dragPoint = point
        lastSwapTarget = nil
        draggingCode = item.code
        withAnimation(.snappy(duration: 0.2)) { floatScale = 1.05 }
    }

    private func gestureMoved(_ point: CGPoint) {
        guard let code = draggingCode, !isSettling else { return }
        dragPoint = point

        let overTrash = !trashFrame.isEmpty && trashFrame.insetBy(dx: -24, dy: -24).contains(point)
        if overTrash != trashTargeted {
            trashTargeted = overTrash
            if overTrash { ListHaptics.swap() }
        }
        if overTrash { return }

        if tileFrames[code]?.contains(point) == true {
            lastSwapTarget = nil
            return
        }
        let target = visibleCompanies.first {
            $0.code != code && tileFrames[$0.code]?.contains(point) == true
        }?.code
        if let target, target != lastSwapTarget {
            lastSwapTarget = target
            withAnimation(.snappy(duration: 0.3)) { move(code, to: target) }
            ListHaptics.swap()
        }
    }

    /// 離したとき（動かさずに離したときも）。カードを空いた場所へ滑り込ませる。ゴミ箱の上なら縮んで消す。
    private func gestureEnded() {
        guard let code = draggingCode, !isSettling else { return }
        let grab = dragGrab ?? .zero
        if trashTargeted, !trashFrame.isEmpty, let item = companies.first(where: { $0.code == code }) {
            isSettling = true
            ListHaptics.delete()
            withAnimation(.snappy(duration: 0.28)) {
                dragPoint = CGPoint(x: trashFrame.midX + grab.width, y: trashFrame.midY + grab.height)
                floatScale = 0.2
                floatOpacity = 0
                remove(item)
            }
        } else if let frame = tileFrames[code] {
            isSettling = true
            withAnimation(.spring(duration: 0.32, bounce: 0.12)) {
                dragPoint = CGPoint(x: frame.midX + grab.width, y: frame.midY + grab.height)
                floatScale = 1
            }
        } else {
            endDrag()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(340))
            endDrag()
        }
    }

    private func endDrag() {
        isSettling = false
        trashTargeted = false
        dragGrab = nil
        lastSwapTarget = nil
        floatingCompany = nil
        floatScale = 1
        floatOpacity = 1
        if draggingCode != nil {
            withAnimation(.snappy) { draggingCode = nil }
        }
    }

    /// 指に付いてくるカード。不透明 100% で、元の場所は空白。
    @ViewBuilder
    private var floatingTile: some View {
        if draggingCode != nil, let company = floatingCompany {
            let grab = dragGrab ?? .zero
            CompanyTile(company: company)
                .frame(width: floatSize.width, height: floatSize.height)
                .scaleEffect(floatScale)
                .opacity(floatOpacity)
                .shadow(color: .black.opacity(0.4 * Double(max(floatScale - 1, 0)) / 0.05), radius: 12, y: 6)
                .position(
                    x: dragPoint.x - grab.width - contentOrigin.x,
                    y: dragPoint.y - grab.height - contentOrigin.y
                )
                .allowsHitTesting(false)
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
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                trashFrame = frame
            }
            .onDisappear { trashFrame = .zero }
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
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

/// 並べ替えの Haptic。ドラッグ中は `sensoryFeedback` が鳴らなかったため UIKit を直接使う。
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

/// スクロール領域（`UIScrollView`）に長押しの認識器を直接付ける。
/// SwiftUI のジェスチャをタイルに付けるとスクロールを妨げるため。0.3 秒動かさずに押すと始まり、
/// それより前に動かすとスクロールのまま。始まったあとは離すまで指の位置を送る（動かさずに離しても終わりが届く）。
private struct LongPressDragBridge: UIViewRepresentable {
    var onBegan: (CGPoint) -> Void
    var onMoved: (CGPoint) -> Void
    var onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: BridgeView, context: Context) {
        context.coordinator.parent = self
    }

    final class BridgeView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                coordinator?.attach(to: enclosingScrollView())
            } else {
                coordinator?.detach()
            }
        }

        private func enclosingScrollView() -> UIScrollView? {
            var view: UIView? = superview
            while let current = view {
                if let scroll = current as? UIScrollView { return scroll }
                view = current.superview
            }
            return nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: LongPressDragBridge
        private let recognizer = UILongPressGestureRecognizer()
        private weak var scrollView: UIScrollView?

        init(_ parent: LongPressDragBridge) {
            self.parent = parent
            super.init()
            recognizer.minimumPressDuration = 0.3
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(handle(_:)))
        }

        func attach(to scrollView: UIScrollView?) {
            guard let scrollView, self.scrollView !== scrollView else { return }
            detach()
            scrollView.addGestureRecognizer(recognizer)
            self.scrollView = scrollView
        }

        func detach() {
            scrollView?.removeGestureRecognizer(recognizer)
            scrollView = nil
        }

        @objc private func handle(_ gesture: UILongPressGestureRecognizer) {
            let point = gesture.location(in: nil)
            switch gesture.state {
            case .began:
                parent.onBegan(point)
            case .changed:
                parent.onMoved(point)
            case .ended, .cancelled, .failed:
                parent.onEnded()
            default:
                break
            }
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
