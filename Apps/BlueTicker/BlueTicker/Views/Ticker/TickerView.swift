import SwiftData
import SwiftUI
import UIKit

enum TickerPage: Int, CaseIterable, Identifiable {
    case summary, breakdown

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .summary: "概要"
        case .breakdown: "分解"
        }
    }
}

struct TickerView: View {
    var company: CompanyRef
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var watched: [WatchedCompany]
    @State private var page: TickerPage = .summary

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                TabView(selection: $page) {
                    SummaryView(code: company.code)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .tag(TickerPage.summary)
                    BreakdownView(code: company.code)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .tag(TickerPage.breakdown)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            pageDots
        }
        .background(Theme.shell.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .background { InteractivePopGestureEnabler() }
        .onAppear { CompanyHistory.record(company) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.text)
                }
                .accessibilityLabel("戻る")
            }
            .withoutSharedBackground()
            ToolbarItem(placement: .principal) {
                BrandMark()
            }
            .withoutSharedBackground()
        }
        .toolbarBackground(Theme.shell, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var isWatched: Bool {
        watched.contains { $0.code == company.code }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            CompanyIconView(company, size: 38)
            VStack(alignment: .leading, spacing: 0) {
                Text(Format.displayName(company.name, fallback: company.code))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(company.code)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if !company.sector.isEmpty {
                    SectorTag(sector: company.sector, compact: true)
                }
                watchButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var watchButton: some View {
        Button(action: toggleWatch) {
            Text(isWatched ? "追加済み" : "リストに追加")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isWatched ? Color.clear : Theme.accent)
                .foregroundStyle(isWatched ? Theme.accent : .black)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.accent, lineWidth: isWatched ? 1.5 : 0)
                }
        }
        .buttonStyle(.plain)
    }

    private var pageDots: some View {
        HStack(spacing: 10) {
            ForEach(TickerPage.allCases) { item in
                let current = page == item
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        page = item
                    }
                } label: {
                    Circle()
                        .fill(current ? Theme.accent : Theme.textMuted.opacity(0.45))
                        .frame(width: current ? 10 : 6, height: current ? 10 : 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .animation(.easeInOut(duration: 0.2), value: page)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func toggleWatch() {
        if let existing = watched.first(where: { $0.code == company.code }) {
            modelContext.delete(existing)
        } else {
            modelContext.insert(
                WatchedCompany(
                    code: company.code,
                    name: company.name,
                    sector: company.sector,
                    iconURL: company.iconURL
                )
            )
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
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
        .padding(16)
    }
}

/// `navigationBarBackButtonHidden` でも端スワイプで戻れるようにする。
private struct InteractivePopGestureEnabler: UIViewRepresentable {
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

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?

        func attach(from view: UIView) {
            guard let navigationController = view.nearestNavigationController() else { return }
            self.navigationController = navigationController
            guard let pop = navigationController.interactivePopGestureRecognizer else { return }
            pop.isEnabled = navigationController.viewControllers.count > 1
            pop.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            other is UIPanGestureRecognizer
        }
    }
}

private extension UIView {
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
