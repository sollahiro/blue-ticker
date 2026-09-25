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
    /// カードの拡大・収縮アニメーション用。true でカードがピルから広がった状態。
    @State private var cardAppeared = false
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            cards
            pageDots
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { contentWidth = $0 }
        .background(Theme.shell.ignoresSafeArea())
        // 詳細カードはウィンドウ直下に載せ、ナビゲーションバーより上に描く。
        // ビュー内オーバーレイは UIKit のバーより必ず下に合成されてかぶせられない。
        .overlay {
            WindowOverlayPresenter(isPresented: showsCompanyCard) {
                windowCard
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            // タイトル領域に置くと、戻ると右上グループの残りをシステムが割り当てる。
            // 右上の幅を固定予約すると機種によって足りず、「…」へ折りたたまれる。
            ToolbarItem(placement: .title) {
                Button {
                    if showsCompanyCard {
                        closeCompanyCard()
                    } else {
                        showsCompanyCard = true
                    }
                } label: {
                    HStack(alignment: .center, spacing: 8) {
                        CompanyIconView(company, size: Theme.headerIconSize)
                        // 1行に収まるときは大きいまま、収まらない社名は小さめ2行に切替。
                        ViewThatFits(in: .horizontal) {
                            Text(Format.displayName(company.name, fallback: company.code))
                                .font(nameFont)
                                .lineLimit(1)
                            Text(Format.displayName(company.name, fallback: company.code))
                                .font(compactNameFont)
                                .lineLimit(2)
                                .lineSpacing(-2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, Theme.headerPillHorizontalPadding)
                    .padding(.vertical, Theme.headerPillVerticalPadding)
                    .frame(maxWidth: titlePillMaxWidth)
                    .glassEffect()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Format.displayName(company.name, fallback: company.code))
                .accessibilityHint("銘柄コード・業種・Overview を表示します")
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
        .background { InteractivePopGestureEnabler(allowsPop: page == .summary) }
        .navigationDestination(isPresented: $showsHoldings) {
            TickerHoldingsView(code: company.code, onAddAccount: addAccount)
        }
        .task { await hydrateSector() }
    }

    /// ウィンドウオーバーレイに載せる詳細カード。上端のオフセットは
    /// `WindowOverlayPresenter` がナビゲーションバーの実フレームから足す。
    private var windowCard: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { closeCompanyCard() }
            CompanyDetailCard(company: displayCompany, onClose: closeCompanyCard)
                .padding(.horizontal, 8)
                // ピルがそのまま上端からカードに広がる見た目。小さく透明な
                // 状態からスプリングで拡大し、閉じるときは逆に収縮させる。
                .scaleEffect(cardAppeared ? 1 : 0.4, anchor: .top)
                .opacity(cardAppeared ? 1 : 0)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(duration: 0.3)) {
                cardAppeared = true
            }
        }
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

    private var nameFont: Font {
        let size = UIFont.preferredFont(forTextStyle: .headline).pointSize + 2
        return .system(size: size, weight: .bold)
    }

    /// 2行表示のときの社名。ステータスバーの時計と同じくらいの大きさ。
    private var compactNameFont: Font {
        .system(size: 15, weight: .semibold)
    }

    /// 社名ピルの上限。戻る・右上2ボタン・左右余白を引いた分だけにし、
    /// それ以上に広がると編集・星のカプセルの下に潜る。
    private var titlePillMaxWidth: CGFloat {
        let reserved: CGFloat = 180
        guard contentWidth > 0 else { return .infinity }
        return max(contentWidth - reserved, 120)
    }

    private func closeCompanyCard() {
        withAnimation(.snappy(duration: 0.18)) {
            cardAppeared = false
        }
        // 収縮アニメーションが終わってからホストビューを外す。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            showsCompanyCard = false
        }
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

/// isPresented のあいだ、子供を画面の UIWindow 直下のホストビューに載せる。
/// ナビゲーションバーより上に描く必要がある浮きカード用。
private struct WindowOverlayPresenter<Content: View>: UIViewRepresentable {
    var isPresented: Bool
    @ViewBuilder var content: Content

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(isPresented: isPresented, content: content, anchor: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        private var host: UIHostingController<AnyView>?
        private var topPad: CGFloat = 0

        deinit {
            host?.view.removeFromSuperview()
        }

        func update(isPresented: Bool, content: Content, anchor: UIView) {
            if isPresented {
                if let host {
                    host.rootView = AnyView(content.padding(.top, topPad).ignoresSafeArea())
                } else if let window = anchor.window {
                    // ナビゲーションバーの実フレームの上端からカードを出し、
                    // 戻る・右上ボタンにかぶせる。safeAreaInsets 系はバーを含む
                    // 値を返すことがあり、下端にずれるため実測する。
                    topPad = (navBarTop(from: anchor, in: window) ?? window.safeAreaInsets.top) + 2
                    let host = UIHostingController(
                        rootView: AnyView(content.padding(.top, topPad).ignoresSafeArea())
                    )
                    host.view.backgroundColor = .clear
                    host.view.frame = window.bounds
                    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    window.addSubview(host.view)
                    self.host = host
                }
            } else if let host {
                host.view.removeFromSuperview()
                self.host = nil
            }
        }

        /// ウィンドウ座標でのナビゲーションバーの上端。
        /// まずアンカーのレスポンダチェーンから表示中のナビゲーションコントローラを
        /// 引く。見つからなければウィンドウ内のバーのうち上端が最も小さいものを使う
        /// （非表示の裏側バーは下端に近い位置を返すことがある）。
        private func navBarTop(from anchor: UIView, in window: UIWindow) -> CGFloat? {
            var responder = anchor.next
            while let next = responder {
                if let vc = next as? UIViewController,
                   let bar = vc.navigationController?.navigationBar {
                    return bar.convert(bar.bounds, to: nil).minY
                }
                responder = next.next
            }
            var tops: [CGFloat] = []
            func collect(_ view: UIView) {
                if let bar = view as? UINavigationBar {
                    if !bar.isHidden && bar.alpha > 0 {
                        tops.append(bar.convert(bar.bounds, to: nil).minY)
                    }
                    return
                }
                view.subviews.forEach(collect)
            }
            collect(window)
            return tops.min()
        }
    }
}

/// 社名ピルを押すと開く詳細カード。コード・業種・Overview をまとめて出す。
private struct CompanyDetailCard: View {
    var company: CompanyRef
    var onClose: () -> Void
    @State private var overview: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                CompanyIconView(company, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.displayName(company.name, fallback: company.code))
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("閉じる")
            }
            if let overview {
                FillWidth {
                    JustifiedOverviewText(text: overview)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(overview)
            }
        }
        .padding(14)
        // Liquid Glass のカード。ガラスのブラー越しにナビバー行が滲むだけで
        // 内容は読めない。社名ピルと同じ素材感に揃える。
        .glassEffect(
            .regular.interactive(),
            in: .rect(cornerRadius: Theme.cardCornerRadius, style: .continuous)
        )
        .task(id: company.code) { await load() }
    }

    private var subtitle: String {
        company.sector.isEmpty ? company.code : "\(company.code) · \(company.sector)"
    }

    private func load() async {
        if let cached = await APIClient.shared.cachedOverview(code: company.code) {
            let text = cached.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            overview = text.isEmpty ? nil : text
        }
        do {
            let loaded = try await APIClient.shared.overview(code: company.code)
            let text = loaded.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            overview = text.isEmpty ? nil : text
        } catch APIClientError.http(let status, _) where status == 404 {
            overview = nil
        } catch {
            // 通信失敗時は最後の成功応答（キャッシュ）を出したままにする。
        }
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
}
