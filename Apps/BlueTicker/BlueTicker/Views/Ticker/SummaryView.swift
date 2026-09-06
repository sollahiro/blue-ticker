import SwiftUI
import UIKit
import CoreText

struct SummaryView: View {
    var code: String
    @State private var response: FinancialsResponse?
    @State private var errorMessage: String?
    @State private var selectedRow: SummaryRow?
    @State private var overview: String?

    var body: some View {
        Group {
            if let response {
                summaryTable(response)
            } else if let errorMessage {
                TickerStubView(title: "概要", detail: errorMessage)
            } else {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private struct MoneyScales {
        var pl: Format.YenScale?
        var cash: Format.YenScale?
    }

    private func moneyScales(for response: FinancialsResponse) -> MoneyScales {
        let plValues = response.years.flatMap { [
            $0.sales, $0.grossProfit, $0.operatingProfit, $0.netProfit,
        ] }
        let cashValues = response.years.flatMap { [
            $0.netCash, $0.cfo, $0.cfi, Format.freeCashFlow($0),
        ] }
        return MoneyScales(
            pl: Format.commonScale(for: plValues),
            cash: Format.commonScale(for: cashValues)
        )
    }

    private func columnColor(index: Int) -> Color {
        index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.06)
    }

    private func summaryTable(_ response: FinancialsResponse) -> some View {
        let years = Format.chronological(response.years)
        let scales = moneyScales(for: response)
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let overview, !overview.isEmpty {
                    FillWidth {
                        JustifiedOverviewText(text: overview)
                    }
                    .padding(.bottom, 8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(overview)
                }
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        Text("")
                            .frame(minWidth: 88, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                        ForEach(Array(years.enumerated()), id: \.element.id) { index, year in
                            Text(Format.fy(year.fyEnd))
                                .gridHeader()
                                .background(columnColor(index: index))
                        }
                    }
                    ForEach(SummaryRow.allCases) { row in
                        GridRow {
                            Text(row.displayTitle(plUnit: scales.pl?.unit ?? "", cashUnit: scales.cash?.unit ?? ""))
                                .font(.caption.weight(selectedRow == row ? .bold : .semibold))
                                .foregroundStyle(selectedRow == row ? Theme.accent : Theme.text)
                                .frame(minWidth: 88, alignment: .leading)
                                .lineLimit(2)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                            ForEach(Array(years.enumerated()), id: \.element.id) { index, year in
                                Text(row.format(year, plScale: scales.pl, cashScale: scales.cash))
                                    .gridCell(color: row.color(year))
                                    .background(columnColor(index: index))
                            }
                        }
                        .background(selectedRow == row ? Theme.accent.opacity(0.12) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedRow = (selectedRow == row ? nil : row)
                        }
                    }
                }
                if let selectedRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedRow.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.accent)
                        Text(selectedRow.description)
                            .font(.caption)
                            .foregroundStyle(Theme.text)
                    }
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
        .padding(12)
    }

    private func load() async {
        async let financials = APIClient.shared.financials(code: code)
        async let overviewText = loadOverview()
        do {
            response = try await financials
            errorMessage = nil
            overview = await overviewText
        } catch APIClientError.http(let status, let message) where status == 404 {
            errorMessage = message.isEmpty ? "財務データは未集計です" : message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadOverview() async -> String? {
        do {
            let loaded = try await APIClient.shared.overview(code: code)
            let text = loaded.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}

/// 親の提案幅を子に渡し、Overview がカード幅まで広がるようにする。
private struct FillWidth: Layout {
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

/// 表と同じ幅で折り返し、途中の行は文字間隔で両端揃え、最終行は左揃え。
/// 高さ計算と描画は同じ UIFont を使う。
private struct JustifiedOverviewText: UIViewRepresentable {
    var text: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> JustifiedOverviewLabel {
        JustifiedOverviewLabel()
    }

    func updateUIView(_ view: JustifiedOverviewLabel, context: Context) {
        _ = dynamicTypeSize
        view.text = text
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: JustifiedOverviewLabel, context: Context
    ) -> CGSize? {
        let width = proposal.width ?? 0
        guard width > 0 else { return .zero }
        uiView.text = text
        return uiView.fittingSize(width: width)
    }
}

private final class JustifiedOverviewLabel: UIView {
    var text = "" {
        didSet {
            guard oldValue != text else { return }
            setNeedsDisplay()
        }
    }

    private let maxLines = 5
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
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    func fittingSize(width: CGFloat) -> CGSize {
        var fitRange = CFRange()
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            CTFramesetterCreateWithAttributedString(attributedText()),
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width, height: font.lineHeight * CGFloat(maxLines)),
            &fitRange
        )
        return CGSize(width: width, height: ceil(size.height))
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !text.isEmpty, bounds.width > 0 else { return }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        let attributed = attributedText()
        let path = CGPath(rect: bounds, transform: nil)
        let frame = CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(attributed),
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)
        for (index, line) in lines.enumerated() {
            let drawn = index == lines.count - 1
                ? line
                : Self.justifiedLine(line, from: attributed, width: bounds.width, font: font, color: color)
            ctx.textPosition = origins[index]
            CTLineDraw(drawn, ctx)
        }
        ctx.restoreGState()
    }

    private func attributedText() -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
            ]
        )
    }

    private static func justifiedLine(
        _ line: CTLine, from attributed: NSAttributedString, width: CGFloat, font: UIFont, color: UIColor
    ) -> CTLine {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let used = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let slack = width - used
        let range = CTLineGetStringRange(line)
        guard slack > 0.5, range.length > 1 else { return line }
        let nsText = attributed.string as NSString
        let substring = nsText.substring(with: NSRange(location: range.location, length: range.length))
        let kern = slack / CGFloat(range.length - 1)
        let filled = NSMutableAttributedString(
            string: substring,
            attributes: [.font: font, .foregroundColor: color]
        )
        filled.addAttribute(.kern, value: kern, range: NSRange(location: 0, length: filled.length - 1))
        return CTLineCreateWithAttributedString(filled)
    }
}

/// 概要に出す Summary 水準値。中タブは置かない（フロー側へ移す）。
private enum SummaryRow: String, CaseIterable, Identifiable {
    case sales
    case grossProfit
    case grossMargin
    case operatingProfit
    case operatingMargin
    case netProfit
    case netProfitMargin
    case netCash
    case netDe
    case cfo
    case cfi
    case fcf
    case equityRatio
    case currentRatio
    case fixedRatio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sales: "売上高"
        case .grossProfit: "売上総利益"
        case .grossMargin: "粗利率"
        case .operatingProfit: "営業利益"
        case .operatingMargin: "営業利益率"
        case .netProfit: "純利益"
        case .netProfitMargin: "純利益率"
        case .netCash: "正味現金"
        case .netDe: "ネットD/E"
        case .cfo: "営業CF"
        case .cfi: "投資CF"
        case .fcf: "フリーCF"
        case .equityRatio: "自己資本比率"
        case .currentRatio: "流動比率"
        case .fixedRatio: "固定比率"
        }
    }

    private var isPlMoney: Bool {
        [.sales, .grossProfit, .operatingProfit, .netProfit].contains(self)
    }

    private var isCashMoney: Bool {
        [.netCash, .cfo, .cfi, .fcf].contains(self)
    }

    private var isPercent: Bool {
        [.grossMargin, .operatingMargin, .netProfitMargin, .equityRatio, .currentRatio, .fixedRatio].contains(self)
    }

    func displayTitle(plUnit: String, cashUnit: String) -> String {
        if isPlMoney, !plUnit.isEmpty {
            return "\(title)（\(plUnit)）"
        }
        if isCashMoney, !cashUnit.isEmpty {
            return "\(title)（\(cashUnit)）"
        }
        if isPercent {
            return "\(title)（％）"
        }
        if self == .netDe {
            return "\(title)（倍）"
        }
        return title
    }

    var description: String {
        switch self {
        case .sales:
            return "当期の売上高です。前期比で規模の伸び縮みを見ます。業種で桁が違うので他社比較は同業が本筋です。"
        case .grossProfit:
            return "売上高から売上原価を差し引いた粗利益です。原価高や値下げで縮小します。"
        case .grossMargin:
            return "粗利益 ÷ 売上高。原価効率です。製造業はおおむね 20〜40%、小売・商社は低め、ソフトは高めが多いです。急落は価格競争や原価高のサインです。"
        case .operatingProfit:
            return "本業で得た利益です。赤字は本業が回っていないことを示します。一時費用でも赤字になり得ます。"
        case .operatingMargin:
            return "営業利益 ÷ 売上高です。製造業は 5〜10% 前後、小売は数%、IT はより高いことが多いです。0% 近傍や赤字は要注意です。同業比較が本筋です。"
        case .netProfit:
            return "税引き後の最終的な当期純利益です。特別損益でぶれるので、営業利益と切り分けて見ます。"
        case .netProfitMargin:
            return "純利益 ÷ 売上高です。最終的な効率です。赤字は資本を毀損します。業種差が大きいので同業比較が本筋です。"
        case .netCash:
            return "現預金などから有利子負債を差し引いた正味の手元資金です。ネットキャッシュとも呼ばれます。プラスは実質無借金、マイナスは純有利子負債です。成長投資で意図的にマイナスの業種（不動産・通信など）もあります。銀行は解釈が異なります。"
        case .netDe:
            return "純借入金 ÷ 自己資本です。1 倍超は負債が自己資本を上回る目安で要注意とされることが多いです。マイナスはネットキャッシュです。金融・商社・不動産は高くなりやすく、製造業は低めが一般的です。"
        case .cfo:
            return "営業活動で稼いだ現金です。利益が出ていても営業 CF が弱いと回収遅れです。継続赤字は資金繰り懸念です。"
        case .cfi:
            return "投資活動によるキャッシュフローです。通常はマイナス（設備投資）です。大きくマイナスは成長投資、プラスは資産売却が多いです。"
        case .fcf:
            return "営業 CF に投資 CF を加えたフリーキャッシュフローです。株主還元や返済に回せる余力です。成長期は意図的にマイナスもあり、継続的なマイナスは外部資金依存です。"
        case .equityRatio:
            return "自己資本 ÷ 総資産です。高いほど財務が安定します。40% 以上が安定、20% 未満は要注意とされることが多いです。銀行は規制上低め、装置産業も低めになりやすいです。"
        case .currentRatio:
            return "流動資産 ÷ 流動負債です。200% 以上が望ましいとされ、100% 未満は短期の支払い余力不足です。小売は在庫回転が速く、低めでも回ることがあります。"
        case .fixedRatio:
            return "固定資産 ÷ 自己資本です。100% 以下が望ましく、150% 超は要注意とされることが多いです。装置産業は高くなりやすいです。"
        }
    }

    func format(_ year: FinancialsYear, plScale: Format.YenScale?, cashScale: Format.YenScale?) -> String {
        switch self {
        case .sales: return yenString(year.sales, scale: plScale)
        case .grossProfit: return yenString(year.grossProfit, scale: plScale)
        case .grossMargin: return Format.percent(year.grossProfitMargin, includeUnit: false)
        case .operatingProfit: return yenString(year.operatingProfit, scale: plScale)
        case .operatingMargin: return Format.percent(year.operatingMargin, includeUnit: false)
        case .netProfit: return yenString(year.netProfit, scale: plScale)
        case .netProfitMargin: return Format.percent(Format.netProfitMargin(year), includeUnit: false)
        case .netCash: return yenString(year.netCash, scale: cashScale)
        case .netDe: return Format.times(year.netDe, includeUnit: false)
        case .cfo: return yenString(year.cfo, scale: cashScale)
        case .cfi: return yenString(year.cfi, scale: cashScale)
        case .fcf: return yenString(Format.freeCashFlow(year), scale: cashScale)
        case .equityRatio: return Format.percent(Format.equityRatio(year), includeUnit: false)
        case .currentRatio: return Format.percent(Format.currentRatio(year), includeUnit: false)
        case .fixedRatio: return Format.percent(Format.fixedRatio(year), includeUnit: false)
        }
    }

    private func yenString(_ value: Double?, scale: Format.YenScale?) -> String {
        if let scale { return Format.scaledYen(value, scale: scale) }
        return Format.autoYen(value)
    }

    func color(_ year: FinancialsYear) -> Color {
        switch self {
        case .operatingProfit:
            return deficitColor(year.operatingProfit)
        case .netProfit:
            return deficitColor(year.netProfit)
        case .netProfitMargin:
            return deficitColor(Format.netProfitMargin(year))
        case .fcf:
            return deficitColor(Format.freeCashFlow(year))
        case .netDe:
            return netDeColor(year.netDe)
        case .equityRatio:
            return equityRatioColor(Format.equityRatio(year))
        case .currentRatio:
            return currentRatioColor(Format.currentRatio(year))
        case .fixedRatio:
            return fixedRatioColor(Format.fixedRatio(year))
        default:
            return Theme.text
        }
    }

    private func deficitColor(_ value: Double?) -> Color {
        guard let value, value < 0 else { return Theme.text }
        return Theme.negative
    }

    private func netDeColor(_ value: Double?) -> Color {
        guard let value else { return Theme.text }
        if value < 0 { return Theme.ratioGreen }
        if value <= 1.0 { return Theme.positive }
        return Theme.text
    }

    private func equityRatioColor(_ value: Double?) -> Color {
        guard let value else { return Theme.text }
        if value < 20 { return Theme.negative }
        if value <= 70 { return Theme.positive }
        return Theme.ratioGreen
    }

    private func currentRatioColor(_ value: Double?) -> Color {
        guard let value else { return Theme.text }
        if value < 100 { return Theme.negative }
        if value <= 200 { return Theme.positive }
        return Theme.ratioGreen
    }

    private func fixedRatioColor(_ value: Double?) -> Color {
        guard let value else { return Theme.text }
        if value > 150 { return Theme.negative }
        if value <= 100 { return Theme.positive }
        return Theme.ratioGreen
    }
}

private extension Text {
    func gridHeader() -> some View {
        self.font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textMuted)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    func gridCell(color: Color) -> some View {
        self.font(.caption.monospacedDigit())
            .foregroundStyle(color)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
