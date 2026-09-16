import SwiftData
import SwiftUI
import UIKit

enum TickerPage: Int, CaseIterable, Hashable, Identifiable {
    case summary, breakdown

    var id: TickerPage { self }
}

private enum HoldingsRoute: Hashable {
    case editor
    case accounts
}

struct TickerView: View {
    var company: CompanyRef
    @Environment(\.modelContext) private var modelContext
    @Query private var watched: [WatchedCompany]
    @State private var page: TickerPage = .summary
    @State private var summarySection: SummarySection = .performance
    @State private var breakdownMetric: BreakdownMetric = .businessProfit
    @State private var resolvedSector = ""
    @State private var holdingsRoute: HoldingsRoute?
    @State private var editingItem: WatchedCompany?

    var body: some View {
        VStack(spacing: 0) {
            header
            CompanyOverviewView(code: company.code)
            cards
            pageDots
        }
        .background(Theme.shell.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .background { InteractivePopGestureEnabler(allowsPop: page == .summary) }
        .navigationDestination(item: $holdingsRoute) { route in
            switch route {
            case .editor:
                if let item = editingItem {
                    FundPositionEditView(item: item, onAddAccount: addAccount)
                }
            case .accounts:
                TickerAccountListView(code: company.code, onAddAccount: addAccount)
            }
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

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            CompanyIconView(company, size: Theme.headerSideHeight)
            VStack(alignment: .leading, spacing: Theme.headerChipSpacing) {
                Text(Format.displayName(company.name, fallback: company.code))
                    .font(nameFont)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Theme.headerRowHeight)
                HStack(alignment: .center, spacing: 8) {
                    Text(company.code)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                    if !displaySector.isEmpty {
                        SectorTag(sector: displaySector, selected: true, height: Theme.headerRowHeight)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Theme.headerRowHeight)
            }
            VStack(alignment: .trailing, spacing: Theme.headerChipSpacing) {
                headerChipButton(
                    title: isWatched ? "追加済み" : "リストに追加",
                    style: isWatched ? .outlineAccent : .filledAccent,
                    action: toggleWatch
                )
                headerChipButton(title: "保有情報", style: .paper, action: openHoldings)
            }
            .frame(height: Theme.headerSideHeight)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var nameFont: Font {
        let size = UIFont.preferredFont(forTextStyle: .headline).pointSize + 2
        return .system(size: size, weight: .bold)
    }

    private enum HeaderChipStyle {
        case filledAccent
        case outlineAccent
        case paper
    }

    private func headerChipButton(
        title: String, style: HeaderChipStyle, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(height: Theme.headerRowHeight)
                .background(chipBackground(style))
                .foregroundStyle(chipForeground(style))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(chipStroke(style), lineWidth: style == .outlineAccent ? 1.5 : 0)
                }
        }
        .buttonStyle(.plain)
    }

    private func chipBackground(_ style: HeaderChipStyle) -> Color {
        switch style {
        case .filledAccent: Theme.accent
        case .outlineAccent: Color.clear
        case .paper: Color.white
        }
    }

    private func chipForeground(_ style: HeaderChipStyle) -> Color {
        switch style {
        case .filledAccent: .black
        case .outlineAccent: Theme.accent
        case .paper: .black
        }
    }

    private func chipStroke(_ style: HeaderChipStyle) -> Color {
        style == .outlineAccent ? Theme.accent : Color.clear
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
        let matching = matchingRows
        let accounts = matching.filter { !$0.isBlankHoldingsRow }
        if accounts.count >= 2 {
            holdingsRoute = .accounts
            return
        }
        editingItem = accounts.first ?? matching.first ?? insertWatchRow()
        holdingsRoute = .editor
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
