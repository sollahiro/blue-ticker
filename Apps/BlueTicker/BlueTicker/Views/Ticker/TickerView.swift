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
    /// プッシュ遷移のあと、社名ピルの見た目をバーの外のガラスへ渡したか。
    /// 渡したあとはツールバー側を消し、同じガラスがカードへ広がる。
    @State private var pillHandedOff = false
    /// ツールバー上の社名ピルのウィンドウ座標。広がる始点に使う。
    @State private var pillRect: CGRect = .zero
    @State private var contentWidth: CGFloat = 0

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
                onExpanded: { showsCompanyCard = $0 }
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
                // 見た目を窓上の一つのガラスへ渡したあとは、バーにアイコンも
                // カプセルも残さない。opacity ではガラスが残ってカードに映る。
                if pillHandedOff {
                    Color.clear
                        .frame(width: max(pillRect.width, 1), height: max(pillRect.height, 1))
                        .accessibilityHidden(true)
                } else {
                    Button {
                        showsCompanyCard = true
                    } label: {
                        CompanyPillLabel(company: company)
                            .frame(maxWidth: titlePillMaxWidth)
                    }
                    .buttonStyle(.plain)
                    .glassEffect()
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { pillRect = $0 }
                    .accessibilityLabel(Format.displayName(company.name, fallback: company.code))
                    .accessibilityHint("銘柄コード・業種・Overview を表示します")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("保有情報", systemImage: "square.and.pencil", action: openHoldings)
                Button(
                    isWatched ? "リストから削除" : "リストに追加",
                    systemImage: isWatched ? "star.fill" : "star",
                    action: toggleWatch
                )
                .accessibilityAddTraits(isWatched ? .isSelected : [])
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

    /// 社名ピルの上限。戻る・右上2ボタン・左右余白を引いた分だけにし、
    /// それ以上に広がると編集・星のカプセルの下に潜る。
    private var titlePillMaxWidth: CGFloat {
        let reserved: CGFloat = 180
        guard contentWidth > 0 else { return .infinity }
        return max(contentWidth - reserved, 120)
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
        } else {
            for item in matching {
                modelContext.delete(item)
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

/// 社名ピルと詳細カードを、ナビゲーションバーより上の一つの Liquid Glass として出す。
/// ビュー内オーバーレイはバーの下に合成されるため、バーの親へ載せる。
private struct CompanyGlassPresenter: UIViewRepresentable {
    @Binding var handedOff: Bool
    var expanded: Bool
    var pillRect: CGRect
    var company: CompanyRef
    var onExpanded: (Bool) -> Void

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
        private var cardContainer: UIView?
        private var disappearHook: GlassDisappearHook?
        private var handoffScheduled = false
        private var didDisappear = false

        func update(
            handedOff: Bool,
            setHandedOff: @escaping (Bool) -> Void,
            expanded: Bool,
            pillRect: CGRect,
            company: CompanyRef,
            onExpanded: @escaping (Bool) -> Void,
            anchor: UIView
        ) {
            model.company = company
            model.onExpanded = onExpanded
            // ホストを載せたあとの計測は、バー側を消すときの縮んだ矩形で上書きされる。
            // 開閉の始点は、載せたときのピル矩形のままにする。
            if host == nil, Self.plausiblePill(pillRect) {
                if model.pillRect.width < 1 || abs(pillRect.minY - model.pillRect.minY) < 24 {
                    model.pillRect = pillRect
                }
            }
            guard let nav = anchor.nearestNavigationController(),
                  let ticker = anchor.nearestViewController() else { return }
            installHook(on: ticker, setHandedOff: setHandedOff)
            guard handedOff, pillRect.width > 1, pillRect.height > 1 else {
                if !handedOff, pillRect.width > 1 {
                    scheduleHandoff(from: nav, setHandedOff: setHandedOff)
                }
                return
            }
            let created = ensureHost(in: nav)
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
                self?.animate(expanded: expanded)
            }
            model.onOverview = { [weak self] in
                self?.growIfNeeded()
            }
            // ホストを載せた最初のフレームは必ずピルの形から始める。
            // 挿入と同じトランザクションで広げると中間フレームが出ない。
            if created && expanded {
                model.expanded = false
                DispatchQueue.main.async { [model] in
                    model.setExpanded(true)
                }
            }
        }

        private func scheduleHandoff(from nav: UINavigationController, setHandedOff: @escaping (Bool) -> Void) {
            guard !handoffScheduled else { return }
            handoffScheduled = true
            let fire = { setHandedOff(true) }
            if let transition = nav.transitionCoordinator, transition.isAnimated {
                transition.animate(alongsideTransition: nil) { context in
                    if context.isCancelled {
                        self.handoffScheduled = false
                    } else {
                        fire()
                    }
                }
            } else {
                DispatchQueue.main.async(execute: fire)
            }
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
            hook.onWillDisappear = { [weak self, weak ticker] in
                guard let self, let ticker else { return }
                guard ticker.isMovingFromParent || ticker.isBeingDismissed else { return }
                self.didDisappear = true
                self.model.expanded = false
                self.model.onExpanded(false)
                self.removeHost()
                setHandedOff(false)
                self.handoffScheduled = false
            }
            hook.onWillAppear = { [weak self] in
                guard let self, self.didDisappear else { return }
                self.didDisappear = false
                setHandedOff(true)
            }
            disappearHook = hook
        }

        @discardableResult
        private func ensureHost(in nav: UINavigationController) -> Bool {
            if host != nil { return false }
            guard let window = nav.view.window else { return false }
            let wrapper = GlassPassThroughView()
            wrapper.backgroundColor = .clear
            wrapper.frame = window.bounds
            wrapper.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            let container = UIView()
            container.backgroundColor = .clear
            container.clipsToBounds = true
            container.layer.cornerCurve = .continuous
            container.frame = model.pillRect
            container.layer.cornerRadius = model.pillRect.height / 2
            let host = UIHostingController(rootView: CompanyGlassMorph(model: model))
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.view.frame = container.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
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
            window.addSubview(wrapper)
            self.wrapper = wrapper
            self.cardContainer = container
            self.host = host
            titleHider.bar = nav.navigationBar
            titleHider.pill = model.pillRect
            titleHider.start()
            return true
        }

        private static func plausiblePill(_ rect: CGRect) -> Bool {
            rect.width > 80 && rect.height > 28 && rect.height < 90 && rect.minY > 40 && rect.minX > 16
        }

        private func animate(expanded: Bool) {
            guard let container = cardContainer, let window = container.window else { return }
            let pill = model.pillRect
            guard pill.width > 1, pill.height > 1 else { return }
            let endWidth = window.bounds.width - 16
            let endHeight = max(measuredHeight(width: endWidth), pill.height)
            let end = expanded
                ? CGRect(x: 8, y: pill.minY, width: endWidth, height: endHeight)
                : pill
            let radius = expanded ? min(end.height / 2, Theme.cardCornerRadius) : pill.height / 2
            openTap?.isEnabled = !expanded
            host?.view.isUserInteractionEnabled = expanded
            UIView.animate(
                withDuration: expanded ? 0.42 : 0.26,
                delay: 0,
                usingSpringWithDamping: expanded ? 0.86 : 1,
                initialSpringVelocity: 0.25,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                container.frame = end
                container.layer.cornerRadius = radius
            } completion: { _ in
                guard self.model.expanded == expanded else { return }
                self.wrapper?.cardFrame = container.frame
                self.openTap?.isEnabled = !expanded
                if expanded {
                    self.model.onExpanded(true)
                    self.growIfNeeded()
                } else {
                    self.model.coversScreen = false
                    self.model.onCoversScreen(false)
                    self.model.onExpanded(false)
                }
            }
        }

        /// Overview が後から来たら、開いているカードの高さだけ足す。
        private func growIfNeeded() {
            guard model.expanded, let container = cardContainer, let window = container.window else { return }
            let height = max(measuredHeight(width: window.bounds.width - 16), model.pillRect.height)
            guard abs(container.frame.height - height) > 1 else { return }
            UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                container.frame.size.height = height
                container.layer.cornerRadius = min(height / 2, Theme.cardCornerRadius)
            }
        }

        private func measuredHeight(width: CGFloat) -> CGFloat {
            let probe = UIHostingController(
                rootView: CompanyMorphStack(model: model).frame(width: width, alignment: .topLeading)
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
            titleHider.stop()
            host?.willMove(toParent: nil)
            wrapper?.removeFromSuperview()
            host?.removeFromParent()
            host = nil
            wrapper = nil
            cardContainer = nil
        }
    }
}

/// バーが描き直しても、社名ピルの UIView を毎フレーム隠す。
/// SwiftUI の opacity ではガラスの実体が残る。
private final class ToolbarTitleHider: NSObject {
    weak var bar: UINavigationBar?
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
        guard let bar, pill.width > 1 else { return }
        let target = bar.convert(pill, from: nil)
        var next: [WeakView] = []
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

/// 銘柄面が pop される直前に、バー上のピルを戻して窓上のガラスを外す。
private final class GlassDisappearHook: UIViewController {
    var onWillDisappear: (() -> Void)?
    var onWillAppear: (() -> Void)?

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onWillDisappear?()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        onWillAppear?()
    }
}

@MainActor
@Observable
private final class CompanyGlassModel {
    var expanded = false
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
        expanded = value
        if value {
            coversScreen = true
            onCoversScreen(true)
        }
        onToggle(value)
    }

    func setOverview(_ text: String?) {
        guard overview != text else { return }
        overview = text
        onOverview()
    }
}

/// ピルと同じ頭を持つ一つのガラス。親の UIView が矩形を伸ばすと、下の行が現れる。
private struct CompanyGlassMorph: View {
    var model: CompanyGlassModel

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.height / 2, Theme.cardCornerRadius)
            let reveal = min(1, max(0, (geo.size.height - model.pillRect.height) / 28))
            CompanyMorphStack(model: model, reveal: reveal)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: geo.size.width, alignment: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
        }
        .ignoresSafeArea()
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
    var reveal: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CompanyPillLabel(company: model.company)
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
                    .opacity(reveal)
                    .accessibilityLabel("閉じる")
                }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, Theme.headerPillHorizontalPadding)
                .opacity(reveal)
            if let overview = model.overview {
                FillWidth {
                    JustifiedOverviewText(text: overview)
                }
                .padding(.horizontal, Theme.headerPillHorizontalPadding)
                .opacity(reveal)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(overview)
            }
        }
        .padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Format.displayName(model.company.name, fallback: model.company.code))
        .accessibilityHint("銘柄コード・業種・Overview を表示します")
    }

    private var subtitle: String {
        model.company.sector.isEmpty ? model.company.code : "\(model.company.code) · \(model.company.sector)"
    }
}

/// アイコンと社名。ツールバーのピルと、広がるガラスの頭で同じ並びにする。
private struct CompanyPillLabel: View {
    var company: CompanyRef

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            CompanyIconView(company, size: Theme.headerIconSize)
            name
        }
        .padding(.horizontal, Theme.headerPillHorizontalPadding)
        .padding(.vertical, Theme.headerPillVerticalPadding)
    }

    private var name: some View {
        let display = Format.displayName(company.name, fallback: company.code)
        return ViewThatFits(in: .horizontal) {
            Text(display)
                .font(nameFont)
                .lineLimit(1)
            Text(display)
                .font(compactNameFont)
                .lineLimit(2)
                .lineSpacing(-2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 1行に収まるときの社名。
    private var nameFont: Font {
        let size = UIFont.preferredFont(forTextStyle: .headline).pointSize + 2
        return .system(size: size, weight: .bold)
    }

    /// 2行表示のときの社名。ステータスバーの時計と同じくらいの大きさ。
    private var compactNameFont: Font {
        .system(size: 15, weight: .semibold)
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
