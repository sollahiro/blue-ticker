import SwiftUI
import UIKit

/// 親の提案幅を子に渡し、Overview が広がるようにする。
struct FillWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = proposal.width ?? 0
        return subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/// 表と同じ幅で折り返す。途中の行は行フラグメント内で両端揃え、最終行は左揃え。
/// 字間を後から足さない。高さ計算と描画は同じ TextKit を使う。
struct JustifiedOverviewText: UIViewRepresentable {
    var text: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> JustifiedOverviewLabel {
        JustifiedOverviewLabel()
    }

    func updateUIView(_ view: JustifiedOverviewLabel, context: Context) {
        _ = dynamicTypeSize
        view.setOverview(text)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: JustifiedOverviewLabel, context: Context
    ) -> CGSize? {
        let width = proposal.width ?? 0
        guard width > 0 else { return .zero }
        uiView.setOverview(text)
        return uiView.fittingSize(width: width)
    }
}

final class JustifiedOverviewLabel: UIView {
    private let maxLines = 5
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer()
    private var text = ""

    private var font: UIFont { UIFont.preferredFont(forTextStyle: .footnote) }
    private var color: UIColor { UIColor(Theme.textMuted) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maxLines
        container.lineBreakMode = .byCharWrapping
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setOverview(_ text: String) {
        self.text = text
        storage.setAttributedString(makeAttributed())
        setNeedsDisplay()
    }

    func fittingSize(width: CGFloat) -> CGSize {
        storage.setAttributedString(makeAttributed())
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        container.size = bounds.size
        manager.ensureLayout(for: container)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !text.isEmpty, bounds.width > 0 else { return }
        container.size = bounds.size
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(for: container)
        manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    private func makeAttributed() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .justified
        style.lineBreakMode = .byCharWrapping
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
        )
    }
}
