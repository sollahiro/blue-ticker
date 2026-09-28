import CoreText
import SwiftData
import SwiftUI
import UIKit

enum TickerPage: Int, CaseIterable, Hashable, Identifiable {
    case summary, breakdown

    var id: TickerPage { self }
}

struct TickerView: View {
    var company: CompanyRef
    @Environment(\.modelContext) private var modelContext
    @Query private var watched: [WatchedCompany]
    @State private var page: TickerPage = .summary
    @State private var summarySection: SummarySection = .performance
    @State private var breakdownMetric: BreakdownMetric = .businessProfit
    @State private var resolvedSector = ""
    @State private var showsHoldings = false
    @State private var showsCompanyCard = false
    /// 社名ピルの見た目を窓上のガラスへ渡したか。
    /// 渡したあとはタイトル用ガラスを出さず、同じガラスがカードへ広がる。
    /// 戻ると右上はナビのまま。社名ピルだけナビのタイトル遷移から外す。
    @State private var pillHandedOff = false
    /// タイトル位置の社名ピルのウィンドウ座標。広がる始点に使う。
    @State private var pillRect: CGRect = .zero
    @State private var contentWidth: CGFloat = 0
    /// 星のアニメーション。追加はレイヤーごとのバウンス（discrete のトリガ）。
    /// 削除の描画オフは indefinite 効果なので、消した直後だけ isActive にして戻す。
    @State private var watchAdded = 0
    @State private var watchDrawOff = false

    var body: some View {
        VStack(spacing: 0) {
            cards
            pageDots
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { contentWidth = $0 }
        .background(Theme.shell.ignoresSafeArea())
        // ピルとカードはバーより上の一つのガラス。ビュー内オーバーレイは
        // UIKit のバーより必ず下に合成されてかぶせられない。
        .overlay {
            CompanyGlassPresenter(
                handedOff: $pillHandedOff,
                expanded: showsCompanyCard,
                pillRect: pillRect,
                company: displayCompany,
                onExpanded: { showsCompanyCard = $0 },
                onFittedPill: { pillRect = $0 }
            )
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            // タイトル領域に置くと、戻ると右上グループの残りをシステムが割り当てる。
            // 右上の幅を固定予約すると機種によって足りず、「…」へ折りたたまれる。
            ToolbarItem(placement: .title) {
                // 場所はタイトル位置のまま。見た目のガラスは窓上へ出す。
                // ここに glassEffect を付けると、ナビのタイトルとして横スライドする。
                if pillHandedOff {
                    Color.clear
                        .frame(width: max(pillRect.width, 1), height: max(pillRect.height, 1))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Format.displayName(company.name, fallback: company.code))
                        .accessibilityHint("銘柄コード・業種・Overview を表示します")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { showsCompanyCard = true }
                        .accessibilityHidden(showsCompanyCard)
                } else {
                    Button {
                        showsCompanyCard = true
                    } label: {
                        // 内容幅まで縮める。上限は中央タイトルが戻る・右ボタンに被らない幅。
                        CompanyPillLabel(company: company)
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: titlePillMaxWidth)
                    .clipped()
                    .opacity(0)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { pillRect = $0 }
                    .accessibilityLabel(Format.displayName(company.name, fallback: company.code))
                    .accessibilityHint("銘柄コード・業種・Overview を表示します")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("保有情報", systemImage: "square.and.pencil", action: openHoldings)
                Button(action: toggleWatch) {
                    Image(systemName: isWatched ? "star.fill" : "star")
                        .contentTransition(.symbolEffect(.replace.downUp.byLayer))
                        .symbolEffect(.drawOff.byLayer, isActive: watchDrawOff)
                }
                .accessibilityLabel(isWatched ? "リストから削除" : "リストに追加")
                .accessibilityAddTraits(isWatched ? .isSelected : [])
                .symbolEffect(.bounce.byLayer, value: watchAdded)
            }
        }
        .background { InteractivePopGestureEnabler(allowsPop: page == .summary && !showsCompanyCard) }
        .navigationDestination(isPresented: $showsHoldings) {
            TickerHoldingsView(code: company.code, onAddAccount: addAccount)
        }
        .task { await hydrateSector() }
    }

    /// `TabView` の page は戻るジェスチャと食い違って、カードが途中で止まりやすい。
    private var cards: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    SummaryView(code: company.code, section: $summarySection)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .id(TickerPage.summary)
                    BreakdownView(code: company.code, metric: $breakdownMetric)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .id(TickerPage.breakdown)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: scrolledPage)
            .scrollIndicators(.hidden)
            .scrollEdgeEffectHidden(true)
            .contentMargins(.all, 0, for: .scrollContent)
            .background { PagerSnapper() }
        }
    }

    private var scrolledPage: Binding<TickerPage?> {
        Binding(
            get: { page },
            set: { newValue in
                guard let newValue else { return }
                page = newValue
            }
        )
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(TickerPage.allCases) { item in
                Circle()
                    .fill(page == item ? Theme.text : Theme.text.opacity(0.28))
                    .frame(width: page == item ? 7 : 6, height: page == item ? 7 : 6)
                    .accessibilityLabel(item == .summary ? "概要" : "分解")
                    .accessibilityAddTraits(page == item ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.tickerPageDotGutter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("カード \(page.rawValue + 1) / \(TickerPage.allCases.count)")
    }

    private var matchingRows: [WatchedCompany] {
        watched.filter { $0.code == company.code }
    }

    private var isWatched: Bool {
        !matchingRows.isEmpty
    }

    private var displaySector: String {
        company.sector.isEmpty ? resolvedSector : company.sector
    }

    private var displayCompany: CompanyRef {
        CompanyRef(
            code: company.code,
            name: company.name,
            sector: displaySector,
            iconURL: company.iconURL
        )
    }

    /// 中央のタイトルは左右へ均等に伸びる。広い側（右の2ボタン）の2倍を空ける。
    private var titlePillMaxWidth: CGFloat {
        let side: CGFloat = 122
        guard contentWidth > 0 else { return .infinity }
        return max(contentWidth - side * 2, 120)
    }

    private func hydrateSector() async {
        if company.sector.isEmpty {
            resolvedSector = await Self.loadSector(code: company.code)
        }
        backfillWatchedSectorIfNeeded()
        CompanyHistory.record(displayCompany)
    }

    private static func loadSector(code: String) async -> String {
        if let cached = await APIClient.shared.cachedFinancials(code: code), !cached.sector.isEmpty {
            return cached.sector
        }
        if let loaded = try? await APIClient.shared.financials(code: code), !loaded.sector.isEmpty {
            return loaded.sector
        }
        return ""
    }

    private func toggleWatch() {
        let matching = matchingRows
        if matching.isEmpty {
            _ = insertWatchRow()
            watchAdded += 1
        } else {
            for item in matching {
                modelContext.delete(item)
            }
            watchDrawOff = true
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                watchDrawOff = false
            }
            Task { await APIClient.shared.unpinCode(company.code) }
        }
    }

    private func openHoldings() {
        if matchingRows.isEmpty {
            _ = insertWatchRow()
        }
        showsHoldings = true
    }

    @discardableResult
    private func insertWatchRow() -> WatchedCompany {
        let row = WatchedCompany(
            code: company.code,
            name: company.name,
            sector: displaySector,
            iconURL: company.iconURL,
            sortOrder: WatchedCompany.nextSortOrder(among: watched)
        )
        modelContext.insert(row)
        Task { await APIClient.shared.pinCode(company.code) }
        return row
    }

    private func addAccount() -> WatchedCompany {
        if let blank = matchingRows.first(where: \.isBlankHoldingsRow) {
            return blank
        }
        let template = matchingRows.first
        let created =
            template?.duplicateAccountRow(
                sortOrder: WatchedCompany.nextSortOrder(among: watched)
            )
            ?? WatchedCompany(
                code: company.code,
                name: company.name,
                sector: displaySector,
                iconURL: company.iconURL,
                sortOrder: WatchedCompany.nextSortOrder(among: watched)
            )
        modelContext.insert(created)
        Task { await APIClient.shared.pinCode(company.code) }
        return created
    }

    /// Feed から先に追加しても、後から取れた業種でウォッチ行を埋める。
    private func backfillWatchedSectorIfNeeded() {
        let sector = displaySector
        guard !sector.isEmpty else { return }
        for existing in watched where existing.code == company.code && existing.sector.isEmpty {
            existing.sector = sector
        }
    }
}

struct SegmentPills<Item: Identifiable & Hashable>: View {
    var items: [Item]
    @Binding var selection: Item
    var title: (Item) -> String
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let current = selection == item
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selection = item
                    }
                } label: {
                    Text(title(item))
                        .font(.subheadline.weight(current ? .semibold : .regular))
                        .foregroundStyle(current ? Theme.text : Theme.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if current {
                                Capsule()
                                    .fill(Color.white.opacity(0.16))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(item))
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
    }
}

struct TickerStubView: View {
    var title: String
    var detail: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(Theme.cardContentInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .bltCardScroll()
    }
}

/// 横スクロールがキャンセルされても、カード幅へスナップし直す。
/// 通常のフリックは減速中に触らず、ネイティブの paging に任せる。
private struct PagerSnapper: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(from: uiView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        private weak var scrollView: UIScrollView?

        deinit {
            scrollView?.panGestureRecognizer.removeTarget(self, action: nil)
        }

        func attach(from view: UIView) {
            guard let scrollView = view.nearestHorizontalScrollView() else { return }
            scrollView.isDirectionalLockEnabled = true
            guard scrollView !== self.scrollView else { return }
            self.scrollView?.panGestureRecognizer.removeTarget(self, action: nil)
            self.scrollView = scrollView
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .cancelled, .failed:
                DispatchQueue.main.async { [weak self] in
                    self?.snapToNearestPage(interruptDeceleration: true)
                }
            case .ended:
                DispatchQueue.main.async { [weak self] in
                    self?.snapToNearestPage(interruptDeceleration: false)
                }
            default:
                break
            }
        }

        private func snapToNearestPage(interruptDeceleration: Bool) {
            guard let scrollView, !scrollView.isDragging, !scrollView.isTracking else { return }
            if !interruptDeceleration, scrollView.isDecelerating { return }
            let width = scrollView.bounds.width
            guard width > 0 else { return }
            let maxIndex = max((scrollView.contentSize.width / width).rounded(.down) - 1, 0)
            let index = min(max((scrollView.contentOffset.x / width).rounded(), 0), maxIndex)
            let target = CGPoint(x: index * width, y: scrollView.contentOffset.y)
            let delta = abs(scrollView.contentOffset.x - target.x)
            guard delta > 0.5 else { return }
            scrollView.setContentOffset(target, animated: delta > 8)
        }
    }
}

/// 戻る・右上ボタンから測った、ピルを置く隙間。
private struct NavigationChrome {
    var leadingMaxX: CGFloat = 0
    var trailingMinX: CGFloat = 0
    var controlHeight: CGFloat = 0
    var controlMidY: CGFloat = 0
    /// 戻る円とピル、ピルと編集ボタンのあいだ。両方ともこの値。
    var gap: CGFloat = 10
    var foundLeading = false
    var foundTrailing = false
    /// 左右の円ボタンが、バーの端に実際にあるときだけ真。
    var isPlausible = false
    /// 編集と星の組の幅と、バーの余白から置いた。滑っている枠ではない。
    var stable = false
    var foundControl: Bool { isPlausible }
}

/// ナビゲーションバーのレイアウトに合わせて、円ボタンの位置を測り直す。
private final class ChromeLayoutProbe: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// 社名ピルの出現。ナビのタイトルスライドとは別で、その場の不透明度だけ変える。
private enum CompanyPillReveal {
    /// 遷移コーディネータが無いときのフェード。push に合わせるときは遷移時間を使う。
    static var showDuration: TimeInterval { UIAccessibility.isReduceMotionEnabled ? 0.08 : 0.20 }
    static var hideDuration: TimeInterval { UIAccessibility.isReduceMotionEnabled ? 0.06 : 0.12 }
}

/// 社名ピルと詳細カードを、ナビゲーションバーより上の一つの Liquid Glass として出す。
/// ビュー内オーバーレイはバーの下に合成されるため、バーの親へ載せる。
private struct CompanyGlassPresenter: UIViewRepresentable {
    @Binding var handedOff: Bool
    var expanded: Bool
    var pillRect: CGRect
    var company: CompanyRef
    var onExpanded: (Bool) -> Void
    var onFittedPill: (CGRect) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(
            handedOff: handedOff,
            setHandedOff: { handedOff = $0 },
            expanded: expanded,
            pillRect: pillRect,
            company: company,
            onExpanded: onExpanded,
            onFittedPill: onFittedPill,
            anchor: uiView
        )
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.removeHost()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        private let model = CompanyGlassModel()
        private let tapCatcher = GlassTapCatcher()
        private let titleHider = ToolbarTitleHider()
        private var openTap: UITapGestureRecognizer?
        private var host: UIHostingController<CompanyGlassMorph>?
        private var wrapper: GlassPassThroughView?
        private var cardContainer: MorphClipView?
        private var morphLink: CADisplayLink?
        private var trackPillHeight: CGFloat = 0
        private var trackCardHeight: CGFloat = 0
        private var trackCardWidth: CGFloat = 0
        private var disappearHook: GlassDisappearHook?
        private var handoffScheduled = false
        private var didDisappear = false
        /// 開閉のアニメーション中。SwiftUI の `expanded` は完了まで遅れるので、
        /// そのあいだの更新で逆方向へアニメーションを始めない。
        private var morphing = false
        /// 銘柄面が見えていないあいだは、窓上のガラスを付け直さない。
        private var tickerVisible = true
        /// 窓上ピルをフェードインし終えたか。毎フレームの更新で重ねない。
        private var revealed = false
        /// フェードアウト完了前に appear が来たら、外す処理を無効化する。
        private var concealGeneration = 0
        /// ボタンのあいだに収めたあとのピル幅。それより広い測り直しでは社名を組み直さない。
        private var lockedNameWidth: CGFloat = 0
        private var chromeProbe: ChromeLayoutProbe?
        private var chromeLayoutPending = false
        private var watchedTransition = false
        private var fittingChrome = false
        /// フェード中。枠のアニメーションには乗せない。差し替えると終端の矩形へ戻る。
        private var revealAnimating = false
        /// ボタンのあいだに一度置いた枠。滑っている測り直しでは動かさない。
        private var pillFrameCommitted = false
        /// 編集と星の組の幅で置けたか、push が終わったか。それまでは着地後の寸法へ合わせ直す。
        private var chromeSettled = false
        /// 直前の測りが、組の幅と余白から置けている。
        private var chromeStable = false

        func update(
            handedOff: Bool,
            setHandedOff: @escaping (Bool) -> Void,
            expanded: Bool,
            pillRect: CGRect,
            company: CompanyRef,
            onExpanded: @escaping (Bool) -> Void,
            onFittedPill: @escaping (CGRect) -> Void,
            anchor: UIView
        ) {
            model.company = company
            model.onExpanded = onExpanded
            guard let nav = anchor.nearestNavigationController(),
                  let ticker = anchor.nearestViewController() else { return }
            installHook(on: ticker, setHandedOff: setHandedOff)
            // タイトル用ガラスは push の最初から出さない。ナビに乗ると横スライドする。
            // 戻る・右上は触らない。対象は銘柄面のタイトルだけ。
            titleHider.bar = nav.navigationBar
            titleHider.item = ticker.navigationItem
            if pillRect.width > 1 {
                titleHider.pill = pillRect
            }
            titleHider.start()
            guard tickerVisible else { return }
            let coordinator = nav.transitionCoordinator
            let sliding = coordinator?.isAnimated == true
            // スライド中のタイトル座標は使わない。幅と高さはバー上のボタンから組む。
            if host == nil, !sliding, Self.plausiblePill(pillRect) {
                let unset = model.pillRect.width < 1
                let sameBand = abs(pillRect.minY - model.pillRect.minY) < 24
                if unset || (sameBand && pillRect.width + 1 >= model.pillRect.width) {
                    model.pillRect = pillRect
                }
            }
            if !handedOff {
                scheduleHandoff(from: nav, setHandedOff: setHandedOff)
            }
            guard handedOff || handoffScheduled else { return }
            guard nav.navigationBar.bounds.width > 80, nav.view.window != nil else { return }
            installChromeProbe(on: nav, onFittedPill: onFittedPill)
            watchTransition(of: nav, onFittedPill: onFittedPill)
            // 円が無いフレームでは出さない。バーのレイアウトが付いたら同じ遷移でフェードする。
            let ready = navigationChrome(in: nav.navigationBar).isPlausible
            let created = ready && ensureHost(in: nav, onFittedPill: onFittedPill)
            if ready, host != nil, !morphing, !model.expanded, model.expansion < 0.02 {
                refitCollapsedPill(in: nav, onFittedPill: onFittedPill)
            }
            if let cardContainer {
                wrapper?.cardFrame = cardContainer.frame
            }
            openTap?.isEnabled = !model.expanded
            host?.view.isUserInteractionEnabled = model.expanded
            if let wrapper {
                wrapper.window?.bringSubviewToFront(wrapper)
            }
            model.onCoversScreen = { [weak self] covers in
                self?.wrapper?.hitEverywhere = covers
            }
            model.onToggle = { [weak self] expanded in
                // onExpanded より先に立てる。SwiftUI の再入で逆方向へ開閉しない。
                self?.morphing = true
                self?.animateExpanded(expanded)
            }
            model.onOverview = { [weak self] in
                self?.growIfNeeded()
            }
            updateModalAccessibility()
            if created {
                revealHost(alongside: coordinator)
            }
            // ホストを載せた最初のフレームは必ずピルの形から始める。
            // 挿入と同じトランザクションで広げると中間フレームが出ない。
            if created && expanded {
                model.expanded = false
                DispatchQueue.main.async { [model] in
                    model.setExpanded(true)
                }
            } else if host != nil, !morphing, expanded != model.expanded {
                // タイトル位置の VoiceOver 操作は SwiftUI 側のフラグだけを変える。
                model.setExpanded(expanded)
            }
        }

        private func updateModalAccessibility() {
            wrapper?.accessibilityViewIsModal = model.expanded || model.expansion > 0.02
        }

        private func scheduleHandoff(
            from _: UINavigationController, setHandedOff: @escaping (Bool) -> Void
        ) {
            guard tickerVisible, !handoffScheduled else { return }
            handoffScheduled = true
            setHandedOff(true)
        }

        private func installHook(on ticker: UIViewController, setHandedOff: @escaping (Bool) -> Void) {
            if disappearHook != nil { return }
            let hook = GlassDisappearHook()
            hook.view.isUserInteractionEnabled = false
            hook.view.backgroundColor = .clear
            hook.view.frame = .zero
            ticker.addChild(hook)
            ticker.view.addSubview(hook.view)
            hook.didMove(toParent: ticker)
            hook.onWillDisappear = { [weak self] coordinator in
                self?.concealHost(alongside: coordinator, setHandedOff: setHandedOff)
            }
            hook.onWillAppear = { [weak self] coordinator in
                guard let self else { return }
                self.tickerVisible = true
                guard self.didDisappear else { return }
                self.didDisappear = false
                if self.host != nil {
                    self.revealHost(alongside: coordinator)
                } else {
                    setHandedOff(true)
                }
            }
            disappearHook = hook
        }

        @discardableResult
        private func ensureHost(
            in nav: UINavigationController, onFittedPill: @escaping (CGRect) -> Void
        ) -> Bool {
            if host != nil { return false }
            guard let window = nav.view.window else { return false }
            let wrapper = GlassPassThroughView()
            wrapper.backgroundColor = .clear
            wrapper.frame = window.bounds
            wrapper.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            let container = MorphClipView()
            container.backgroundColor = .clear
            container.clipsToBounds = true
            container.layer.cornerCurve = .continuous
            let measured = model.pillRect
            let pill = fittedPill(measured, bar: nav.navigationBar)
            model.pillRect = pill
            if abs(pill.width - measured.width) > 1
                || abs(pill.minX - measured.minX) > 1
                || abs(pill.minY - measured.minY) > 1
                || abs(pill.height - measured.height) > 1
            {
                DispatchQueue.main.async {
                    onFittedPill(pill)
                }
            }
            container.frame = pill
            container.layer.cornerRadius = pill.height / 2
            container.transform = .identity
            pillFrameCommitted = chromeStable
            let expandedWidth = window.bounds.width - 16
            model.cardWidth = expandedWidth
            model.visibleWidth = pill.width
            applyNameLock(pillWidth: pill.width)
            let host = UIHostingController(rootView: CompanyGlassMorph(model: model))
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.view.autoresizingMask = []
            let expandedHeight = measuredHeight(width: expandedWidth)
            host.view.frame = CGRect(x: 0, y: 0, width: expandedWidth, height: expandedHeight)
            container.addSubview(host.view)
            wrapper.addSubview(container)
            wrapper.cardFrame = container.frame
            tapCatcher.onOpen = { [weak self] in
                self?.model.setExpanded(true)
            }
            tapCatcher.onBackground = { [weak self] gesture in
                self?.backgroundTapped(gesture)
            }
            let open = UITapGestureRecognizer(target: tapCatcher, action: #selector(GlassTapCatcher.openTapped))
            container.addGestureRecognizer(open)
            openTap = open
            let background = UITapGestureRecognizer(target: tapCatcher, action: #selector(GlassTapCatcher.backgroundTapped(_:)))
            background.cancelsTouchesInView = false
            wrapper.addGestureRecognizer(background)
            // 親 VC を付けずにウィンドウへ載せる。ナビの子にするとスタックと
            // ビュー階層が食い違う。バーより上に描くためのホストだけ。
            wrapper.alpha = 0
            window.addSubview(wrapper)
            self.wrapper = wrapper
            self.cardContainer = container
            self.host = host
            titleHider.bar = nav.navigationBar
            titleHider.item = nav.topViewController?.navigationItem
            titleHider.pill = model.pillRect
            titleHider.start()
            revealed = false
            return true
        }

        private static func plausiblePill(_ rect: CGRect) -> Bool {
            rect.width > 80 && rect.height > 28 && rect.height < 90 && rect.minY > 40 && rect.minX > 16
        }

        /// バー自身のレイアウトで測る。SwiftUI の更新やスクロールを待たない。
        private func installChromeProbe(
            on nav: UINavigationController, onFittedPill: @escaping (CGRect) -> Void
        ) {
            let bar = nav.navigationBar
            if chromeProbe?.superview === bar { return }
            chromeProbe?.removeFromSuperview()
            let probe = ChromeLayoutProbe()
            probe.isUserInteractionEnabled = false
            probe.backgroundColor = .clear
            probe.frame = .zero
            probe.onLayout = { [weak self] in
                guard let self, !self.chromeLayoutPending else { return }
                self.chromeLayoutPending = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.chromeLayoutPending = false
                    self.fitWhenReady(in: nav, onFittedPill: onFittedPill)
                }
            }
            bar.addSubview(probe)
            chromeProbe = probe
        }

        /// push の終端でもう一度だけ合わせる。途中のフレームで円がまだ無いときに取りこぼさない。
        private func watchTransition(
            of nav: UINavigationController, onFittedPill: @escaping (CGRect) -> Void
        ) {
            guard !watchedTransition, let coordinator = nav.transitionCoordinator, coordinator.isAnimated else {
                return
            }
            watchedTransition = true
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                guard let self, self.tickerVisible else { return }
                self.chromeSettled = true
                self.pillFrameCommitted = false
                self.fitWhenReady(in: nav, onFittedPill: onFittedPill)
            }
        }

        /// 左右の円が取れたフレームでフェードを始める。取れないあいだは出さない。
        private func fitWhenReady(
            in nav: UINavigationController, onFittedPill: @escaping (CGRect) -> Void
        ) {
            guard !fittingChrome, tickerVisible, !morphing, !model.expanded, model.expansion < 0.02 else { return }
            guard nav.view.window != nil else { return }
            fittingChrome = true
            defer { fittingChrome = false }
            guard navigationChrome(in: nav.navigationBar).isPlausible else { return }
            let created = ensureHost(in: nav, onFittedPill: onFittedPill)
            refitCollapsedPill(in: nav, onFittedPill: onFittedPill)
            if created {
                revealHost(alongside: nav.transitionCoordinator)
            }
        }

        /// 折りたたみ中だけ、戻ると右ボタンの実寸へ枠を合わせ直す。フェードの透明度は変えない。
        /// 一度ボタンのあいだに収めた幅よりは広げない。
        private func refitCollapsedPill(
            in nav: UINavigationController, onFittedPill: @escaping (CGRect) -> Void
        ) {
            guard let container = cardContainer, !morphing, !model.expanded, model.expansion < 0.02 else { return }
            guard !pillFrameCommitted else { return }
            var pill = fittedPill(model.pillRect, bar: nav.navigationBar)
            let previous = container.frame
            guard abs(pill.width - previous.width) > 1
                || abs(pill.height - previous.height) > 1
                || abs(pill.minX - previous.minX) > 1
                || abs(pill.minY - previous.minY) > 1
            else {
                if chromeStable { pillFrameCommitted = previous.width > 1 }
                return
            }
            model.pillRect = pill
            model.visibleWidth = pill.width
            applyNameLock(pillWidth: pill.width)
            UIView.performWithoutAnimation {
                container.transform = .identity
                container.frame = pill
                container.layer.cornerRadius = pill.height / 2
            }
            wrapper?.cardFrame = pill
            titleHider.pill = pill
            pillFrameCommitted = chromeStable
            DispatchQueue.main.async {
                onFittedPill(pill)
            }
        }

        /// 狭い幅で決めた折りと字の大きさは、その後の広い計測で上書きしない。
        private func applyNameLock(pillWidth: CGFloat) {
            if lockedNameWidth > 1, pillWidth + 1 >= lockedNameWidth { return }
            model.nameLock = CompanyNameLock.measure(
                name: model.company.name,
                code: model.company.code,
                pillWidth: pillWidth
            )
            lockedNameWidth = pillWidth
        }

        /// 幅も高さも社名の文字数によらない。戻ると編集ボタンのあいだ、高さはその端末の円ボタン。
        /// 左右の隙間は同じ。長い社名は同じ枠の中で2行。バー自体の高さは使わない。
        private func fittedPill(_ measured: CGRect, bar: UINavigationBar) -> CGRect {
            let chrome = navigationChrome(in: bar)
            chromeStable = chrome.stable || chromeSettled
            let gap = chrome.gap
            guard chrome.isPlausible else { return measured }
            let left = chrome.leadingMaxX + gap
            let right = chrome.trailingMinX - gap
            let width = max(right - left, 1)
            let height = chrome.controlHeight
            return CGRect(x: left, y: chrome.controlMidY - height / 2, width: width, height: height)
        }

        /// 戻るの右端・右ボタンの左端・円の中心を、バー上に見えている円から取る。
        /// ウィンドウ座標で測る。変形を外した着地位置だけだと、円がバーの外に出てピルが出ない。
        private func navigationChrome(in bar: UINavigationBar) -> NavigationChrome {
            bar.layoutIfNeeded()
            let root = bar.nearestNavigationController()?.view ?? bar
            let barInWindow = bar.convert(bar.bounds, to: nil)
            let leftCut = barInWindow.minX + barInWindow.width * 0.32
            let rightCut = barInWindow.maxX - barInWindow.width * 0.32
            var chrome = NavigationChrome()
            var left: [CGRect] = []
            var right: [CGRect] = []
            var trailingClusters: [CGRect] = []
            var circleHeights: [CGFloat] = []
            var circleMidYs: [CGFloat] = []
            var capsuleWidths: [CGFloat] = []
            var capsuleHeights: [CGFloat] = []
            func consider(_ view: UIView) {
                // 遷移中は円の親がまだ透明なことがある。そこで打ち切ると、着地後もピルが出ない。
                view.subviews.forEach(consider)
                if view.isHidden { return }
                let visual = view.convert(view.bounds, to: nil)
                let bounds = view.bounds
                let nearBar = visual.midY >= barInWindow.minY - 12 && visual.midY <= barInWindow.maxY + 12
                let offTrailing = visual.minX >= barInWindow.maxX - 12
                if nearBar || offTrailing {
                    if bounds.height >= 36, bounds.height <= 72, abs(bounds.width - bounds.height) <= 4,
                       visual.midX < leftCut || visual.midX > rightCut || offTrailing
                    {
                        circleHeights.append(bounds.height)
                        if nearBar { circleMidYs.append(visual.midY) }
                    }
                    let onRight = visual.midX > barInWindow.midX || offTrailing
                    if onRight, bounds.height >= 36, bounds.height <= 72 {
                        let ratio = bounds.height > 1 ? bounds.width / bounds.height : 0
                        // 編集と星の組。遷移元の履歴・編集ボタン（円1つ）はここには入らない。
                        if ratio >= 2.0 && ratio <= 2.7 {
                            capsuleWidths.append(bounds.width)
                            capsuleHeights.append(bounds.height)
                        }
                    }
                }
                // バー内の着地位置を優先する。着地位置がバーに無いときは、見えている枠を使う。
                let frame = Self.landingFrame(of: view, in: bar).flatMap { landed in
                    Self.hitsBar(landed, barInWindow: barInWindow) ? landed : nil
                } ?? visual
                guard Self.hitsBar(frame, barInWindow: barInWindow) else { return }
                let h = frame.height
                let w = frame.width
                let inBar = frame.midY >= barInWindow.minY - 6 && frame.midY <= barInWindow.maxY + 6
                let onScreen = frame.maxX > barInWindow.minX + 4 && frame.minX < barInWindow.maxX - 4
                let button = h >= 36 && h <= 72 && w >= 28 && w <= h * 1.35 && w / h >= 0.8
                let cluster = h >= 36 && h <= 72 && w > h * 1.35 && w <= h * 3.2 && frame.midX > rightCut
                if inBar, onScreen, button, frame.midX < leftCut {
                    left.append(frame)
                } else if inBar, onScreen, button, frame.midX > rightCut {
                    right.append(frame)
                } else if inBar, onScreen, cluster {
                    trailingClusters.append(frame)
                }
            }
            consider(root)
            let leftButtons = Self.visibleDiscs(left)
            let rightSettled = Self.visibleDiscs(right)
            let settledDiameter = (leftButtons + rightSettled).map(\.height).min()
            let trailing = Self.trailingPair(right)
            // 組の高さ（ガラスの円）。内側の 36pt 枠の最小値にはしない。
            let diameter = Self.dominantHeight(capsuleHeights)
                ?? Self.dominantHeight(circleHeights)
                ?? settledDiameter
                ?? trailing.map(\.height).min()
            let midY = circleMidYs.isEmpty
                ? barInWindow.midY
                : circleMidYs.reduce(0, +) / CGFloat(circleMidYs.count)
            let trailingCircleInset = Self.edgeInset(
                maxX: rightSettled.map(\.maxX).max(),
                barMaxX: barInWindow.maxX
            )
            if let diameter,
               let width = Self.capsuleWidth(capsuleWidths, heights: capsuleHeights, diameter: diameter)
            {
                let landedInset = Self.landedInset(
                    lead: leftButtons.max(by: { $0.maxX < $1.maxX }),
                    diameter: diameter,
                    barInWindow: barInWindow
                )
                if let inset = Self.contentInset(bar: bar, landed: landedInset ?? trailingCircleInset) {
                    chrome.foundTrailing = true
                    // 余白を実測の円から取れたときだけ確定する。マージンだけの予測は遷移の終わりに直す。
                    chrome.stable = landedInset != nil || trailingCircleInset != nil
                    chrome.trailingMinX = barInWindow.maxX - inset - width
                    chrome.controlHeight = diameter
                    chrome.controlMidY = midY
                }
            }
            // 組の幅がまだ無いときだけ、見えている2円の中心から右端を置く。
            if !chrome.foundTrailing, let diameter, trailing.count >= 2,
               let trail = trailing.min(by: { $0.midX < $1.midX })
            {
                chrome.foundTrailing = true
                chrome.trailingMinX = trail.midX - diameter / 2
                chrome.controlHeight = diameter
                chrome.controlMidY = trail.midY
            }
            if let diameter, let lead = leftButtons.max(by: { $0.maxX < $1.maxX }) {
                let edge = lead.midX + diameter / 2
                let span = edge - barInWindow.minX
                // 滑っている途中の戻る円では確定しない。着地位置は右の円から予測する。
                if span >= diameter * 0.7 && span <= diameter * 2.4 {
                    chrome.foundLeading = true
                    chrome.leadingMaxX = edge
                    chrome.controlMidY = chrome.controlMidY == 0
                        ? lead.midY
                        : (chrome.controlMidY + lead.midY) / 2
                }
            }
            // 戻る円がまだ着地していないとき、右端と同じ余白で着地位置を置く。
            if !chrome.foundLeading, chrome.foundTrailing,
               let diameter = diameter ?? (chrome.controlHeight > 1 ? chrome.controlHeight : nil)
            {
                let buttonHeight = chrome.controlHeight > 1 ? chrome.controlHeight : diameter
                let landed = Self.landedInset(
                    lead: leftButtons.max(by: { $0.maxX < $1.maxX }),
                    diameter: buttonHeight,
                    barInWindow: barInWindow
                )
                if let inset = Self.contentInset(bar: bar, landed: landed ?? trailingCircleInset) {
                    chrome.foundLeading = true
                    chrome.leadingMaxX = barInWindow.minX + inset + buttonHeight
                    if chrome.controlMidY == 0 {
                        chrome.controlMidY = midY
                    }
                }
            }
            if !chrome.foundTrailing, chrome.foundLeading,
               let cluster = trailingClusters.min(by: { $0.minX < $1.minX }),
               abs(cluster.midY - chrome.controlMidY) < 8,
               cluster.width >= chrome.controlHeight * 1.6
            {
                chrome.foundTrailing = true
                chrome.trailingMinX = cluster.minX
            }
            let height = chrome.controlHeight
            let leadingSpan = chrome.leadingMaxX - barInWindow.minX
            let trailingSpan = barInWindow.maxX - chrome.trailingMinX
            chrome.isPlausible = chrome.foundLeading && chrome.foundTrailing && height >= 28
                && leadingSpan >= height * 0.7 && leadingSpan <= height * 2.4
                && trailingSpan >= height * 1.5 && trailingSpan <= height * 3.6
            if !chrome.isPlausible {
                chrome.foundLeading = false
                chrome.foundTrailing = false
                chrome.stable = false
            }
            return chrome
        }

        /// いちばん多い高さ。同数なら大きいほう（ガラスの円。内側の小さい枠は使わない）。
        private static func dominantHeight(_ heights: [CGFloat]) -> CGFloat? {
            var buckets: [Int: Int] = [:]
            for height in heights {
                let key = Int(height.rounded())
                buckets[key, default: 0] += 1
            }
            guard let best = buckets.max(by: { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key < rhs.key
            }) else { return nil }
            return CGFloat(best.key)
        }

        /// 編集と星の組。円の直径に対して、2つの円とあいだの隙間に収まる幅だけ。
        private static func capsuleWidth(
            _ widths: [CGFloat], heights: [CGFloat], diameter: CGFloat
        ) -> CGFloat? {
            let fitting = zip(widths, heights).compactMap { width, height -> CGFloat? in
                guard abs(height - diameter) <= 2 || height <= diameter + 2 else { return nil }
                guard width >= diameter * 2.0, width <= diameter * 2.7 else { return nil }
                return width
            }
            return fitting.max()
        }

        /// 着地した戻る円の、画面端からの余白。滑っている円は nil。
        private static func landedInset(
            lead: CGRect?, diameter: CGFloat, barInWindow: CGRect
        ) -> CGFloat? {
            guard let lead else { return nil }
            let edge = lead.midX + diameter / 2
            let span = edge - barInWindow.minX
            guard span >= diameter * 0.7, span <= diameter * 2.4 else { return nil }
            let inset = span - diameter
            guard inset >= 8, inset <= 32 else { return nil }
            return inset
        }

        /// 右端の円から画面端までの余白。内枠で左に寄った maxX は使わない。
        private static func edgeInset(maxX: CGFloat?, barMaxX: CGFloat) -> CGFloat? {
            guard let maxX else { return nil }
            let inset = barMaxX - maxX
            guard inset >= 8, inset <= 32 else { return nil }
            return inset
        }

        /// 実測の余白が無いとき、バー自身のレイアウト余白。
        private static func contentInset(bar: UINavigationBar, landed: CGFloat?) -> CGFloat? {
            if let landed { return landed }
            let values = [
                bar.directionalLayoutMargins.trailing,
                bar.directionalLayoutMargins.leading,
                bar.layoutMargins.right,
                bar.layoutMargins.left,
            ]
            return values.first { $0 >= 8 && $0 <= 32 }
        }

        /// ほぼ正方形のボタン枠。高さでは絞らない。
        private static func squareDiscs(_ frames: [CGRect]) -> [CGRect] {
            frames.filter { frame in
                frame.height >= 36 && abs(frame.width - frame.height) <= 4
            }
        }

        /// 同じ高さの円が2つ以上ある組。1つだけの遷移元ボタンは右端に使わない。
        /// 複数あれば、見える円（いちばん低い組）を使う。
        private static func trailingPair(_ frames: [CGRect]) -> [CGRect] {
            let circles = squareDiscs(frames).sorted { $0.height < $1.height }
            var groups: [[CGRect]] = []
            for frame in circles {
                if let index = groups.indices.last,
                   let height = groups[index].first?.height,
                   abs(frame.height - height) <= 1
                {
                    groups[index].append(frame)
                } else {
                    groups.append([frame])
                }
            }
            let pairs = groups.map { separated($0) }.filter { $0.count >= 2 }
            return pairs.min { ($0.map(\.height).min() ?? 0) < ($1.map(\.height).min() ?? 0) } ?? []
        }

        /// バーより下のスライド変形を外した、ウィンドウ上の着地枠。バーの外に出る計算は使わない。
        private static func landingFrame(of view: UIView, in bar: UINavigationBar) -> CGRect? {
            guard view.isDescendant(of: bar) else { return nil }
            var origin = CGPoint(x: view.bounds.minX, y: view.bounds.minY)
            var node: UIView = view
            while node !== bar {
                guard let parent = node.superview else { return nil }
                origin.x = node.center.x + (origin.x - node.bounds.midX)
                origin.y = node.center.y + (origin.y - node.bounds.midY)
                node = parent
            }
            let rect = CGRect(origin: origin, size: view.bounds.size)
            return bar.convert(rect, to: nil)
        }

        private static func hitsBar(_ frame: CGRect, barInWindow: CGRect) -> Bool {
            frame.maxY >= barInWindow.minY - 8 && frame.minY <= barInWindow.maxY + 8
        }

        /// 重なっている同じ円は1つにする。中心が離れていれば、枠が重なっていても別の円。
        private static func separated(_ frames: [CGRect]) -> [CGRect] {
            var kept: [CGRect] = []
            for frame in frames.sorted(by: { $0.midX < $1.midX }) {
                if let last = kept.last {
                    let limit = max(frame.height, last.height) * 0.45
                    if abs(frame.midX - last.midX) < limit { continue }
                }
                kept.append(frame)
            }
            return kept
        }

        /// 円の中の印や、円より高い戻る枠ではなく、見える円だけを残す。
        private static func visibleDiscs(_ frames: [CGRect]) -> [CGRect] {
            let circles = frames.filter { frame in
                frame.height >= 36 && abs(frame.width - frame.height) <= 4
            }
            guard let minHeight = circles.map(\.height).min() else { return [] }
            return circles.filter { $0.height <= minHeight + 1 }
        }

        /// SwiftUI のボタン内では UIKit アニメーションが止まっている。
        /// そのまま `UIView.animate` すると、閉じる矩形が終端へ飛ぶ。
        private func animateExpanded(_ expanded: Bool) {
            let fire = { [weak self] in
                guard let self else { return }
                let enabled = UIView.areAnimationsEnabled
                UIView.setAnimationsEnabled(true)
                self.animate(expanded: expanded)
                UIView.setAnimationsEnabled(enabled)
            }
            if UIView.areAnimationsEnabled {
                fire()
            } else {
                DispatchQueue.main.async(execute: fire)
            }
        }

        private func animate(expanded: Bool) {
            guard let container = cardContainer, let window = container.window else {
                morphing = false
                model.freezesGlyphs = false
                return
            }
            let pill = model.pillRect
            guard pill.width > 1, pill.height > 1 else {
                morphing = false
                model.freezesGlyphs = false
                return
            }
            let endWidth = window.bounds.width - 16
            let endHeight = max(measuredHeight(width: endWidth), pill.height)
            let end = expanded
                ? CGRect(x: 8, y: pill.minY, width: endWidth, height: endHeight)
                : pill
            let radius = expanded ? min(end.height / 2, Theme.cardCornerRadius) : pill.height / 2
            // 中身は広がったサイズのまま置き、枠だけをピルへ戻す。
            // 枠に合わせて組み直すと、閉じ始めに本文が消えて矩形だけが縮む。
            if let hostView = host?.view {
                UIView.performWithoutAnimation {
                    hostView.frame = CGRect(x: 0, y: 0, width: endWidth, height: endHeight)
                }
            }
            openTap?.isEnabled = !expanded
            host?.view.isUserInteractionEnabled = expanded
            morphing = true
            updateModalAccessibility()
            // 閉じる終端はピルなので、追跡の分母は常に開いた高さにする。
            startMorphTracking(pillHeight: pill.height, cardWidth: endWidth, cardHeight: endHeight)
            UIView.animate(
                withDuration: 0.42,
                delay: 0,
                usingSpringWithDamping: 0.86,
                initialSpringVelocity: 0.25,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                container.frame = end
                container.layer.cornerRadius = radius
            } completion: { _ in
                guard self.model.expanded == expanded else { return }
                self.stopMorphTracking()
                // 途中で別のアニメーションに割り込まれても、見た目は終端の枠に揃える。
                // 中間幅のまま字を固定解除すると、社名がアイコンだけに欠ける。
                self.model.expansion = expanded ? 1 : 0
                self.model.visibleWidth = end.width
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    self.model.freezesGlyphs = false
                }
                UIView.performWithoutAnimation {
                    container.frame = end
                    container.layer.cornerRadius = radius
                    self.host?.view.frame = CGRect(origin: .zero, size: end.size)
                }
                self.wrapper?.cardFrame = end
                self.openTap?.isEnabled = !expanded
                self.updateModalAccessibility()
                if expanded {
                    self.model.onExpanded(true)
                    self.growIfNeeded()
                } else {
                    self.model.coversScreen = false
                    self.model.onCoversScreen(false)
                    self.model.onExpanded(false)
                }
                self.morphing = false
            }
        }

        private func startMorphTracking(pillHeight: CGFloat, cardWidth: CGFloat, cardHeight: CGFloat) {
            trackPillHeight = pillHeight
            trackCardWidth = cardWidth
            trackCardHeight = cardHeight
            morphLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(trackMorph))
            link.add(to: .main, forMode: .common)
            morphLink = link
        }

        private func stopMorphTracking() {
            morphLink?.invalidate()
            morphLink = nil
        }

        /// 表示中の枠の高さに、上余白と下段の出現を合わせる。モデルの矩形は終端へ先に飛ぶ。
        @objc private func trackMorph() {
            guard let container = cardContainer else { return }
            let frame = container.layer.presentation()?.frame ?? container.frame
            wrapper?.cardFrame = frame
            if let hostView = host?.view, trackCardWidth > 1, trackCardHeight > 1 {
                let size = CGSize(width: trackCardWidth, height: trackCardHeight)
                if abs(hostView.frame.width - size.width) > 0.5 || abs(hostView.frame.height - size.height) > 0.5 {
                    UIView.performWithoutAnimation {
                        hostView.frame = CGRect(origin: .zero, size: size)
                    }
                }
            }
            let span = trackCardHeight - trackPillHeight
            let expansion = span > 1
                ? min(1, max(0, (frame.height - trackPillHeight) / span))
                : (model.expanded ? 1 : 0)
            if abs(model.expansion - expansion) > 0.004 {
                model.expansion = expansion
            }
            if model.cardWidth > 1, abs(model.visibleWidth - frame.width) > 0.5 {
                model.visibleWidth = frame.width
            }
            // 枠がピル幅に着いた時点で…を出す。完了後に組み直すと、見切れてから…になる。
            if morphing, !model.expanded, model.freezesGlyphs, model.pillRect.width > 1,
               frame.width <= model.pillRect.width + 4
            {
                model.freezesGlyphs = false
            }
            updateModalAccessibility()
        }

        /// Overview が後から来たら、開いているカードの高さだけ足す。
        private func growIfNeeded() {
            guard model.expanded, let container = cardContainer, let window = container.window else { return }
            let height = max(measuredHeight(width: window.bounds.width - 16), model.pillRect.height)
            guard abs(container.frame.height - height) > 1 else { return }
            host?.view.frame.size.height = height
            UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                container.frame.size.height = height
                container.layer.cornerRadius = min(height / 2, Theme.cardCornerRadius)
            }
        }

        private func measuredHeight(width: CGFloat) -> CGFloat {
            let probe = UIHostingController(
                rootView: CompanyMorphStack(model: model, expansion: 1)
                    .frame(width: width, alignment: .topLeading)
            )
            probe.safeAreaRegions = []
            return probe.sizeThatFits(in: CGSize(width: width, height: 4000)).height
        }

        private func backgroundTapped(_ gesture: UITapGestureRecognizer) {
            guard model.expanded, let container = cardContainer, let wrapper else { return }
            let point = gesture.location(in: wrapper)
            if !container.frame.contains(point) {
                model.setExpanded(false)
            }
        }

        func removeHost() {
            morphing = false
            revealed = false
            lockedNameWidth = 0
            watchedTransition = false
            chromeLayoutPending = false
            revealAnimating = false
            pillFrameCommitted = false
            chromeSettled = false
            chromeStable = false
            chromeProbe?.removeFromSuperview()
            chromeProbe = nil
            model.freezesGlyphs = false
            stopMorphTracking()
            titleHider.stop()
            host?.willMove(toParent: nil)
            wrapper?.removeFromSuperview()
            host?.removeFromParent()
            host = nil
            wrapper = nil
            cardContainer = nil
        }

        /// 遷移の残り時間でフェードする。0.20秒で先に終わると、戻る・編集よりピルだけ濃くなる。
        /// コーディネータの alongside には乗せない。相乗りすると終端の不透明へ飛ぶ。
        private func revealHost(alongside coordinator: UIViewControllerTransitionCoordinator? = nil) {
            concealGeneration += 1
            guard let wrapper, let container = cardContainer else { return }
            let opacity = CGFloat(wrapper.layer.presentation()?.opacity ?? Float(wrapper.alpha))
            if revealed, opacity > 0.99, container.transform == .identity { return }
            revealed = true
            let generation = concealGeneration
            let resting = container.frame
            let duration = Self.showDuration(matching: coordinator)
            UIView.performWithoutAnimation {
                wrapper.alpha = 0
                container.transform = .identity
                container.frame = resting
            }
            revealAnimating = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.concealGeneration == generation, self.revealed,
                      let wrapper = self.wrapper else { return }
                let enabled = UIView.areAnimationsEnabled
                UIView.setAnimationsEnabled(true)
                UIView.animate(
                    withDuration: duration,
                    delay: 0,
                    options: [.curveEaseInOut, .allowUserInteraction]
                ) {
                    wrapper.alpha = 1
                } completion: { [weak self] _ in
                    guard let self, self.concealGeneration == generation else { return }
                    self.revealAnimating = false
                }
                UIView.setAnimationsEnabled(enabled)
            }
        }

        /// push の残り時間。標準の戻る・編集ボタンが不透明になるのと揃える。
        private static func showDuration(matching coordinator: UIViewControllerTransitionCoordinator?) -> TimeInterval {
            guard let coordinator, coordinator.isAnimated, !coordinator.isCancelled else {
                return CompanyPillReveal.showDuration
            }
            let remaining = coordinator.transitionDuration * (1 - coordinator.percentComplete)
            return max(remaining, 0.05)
        }

        /// 戻る・タブ・別画面へ行くときはフェードアウト。ナビのタイトルとしてはスライドさせない。
        /// 非インタラクティブな pop は遷移全体より短く消し、切り替わり時にはほぼ消えている。
        private func concealHost(
            alongside transition: UIViewControllerTransitionCoordinator?,
            setHandedOff: @escaping (Bool) -> Void
        ) {
            tickerVisible = false
            didDisappear = true
            model.expanded = false
            model.onExpanded(false)
            concealGeneration += 1
            let generation = concealGeneration
            revealed = false
            let animations = { [weak self] in
                self?.wrapper?.alpha = 0
            }
            let finish = { [weak self] in
                guard let self, self.concealGeneration == generation else { return }
                self.removeHost()
                setHandedOff(false)
                self.handoffScheduled = false
            }
            let cancelled = { [weak self] in
                guard let self, self.concealGeneration == generation else { return }
                self.tickerVisible = true
                self.didDisappear = false
                self.revealHost(alongside: transition)
            }
            guard wrapper != nil else {
                finish()
                return
            }
            if let transition, transition.isAnimated, transition.initiallyInteractive {
                transition.animate(alongsideTransition: { _ in
                    animations()
                }, completion: { context in
                    if context.isCancelled {
                        cancelled()
                    } else {
                        finish()
                    }
                })
            } else {
                UIView.animate(
                    withDuration: CompanyPillReveal.hideDuration,
                    delay: 0,
                    options: [.curveEaseIn, .beginFromCurrentState]
                ) {
                    animations()
                } completion: { _ in
                    if transition?.isCancelled == true {
                        cancelled()
                    } else {
                        finish()
                    }
                }
            }
        }
    }
}

/// バーが描き直しても、銘柄のタイトル用ガラスだけを毎フレーム隠す。
/// ナビのタイトルとして出すと横スライドするので、見た目は窓上のピルだけにする。
/// SwiftUI の opacity ではガラスの実体が残る。戻る・右上はサイズ推測で消さない。
private final class ToolbarTitleHider: NSObject {
    weak var bar: UINavigationBar?
    /// 銘柄面の navigation item。topItem だと pop 中に元画面のタイトルまで消える。
    weak var item: UINavigationItem?
    var pill: CGRect = .zero
    private var link: CADisplayLink?
    private var hidden: [WeakView] = []

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        tick()
    }

    func stop() {
        link?.invalidate()
        link = nil
        for item in hidden {
            item.view?.alpha = 1
        }
        hidden.removeAll()
    }

    @objc private func tick() {
        guard let bar else { return }
        var next: [WeakView] = []
        if let titleView = item?.titleView {
            titleView.alpha = 0
            next.append(WeakView(titleView))
        }
        guard pill.width > 1 else {
            hidden = next
            return
        }
        let target = bar.convert(pill, from: nil)
        func walk(_ view: UIView) {
            let frame = view.convert(view.bounds, to: bar)
            let matches = abs(frame.midX - target.midX) < 36
                && abs(frame.width - target.width) < 48
                && frame.height > 20
                && frame.height < 80
                && frame.width > 60
            if matches, view !== bar {
                view.alpha = 0
                next.append(WeakView(view))
            }
            view.subviews.forEach(walk)
        }
        walk(bar)
        hidden = next
    }
}

private struct WeakView {
    weak var view: UIView?
    init(_ view: UIView) { self.view = view }
}

private final class GlassTapCatcher: NSObject {
    var onOpen: (() -> Void)?
    var onBackground: ((UITapGestureRecognizer) -> Void)?

    @objc func openTapped() {
        onOpen?()
    }

    @objc func backgroundTapped(_ gesture: UITapGestureRecognizer) {
        onBackground?(gesture)
    }
}

/// 中身は広がったカードの大きさのまま固定し、このビューの矩形だけをピルへ縮める。
private final class MorphClipView: UIView {}

/// ピル矩形の外のタップは下のバーへ通す。広がっているあいだは全面で受ける。
private final class GlassPassThroughView: UIView {
    var hitEverywhere = false
    /// ラッパー座標でのカード矩形。折りたたみ中はここだけタップを受ける。
    var cardFrame: CGRect = .zero

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if hitEverywhere { return bounds.contains(point) }
        return cardFrame.contains(point)
    }
}

/// 銘柄面が消える直前に、窓上のガラスをフェードアウトして外す。
private final class GlassDisappearHook: UIViewController {
    var onWillDisappear: ((UIViewControllerTransitionCoordinator?) -> Void)?
    var onWillAppear: ((UIViewControllerTransitionCoordinator?) -> Void)?

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onWillDisappear?(transitionCoordinator)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        onWillAppear?(transitionCoordinator)
    }
}

@MainActor
@Observable
private final class CompanyGlassModel {
    var expanded = false
    /// 0 がピル、1 がカード。表示中の枠の高さから毎フレーム更新する。
    var expansion: CGFloat = 0
    /// ガラスの中身を組む幅。枠のアニメーションでは変えない。
    var cardWidth: CGFloat = 0
    /// いま見えている枠の幅。閉じるボタンの位置だけに使う。
    var visibleWidth: CGFloat = 0
    /// 開閉中は社名の字間を組み直さない。はみ出しは枠が隠す。
    var freezesGlyphs = false
    /// ピル幅で決めた社名の行。広がっても行数と1行目は変えない。
    var nameLock: CompanyNameLock = .automatic
    /// 広がっているあいだ（収縮アニメーション中を含む）全面のタップを取る。
    var coversScreen = false
    var pillRect: CGRect = .zero
    var company = CompanyRef(code: "", name: "", sector: "")
    var overview: String?
    var onExpanded: (Bool) -> Void = { _ in }
    var onCoversScreen: (Bool) -> Void = { _ in }
    var onToggle: (Bool) -> Void = { _ in }
    var onOverview: () -> Void = {}

    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        // 1行目の字間は先に固定する。閉じ終わりの「…」はアニメーションさせない。
        freezesGlyphs = true
        expanded = value
        if value {
            coversScreen = true
            onCoversScreen(true)
        }
        onToggle(value)
        if value {
            // 開いた直後からタイトル位置のボタンを読み上げ対象から外す。
            onExpanded(true)
        }
    }

    func setOverview(_ text: String?) {
        guard overview != text else { return }
        overview = text
        onOverview()
    }
}

/// ピルと同じ頭を持つ一つのガラス。枠が伸び縮みしても、中身の幅はカードのまま。
private struct CompanyGlassMorph: View {
    var model: CompanyGlassModel

    var body: some View {
        let pillRadius = model.pillRect.height / 2
        let radius = min(
            Theme.cardCornerRadius,
            pillRadius + (Theme.cardCornerRadius - pillRadius) * model.expansion
        )
        // 開閉中はカード幅のまま字を組む。閉じ切ったらピル幅に戻す。
        // カード幅のまま小さい枠に置くと中央合わせになり、社名が右へ欠ける。
        let wide = model.freezesGlyphs || model.expanded
        let width = wide
            ? (model.cardWidth > 1 ? model.cardWidth : nil)
            : (model.pillRect.width > 1 ? model.pillRect.width : nil)
        // 閉じているあいだも下段は高さを持つ。ガラスの中央ではなく上端に社名を置く。
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                CompanyMorphStack(model: model, expansion: model.expansion)
                    .frame(width: width, alignment: .topLeading)
            }
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .task(id: model.company.code) { await loadOverview() }
    }

    private func loadOverview() async {
        guard !model.company.code.isEmpty else { return }
        if let cached = await APIClient.shared.cachedOverview(code: model.company.code) {
            let text = cached.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            model.setOverview(text.isEmpty ? nil : text)
        }
        do {
            let loaded = try await APIClient.shared.overview(code: model.company.code)
            let text = loaded.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            model.setOverview(text.isEmpty ? nil : text)
        } catch APIClientError.http(let status, _) where status == 404 {
            model.setOverview(nil)
        } catch {
            // 通信失敗時は最後の成功応答（キャッシュ）を出したままにする。
        }
    }
}

/// 高さ計測と表示で同じ並び。頭は社名ピルそのもの。
private struct CompanyMorphStack: View {
    var model: CompanyGlassModel
    /// 1 のときカード。計測は開いた高さで行う。
    var expansion: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                // 外側半径 − アイコン半径。ピル自身の上余白を引いた分だけ、開いたとき下げる。
                Color.clear
                    .frame(height: CompanyCardInset.extraTop * expansion)
                    .accessibilityHidden(true)
                CompanyPillLabel(
                    company: model.company,
                    trailingReserve: showsWideName ? 32 + 8 : 0,
                    nameLock: model.nameLock,
                    freezeGlyphs: model.freezesGlyphs,
                    fittingHeight: showsWideName ? 0 : model.pillRect.height
                )
                .frame(
                    width: showsWideName ? nil : collapsedNameWidth,
                    height: showsWideName ? nil : collapsedNameHeight,
                    alignment: .leading
                )
                    .overlay(alignment: .trailing) {
                        Button {
                            model.setExpanded(false)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 32, height: 32)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, Theme.headerPillHorizontalPadding)
                        .opacity(expansion)
                        .offset(x: showsWideName ? model.visibleWidth - model.cardWidth : 0)
                        .accessibilityLabel("閉じる")
                        .accessibilityHidden(!model.expanded)
                    }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, Theme.headerPillHorizontalPadding)
                .opacity(expansion)
                .accessibilityHidden(!model.expanded)
            if let overview = model.overview {
                FillWidth {
                    JustifiedOverviewText(text: overview)
                }
                .padding(.horizontal, Theme.headerPillHorizontalPadding)
                .opacity(expansion)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(overview)
                .accessibilityHidden(!model.expanded)
            }
        }
        .padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityHidden(!model.expanded && model.expansion < 0.02)
    }

    private var subtitle: String {
        model.company.sector.isEmpty ? model.company.code : "\(model.company.code) · \(model.company.sector)"
    }

    /// 開閉中はカード幅のまま字を置く。枠だけが伸び縮みする。
    private var showsWideName: Bool {
        model.freezesGlyphs || model.expanded
    }

    private var collapsedNameWidth: CGFloat? {
        model.pillRect.width > 1 ? model.pillRect.width : nil
    }

    private var collapsedNameHeight: CGFloat? {
        model.pillRect.height > 1 ? model.pillRect.height : nil
    }
}

/// カード外側の角と、アイコンの角を同心にする余白。
private enum CompanyCardInset {
    /// `CompanyIconView` と同じ。サイズの 0.22、下限 6。
    static var iconCornerRadius: CGFloat {
        max(6, Theme.headerIconSize * 0.22)
    }

    /// 外側 R = 内側 R + padding。アイコン上端からガラス上端までの距離。
    static var top: CGFloat {
        max(0, Theme.cardCornerRadius - iconCornerRadius)
    }

    /// ピルが既に持つ上余白を除いた、開いたカードだけの追加分。
    static var extraTop: CGFloat {
        max(0, top - Theme.headerPillVerticalPadding)
    }
}

/// ピル幅で決めた社名。2行のときは1行目を固定し、2行目の…だけ幅で足す。
private enum CompanyNameLock: Equatable {
    case automatic
    /// Headline +2pt の1行。
    case singleLine
    /// 15pt の1行。大きな字ではピル幅に入らない。
    case compactLine
    case twoLine(first: String, rest: String)

    static func measure(name: String, code: String, pillWidth: CGFloat) -> CompanyNameLock {
        let display = Format.displayName(name, fallback: code)
        let textWidth = pillWidth
            - Theme.headerPillHorizontalPadding * 2
            - Theme.headerIconSize
            - 8
        guard textWidth > 8, !display.isEmpty else { return .singleLine }
        let headline = UIFont.preferredFont(forTextStyle: .headline).pointSize + 2
        let large = UIFont.systemFont(ofSize: headline, weight: .bold)
        let largeWidth = (display as NSString).size(withAttributes: [.font: large]).width
        if largeWidth <= textWidth { return .singleLine }
        let compact = UIFont.systemFont(ofSize: 15, weight: .semibold)
        let compactWidth = (display as NSString).size(withAttributes: [.font: compact]).width
        if compactWidth <= textWidth { return .compactLine }
        let attributed = NSAttributedString(string: display, attributes: [.font: compact])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let count = CTTypesetterSuggestLineBreak(typesetter, 0, Double(textWidth))
        let index = splitIndex(in: display, utf16Offset: count)
        guard index > display.startIndex, index < display.endIndex else { return .compactLine }
        return .twoLine(first: String(display[..<index]), rest: String(display[index...]))
    }

    /// Core Text の折り位置は UTF-16。𠮷 のようなサロゲートは文字境界で切る。
    private static func splitIndex(in text: String, utf16Offset: Int) -> String.Index {
        let utf16 = text.utf16
        guard !utf16.isEmpty else { return text.endIndex }
        let capped = min(max(utf16Offset, 1), utf16.count)
        let raw = utf16.index(utf16.startIndex, offsetBy: capped)
        if let index = String.Index(raw, within: text), index > text.startIndex {
            return index
        }
        var cursor = raw
        while cursor < utf16.endIndex {
            cursor = utf16.index(after: cursor)
            if let index = String.Index(cursor, within: text), index > text.startIndex {
                return index
            }
        }
        return text.endIndex
    }
}

/// アイコンと社名。ツールバーのピルと、広がるガラスの頭で同じ並びにする。
private struct CompanyPillLabel: View {
    var company: CompanyRef
    /// 開いたカードで、社名が閉じるボタンに重ならないように空ける幅。
    var trailingReserve: CGFloat = 0
    var nameLock: CompanyNameLock = .automatic
    /// 開閉中。字間は動かさず、はみ出しは親の枠が隠す。
    var freezeGlyphs: Bool = false
    /// 閉じたピルの高さ。2行はこの中に収める。0 のときはカード側の行間。
    var fittingHeight: CGFloat = 0

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            CompanyIconView(company, size: Theme.headerIconSize)
            name
        }
        .padding(.leading, Theme.headerPillHorizontalPadding)
        .padding(.trailing, Theme.headerPillHorizontalPadding + trailingReserve)
        .padding(.vertical, Theme.headerPillVerticalPadding)
    }

    private var name: some View {
        let display = Format.displayName(company.name, fallback: company.code)
        return lockedName(display)
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(display)
    }

    @ViewBuilder
    private func lockedName(_ display: String) -> some View {
        switch nameLock {
        case .singleLine:
            Text(display)
                .font(nameFont)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
        case .compactLine:
            Text(display)
                .font(compactNameFont)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
        case .twoLine(let first, let rest):
            VStack(alignment: .leading, spacing: twoLineSpacing) {
                Text(first)
                    .font(compactNameFont)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                Text(rest)
                    .font(compactNameFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .automatic:
            ViewThatFits(in: .horizontal) {
                Text(display)
                    .font(nameFont)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                Text(display)
                    .font(compactNameFont)
                    .lineLimit(2)
                    .lineSpacing(-2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 1行に収まるときの社名。
    private var nameFont: Font {
        let size = UIFont.preferredFont(forTextStyle: .headline).pointSize + 2
        return .system(size: size, weight: .bold)
    }

    /// 2行のときの社名。ステータスバーの時計と同じくらいの大きさ。
    private var compactNameFont: Font {
        .system(size: 15, weight: .semibold)
    }

    /// 円ボタンの高さに収まる行間。カード側は従来の詰めのまま。
    private var twoLineSpacing: CGFloat {
        let line = UIFont.systemFont(ofSize: 15, weight: .semibold).lineHeight
        guard fittingHeight > 1 else { return -2 }
        let inner = fittingHeight - Theme.headerPillVerticalPadding * 2
        return min(-2, inner - line * 2)
    }
}

/// ナビバーを隠しても、概要では端スワイプで戻れるようにする。
/// 分解から左へはカード送りだけにし、戻ると食い違わないようにする。
private struct InteractivePopGestureEnabler: UIViewRepresentable {
    var allowsPop: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.allowsPop = allowsPop
        DispatchQueue.main.async {
            context.coordinator.attach(from: uiView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(allowsPop: allowsPop)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var allowsPop: Bool
        weak var navigationController: UINavigationController?
        private static let edgeWidth: CGFloat = 32

        init(allowsPop: Bool) {
            self.allowsPop = allowsPop
        }

        deinit {
            if navigationController?.interactivePopGestureRecognizer?.delegate === self {
                navigationController?.interactivePopGestureRecognizer?.delegate = nil
            }
        }

        func attach(from view: UIView) {
            guard let navigationController = view.nearestNavigationController() else { return }
            self.navigationController = navigationController
            guard let pop = navigationController.interactivePopGestureRecognizer else { return }
            pop.isEnabled = navigationController.viewControllers.count > 1
            pop.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard allowsPop else { return false }
            guard (navigationController?.viewControllers.count ?? 0) > 1 else { return false }
            let location = gestureRecognizer.location(in: gestureRecognizer.view)
            return location.x <= Self.edgeWidth
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            allowsPop && other is UIPanGestureRecognizer
        }
    }
}

private extension UIView {
    func nearestHorizontalScrollView() -> UIScrollView? {
        var current: UIView? = self
        while let view = current {
            if let found = view.horizontalScrollViewAmongDescendants() {
                return found
            }
            current = view.superview
        }
        return nil
    }

    func horizontalScrollViewAmongDescendants() -> UIScrollView? {
        if let scroll = self as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 {
            return scroll
        }
        for subview in subviews {
            if let found = subview.horizontalScrollViewAmongDescendants() {
                return found
            }
        }
        return nil
    }

    func nearestNavigationController() -> UINavigationController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let navigationController = current as? UINavigationController {
                return navigationController
            }
            if let viewController = current as? UIViewController {
                return viewController.navigationController
            }
            responder = current.next
        }
        return nil
    }

    func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}
