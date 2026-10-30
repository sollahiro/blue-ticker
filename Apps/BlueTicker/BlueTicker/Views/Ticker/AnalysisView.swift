import Charts
import SwiftUI

/// 銘柄の分析結果。業績・収益構造・資本効率・資金配分・労働生産性を縦に並べ、スクロールで見る。
/// 入力は Waterfall（`/waterfall`）。Summary の水準値に前年差を足した上位集合なので 1 本で足りる。
struct AnalysisView: View {
    var code: String
    @State private var response: FinancialsResponse?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let response {
                content(response)
            } else if let errorMessage {
                TickerStubView(title: "分析", detail: errorMessage)
            } else {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private func content(_ response: FinancialsResponse) -> some View {
        let years = Format.chronological(response.years)
        let currency = response.currency ?? Format.latestYear(response.years)?.currency
        return ScrollView {
            VStack(spacing: Theme.cardContentInset) {
                PerformanceSection(years: years, currency: currency)
                BusinessProfitSection(years: years)
                CapitalEfficiencySection(years: years)
                AnalysisCard(title: "資金配分") {
                    AnalysisNote(text: "準備中です。")
                }
                ProductivitySection(years: years, currency: currency)
            }
            .padding(Theme.cardContentInset)
        }
        .scrollIndicators(.hidden)
    }

    private func load() async {
        if let cached = await APIClient.shared.cachedWaterfall(code: code) {
            response = cached
            errorMessage = nil
        }
        do {
            response = try await APIClient.shared.waterfall(code: code)
            errorMessage = nil
        } catch APIClientError.http(let status, let message) where status == 404 {
            response = nil
            errorMessage = message.isEmpty ? "財務データは未集計です" : message
        } catch {
            if response == nil {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 共通

/// 分析の 1 区分。見出しと中身を角丸のカードに載せる。
private struct AnalysisCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bltCardSurface()
    }
}

/// カード内の小見出し。1 枚に複数のグラフを置くとき。
private struct AnalysisSubheading: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.text)
    }
}

private struct AnalysisNote: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum ChartStyle {
    static let height: CGFloat = 220
    static let grid = StrokeStyle(lineWidth: 0.5, dash: [3, 3])
    static let gridColor = Theme.textMuted.opacity(0.35)
    static let primaryBar = Color(white: 0.88)
    static let secondaryBar = Color(white: 0.45)
    static let line = Color(red: 0.30, green: 0.52, blue: 0.95)
}

/// 凡例の印。棒は角丸の四角、線は丸。
private struct LegendItem: Identifiable {
    enum Shape {
        case bar
        case line
    }

    var title: String
    var color: Color
    var shape: Shape
    var detail: String?
    var id: String { title }
}

private struct ChartLegend: View {
    var items: [LegendItem]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(items) { item in
                HStack(spacing: 5) {
                    switch item.shape {
                    case .bar:
                        RoundedRectangle(cornerRadius: 2)
                            .fill(item.color)
                            .frame(width: 10, height: 10)
                    case .line:
                        Circle()
                            .fill(item.color)
                            .frame(width: 9, height: 9)
                    }
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                    if let detail = item.detail {
                        Text(detail)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.text)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// 折れ線の点。欠損年を挟んだら `run` を変え、線を切る。
private struct LinePoint: Identifiable {
    var id: String
    var label: String
    var value: Double
    var run: Int
}

private enum ChartMath {
    static func linePoints(_ years: [FinancialsYear], value: (FinancialsYear) -> Double?) -> [LinePoint] {
        var run = 0
        var points: [LinePoint] = []
        for year in years {
            guard let number = value(year) else {
                run += 1
                continue
            }
            points.append(LinePoint(id: year.id, label: Format.fy(year.fyEnd), value: number, run: run))
        }
        return points
    }

    /// 0 を含む、切りのよい目盛り。
    static func niceTicks(lower: Double, upper: Double, count: Int = 4) -> [Double] {
        let low = min(lower, 0)
        let high = max(upper, 0)
        let span = high - low
        guard span > 0 else { return [0] }
        let raw = span / Double(max(count, 1))
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1.0, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? raw
        let start = floor(low / step) * step
        let end = ceil(high / step) * step
        return stride(from: start, through: end + step / 2, by: step).map { $0 }
    }
}

// MARK: - 業績

/// 売上高と純利益の棒、営業利益率の折れ線。営業利益率は右軸。
private struct PerformanceSection: View {
    var years: [FinancialsYear]
    var currency: String?

    var body: some View {
        AnalysisCard(title: "業績") {
            if years.contains(where: { $0.sales != nil || $0.netProfit != nil }) {
                chart
                ChartLegend(items: [
                    LegendItem(title: "売上高", color: ChartStyle.primaryBar, shape: .bar),
                    LegendItem(title: "純利益", color: ChartStyle.secondaryBar, shape: .bar),
                    LegendItem(title: "営業利益率", color: ChartStyle.line, shape: .line),
                ])
                if let scale {
                    AnalysisNote(text: "左軸は\(scale.unit)、右軸は営業利益率（%）です。")
                }
            } else {
                AnalysisNote(text: "業績は未集計です。")
            }
        }
    }

    private var labels: [String] { years.map { Format.fy($0.fyEnd) } }

    private var scale: Format.YenScale? {
        Format.commonScale(for: years.flatMap { [$0.sales, $0.netProfit] }, currency: currency)
    }

    private var amountRange: (lower: Double, upper: Double) {
        let values = years.flatMap { [$0.sales, $0.netProfit] }.compactMap { $0 }
        return (min(values.min() ?? 0, 0), max(values.max() ?? 0, 0))
    }

    private var marginTicks: [Double] {
        let margins = years.compactMap(\.operatingMargin)
        return ChartMath.niceTicks(lower: margins.min() ?? 0, upper: margins.max() ?? 0)
    }

    /// 営業利益率の目盛りの上端を、金額の上端に重ねる倍率。
    private var marginFactor: Double {
        let top = marginTicks.max() ?? 0
        let upper = amountRange.upper
        guard top > 0, upper > 0 else { return 1 }
        return upper / top
    }

    private var domain: ClosedRange<Double> {
        let factor = marginFactor
        let lower = min(amountRange.lower, (marginTicks.min() ?? 0) * factor)
        let upper = max(amountRange.upper, (marginTicks.max() ?? 0) * factor)
        let pad = (upper - lower) * 0.05
        return (lower - (lower < 0 ? pad : 0))...(upper + pad)
    }

    private var chart: some View {
        let factor = marginFactor
        let margins = ChartMath.linePoints(years) { $0.operatingMargin }
        return Chart {
            ForEach(years) { year in
                let label = Format.fy(year.fyEnd)
                if let sales = year.sales {
                    BarMark(x: .value("年度", label), y: .value("金額", sales), width: .fixed(12))
                        .position(by: .value("系列", "売上高"))
                        .foregroundStyle(ChartStyle.primaryBar)
                        .cornerRadius(3)
                        .accessibilityLabel("\(label) 売上高")
                        .accessibilityValue(Format.autoYen(sales, currency: currency))
                }
                if let net = year.netProfit {
                    BarMark(x: .value("年度", label), y: .value("金額", net), width: .fixed(12))
                        .position(by: .value("系列", "純利益"))
                        .foregroundStyle(net < 0 ? Theme.negative : ChartStyle.secondaryBar)
                        .cornerRadius(3)
                        .accessibilityLabel("\(label) 純利益")
                        .accessibilityValue(Format.autoYen(net, currency: currency))
                }
            }
            ForEach(margins) { point in
                LineMark(
                    x: .value("年度", point.label),
                    y: .value("営業利益率", point.value * factor),
                    series: .value("線", "margin-\(point.run)")
                )
                .foregroundStyle(ChartStyle.line)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                PointMark(x: .value("年度", point.label), y: .value("営業利益率", point.value * factor))
                    .foregroundStyle(ChartStyle.line)
                    .symbolSize(40)
                    .accessibilityLabel("\(point.label) 営業利益率")
                    .accessibilityValue(Format.percent(point.value))
            }
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(Theme.textMuted.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 0.5))
        }
        .chartXScale(domain: labels)
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: ChartStyle.grid)
                    .foregroundStyle(ChartStyle.gridColor)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(scale.map { Format.scaledYen(number, scale: $0) } ?? Format.autoYen(number))
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
            AxisMarks(position: .trailing, values: marginTicks.map { $0 * factor }) { value in
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(Format.percent(number / factor, digits: 0))
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: ChartStyle.height)
    }
}

// MARK: - 収益構造

/// 事業利益の分解。年次バーで年を選び、売上・利益率・販管費の要因を出す。
private struct BusinessProfitSection: View {
    var years: [FinancialsYear]
    @State private var selectedYearID: String?
    @State private var selectedFactor: FactorKind?

    var body: some View {
        AnalysisCard(title: "収益構造") {
            AnalysisSubheading(text: "事業利益の分解")
            if years.contains(where: { $0.businessProfit != nil }) {
                yearBars
            } else {
                AnalysisNote(text: "事業利益は未算出です。")
            }
            if let selectedYear = years.first(where: { $0.id == currentYearID && isYearSelectable($0) }) {
                factorChart(selectedYear, years: years)
            } else {
                AnalysisNote(text: "年を選ぶと売上要因・利益率要因・販管費要因を表示します。")
            }
            AnalysisNote(text: "事業利益は売上総利益 − 販管費です。開示されている営業利益と一致しない場合がございます。")
        }
    }

    /// 未選択なら、前年差がある最新の年。
    private var currentYearID: String? {
        selectedYearID ?? years.last { isYearSelectable($0) }?.id
    }

    private var yearBars: some View {
        let peak = years.compactMap(\.businessProfit).map(abs).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(years) { year in
                let selectable = isYearSelectable(year)
                let selected = selectable && year.id == currentYearID
                let row = HStack(spacing: 8) {
                    Text(Format.fy(year.fyEnd))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 48, alignment: .leading)
                    SignedBar(value: year.businessProfit ?? 0, peak: peak)
                        .frame(height: 18)
                    Text(Format.autoYen(year.businessProfit, currency: year.currency))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.text)
                        .frame(width: 88, alignment: .trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(selected ? Theme.accent.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                if selectable {
                    Button {
                        selectedYearID = year.id
                        selectedFactor = nil
                    } label: {
                        row
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                } else {
                    row
                }
            }
        }
    }

    private func factorChart(_ year: FinancialsYear, years: [FinancialsYear]) -> some View {
        let spec = factorSpec(year)
        let peak = (spec.factors.map { abs($0.value ?? 0) } + [abs(spec.totalValue ?? 0)]).max() ?? 0
        let prior = priorYear(of: year, in: years)
        return VStack(alignment: .leading, spacing: 8) {
            Text(yearOutcomeTitle(year, total: spec.totalValue))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
            ForEach(spec.factors) { factor in
                let selected = selectedFactor == factor.kind
                factorRow(
                    title: factor.kind.title,
                    value: factor.value,
                    peak: peak,
                    format: spec.format,
                    selected: selected,
                    emphasized: false
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedFactor = (selectedFactor == factor.kind ? nil : factor.kind)
                }
            }
            Rectangle()
                .fill(Theme.textMuted.opacity(0.45))
                .frame(height: 1)
                .padding(.vertical, 2)
            factorRow(
                title: spec.totalTitle,
                value: spec.totalValue,
                peak: peak,
                format: spec.format,
                selected: false,
                emphasized: true
            )
            .accessibilityLabel("\(spec.totalTitle) \(spec.format(spec.totalValue))")
            if let selectedFactor, let factor = spec.factors.first(where: { $0.kind == selectedFactor }) {
                let detail = selectedFactor.detail(year: year, prior: prior, contribution: factor.value)
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedFactor.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                    Text(detail.outcome)
                        .font(.caption)
                        .foregroundStyle(outcomeColor(factor.value))
                    if let note = detail.inversionNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }
                    Text(detail.formula)
                        .font(.caption)
                        .foregroundStyle(Theme.text)
                    if let substitution = detail.substitution {
                        Text("= \(substitution)")
                            .font(.caption)
                            .foregroundStyle(Theme.text)
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.top, 8)
    }

    private func factorRow(
        title: String,
        value: Double?,
        peak: Double,
        format: (Double?) -> String,
        selected: Bool,
        emphasized: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(selected || emphasized ? .bold : .regular))
                .foregroundStyle(selected ? Theme.accent : Theme.text)
                .frame(width: 88, alignment: .leading)
            MagnitudeBar(value: value ?? 0, peak: peak)
                .frame(height: 16)
            Text(format(value))
                .font(.caption.monospacedDigit().weight(emphasized ? .semibold : .regular))
                .foregroundStyle(factorColor(value))
                .frame(width: 88, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 2)
        .background(selected ? Theme.accent.opacity(0.12) : Color.clear)
    }

    /// 「26年2月期の事業利益は、前年より増えました」のように前年差の結論だけを見出しにする。
    private func yearOutcomeTitle(_ year: FinancialsYear, total: Double?) -> String {
        let period = Format.fyJapanese(year.fyEnd)
        guard let total else { return "\(period)の事業利益" }
        if total == 0 { return "\(period)の事業利益は、前年とほぼ変わりませんでした" }
        return "\(period)の事業利益は、前年より\(total > 0 ? "増えました" : "減りました")"
    }

    private struct FactorDetail {
        var outcome: String
        var inversionNote: String?
        var formula: String
        var substitution: String?
    }

    private enum FactorKind: String, CaseIterable {
        case salesChange
        case grossMarginChange
        case sgaChange

        var title: String {
            switch self {
            case .salesChange: "売上要因"
            case .grossMarginChange: "利益率要因"
            case .sgaChange: "販管費要因"
            }
        }

        func detail(year: FinancialsYear, prior: FinancialsYear?, contribution: Double?) -> FactorDetail {
            let inverted = isDriverInverted(year: year, prior: prior)
            return FactorDetail(
                outcome: outcome(contribution: contribution, inverted: inverted),
                inversionNote: inverted ? inversionNote : nil,
                formula: formula,
                substitution: substitution(year: year, prior: prior)
            )
        }

        private func outcome(contribution: Double?, inverted: Bool) -> String {
            guard let contribution, contribution != 0 else {
                return "前年に比べて、この要因の押し上げ・押し下げはほとんどありませんでした。"
            }
            return contribution > 0 ? plusMeaning(inverted: inverted) : minusMeaning(inverted: inverted)
        }

        /// 計算の掛け算側がマイナスだと、売上・回転・レバレッジの増減と寄与の符号が逆になる。
        /// 開示の粗利率が無くても、サーバーは事業利益+販管費からマージンを出すので、
        /// 判定は報告値ではなくドライバー増減と寄与の符号を比べる。
        private func isDriverInverted(year: FinancialsYear, prior: FinancialsYear?) -> Bool {
            switch self {
            case .salesChange:
                return signsDisagree(year.sales, prior?.sales, contribution: year.salesChangeImpact)
            case .grossMarginChange, .sgaChange:
                return false
            }
        }

        private func signsDisagree(_ current: Double?, _ prior: Double?, contribution: Double?) -> Bool {
            guard let current, let prior, let contribution, current != prior, contribution != 0 else {
                return false
            }
            return (current > prior) != (contribution > 0)
        }

        private var inversionNote: String? {
            switch self {
            case .salesChange:
                return "粗利率がマイナスのときは、売上が増えると赤字も増えます。"
            default:
                return nil
            }
        }

        private func plusMeaning(inverted: Bool) -> String {
            if inverted {
                switch self {
                case .salesChange:
                    return "前年に比べて、売上の変化が利益を押し上げました。"
                default:
                    break
                }
            }
            switch self {
            case .salesChange:
                return "前年に比べて、売上が増えて利益を押し上げました。"
            case .grossMarginChange:
                return "前年に比べて、仕入れや製造の効率が良くなり、同じ売上から残る利益が増えました。"
            case .sgaChange:
                return "前年に比べて、経費が減り、利益が増えました。"
            }
        }

        private func minusMeaning(inverted: Bool) -> String {
            if inverted {
                switch self {
                case .salesChange:
                    return "前年に比べて、売上の変化が利益を押し下げました。"
                default:
                    break
                }
            }
            switch self {
            case .salesChange:
                return "前年に比べて、売上が減って利益を押し下げました。"
            case .grossMarginChange:
                return "前年に比べて、原価がかさみ、同じ売上から残る利益が減りました。"
            case .sgaChange:
                return "前年に比べて、経費が増え、利益が減りました。"
            }
        }

        private var formula: String {
            switch self {
            case .salesChange:
                return "(当期売上 − 前期売上) × 前期粗利率"
            case .grossMarginChange:
                return "当期売上 × (当期粗利率 − 前期粗利率)"
            case .sgaChange:
                return "−(当期販管費 − 前期販管費)"
            }
        }

        private func substitution(year: FinancialsYear, prior: FinancialsYear?) -> String? {
            guard let prior else { return nil }
            switch self {
            case .salesChange:
                guard year.sales != nil, prior.sales != nil, prior.grossProfitMargin != nil else { return nil }
                return "(\(Format.autoYen(year.sales, currency: year.currency)) − \(Format.autoYen(prior.sales, currency: year.currency))) × \(Format.percent(prior.grossProfitMargin))"
            case .grossMarginChange:
                guard year.sales != nil, year.grossProfitMargin != nil, prior.grossProfitMargin != nil else { return nil }
                return "\(Format.autoYen(year.sales, currency: year.currency)) × (\(Format.percent(year.grossProfitMargin)) − \(Format.percent(prior.grossProfitMargin)))"
            case .sgaChange:
                guard year.sga != nil, prior.sga != nil else { return nil }
                return "−(\(Format.autoYen(year.sga, currency: year.currency)) − \(Format.autoYen(prior.sga, currency: year.currency)))"
            }
        }
    }

    private struct FactorRow: Identifiable {
        var kind: FactorKind
        var value: Double?
        var id: String { kind.rawValue }
    }

    private struct FactorSpec {
        var factors: [FactorRow]
        var format: (Double?) -> String
        var totalTitle: String
        var totalValue: Double?
    }

    private func factorSpec(_ year: FinancialsYear) -> FactorSpec {
        FactorSpec(
            factors: [
                FactorRow(kind: .salesChange, value: year.salesChangeImpact),
                FactorRow(kind: .grossMarginChange, value: year.grossMarginChangeImpact),
                FactorRow(kind: .sgaChange, value: year.sgaChangeImpact),
            ],
            format: { Format.autoYen($0, currency: year.currency) },
            totalTitle: "前年差",
            totalValue: year.businessProfitChange
        )
    }

    private func outcomeColor(_ value: Double?) -> Color {
        guard let value else { return Theme.text }
        if value < 0 { return Theme.negative }
        if value > 0 { return Theme.positive }
        return Theme.text
    }

    private func factorColor(_ value: Double?) -> Color {
        guard let value, value < 0 else { return Theme.text }
        return Theme.negative
    }

    /// 事業利益は前年差（要因分解の合計）がある年度だけ選べる。資本効率は年度を選ばない。
    private func isYearSelectable(_ year: FinancialsYear) -> Bool {
        year.businessProfitChange != nil
    }

    private func priorYear(of year: FinancialsYear, in years: [FinancialsYear]) -> FinancialsYear? {
        guard let index = years.firstIndex(where: { $0.id == year.id }), index > 0 else { return nil }
        return years[index - 1]
    }

}

// MARK: - 資本効率

/// ROE と ROIC の推移を 1 枚の折れ線に重ね、その下に ROE のデュポン分解を直近 5 年分並べる。
private struct CapitalEfficiencySection: View {
    var years: [FinancialsYear]

    var body: some View {
        AnalysisCard(title: "資本効率") {
            AnalysisSubheading(text: "ROE・ROICの推移")
            if years.contains(where: { $0.roic != nil || $0.roe != nil }) {
                ratioChart
                ChartLegend(items: RatioSeries.allCases.map { series -> LegendItem in
                    let latest = years.last { series.value($0) != nil }
                    return LegendItem(
                        title: series.title,
                        color: series.color,
                        shape: .line,
                        detail: latest.map { "\(Format.percent(series.value($0), digits: 2))（\(Format.fy($0.fyEnd))）" }
                    )
                })
            } else {
                AnalysisNote(text: "ROIC・ROE は未算出です。")
            }
            duPontTable(Array(years.suffix(5)))
        }
    }

    private enum RatioSeries: String, CaseIterable, Identifiable {
        case roe
        case roic

        var id: String { rawValue }

        var title: String {
            switch self {
            case .roe: "ROE"
            case .roic: "ROIC"
            }
        }

        var color: Color {
            switch self {
            case .roe: Theme.growthTint
            case .roic: ChartStyle.line
            }
        }

        func value(_ year: FinancialsYear) -> Double? {
            switch self {
            case .roe: year.roe
            case .roic: year.roic
            }
        }
    }

    /// 値は線に注記せず、凡例に直近値を添える。未算出の年は点も線も描かない。
    private var ratioChart: some View {
        Chart {
            ForEach(RatioSeries.allCases) { series in
                ForEach(ChartMath.linePoints(years, value: series.value)) { point in
                    LineMark(
                        x: .value("年度", point.label),
                        y: .value("比率", point.value),
                        series: .value("線", "\(series.rawValue)-\(point.run)")
                    )
                    .foregroundStyle(series.color)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(x: .value("年度", point.label), y: .value("比率", point.value))
                        .foregroundStyle(series.color)
                        .symbolSize(40)
                        .accessibilityLabel("\(point.label) \(series.title)")
                        .accessibilityValue(Format.percent(point.value, digits: 2))
                }
            }
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(Theme.textMuted.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 0.5))
        }
        .chartXScale(domain: years.map { Format.fy($0.fyEnd) })
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: ChartStyle.grid)
                    .foregroundStyle(ChartStyle.gridColor)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(Format.percent(number, digits: 0))
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: ChartStyle.height)
    }

    /// ROE のデュポン3要素（各年の水準）。純利益率 × 総資産回転率 × 財務レバレッジ = ROE。
    /// 年度は古い順に左から右（概要の表と同じ並び）。
    private func duPontTable(_ years: [FinancialsYear]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ROEのデュポン分解")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
            Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .gridColumnAlignment(.leading)
                    ForEach(years) { year in
                        Text(Format.fy(year.fyEnd))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                duPontRow("純利益率", years: years) { Format.percent($0.netMargin, includeUnit: false) }
                duPontRow("総資産回転率", years: years) { Format.times($0.assetTurnover, includeUnit: false) }
                duPontRow("財務レバレッジ", years: years) { Format.times($0.financialLeverage, includeUnit: false) }
                Rectangle()
                    .fill(Theme.textMuted.opacity(0.45))
                    .frame(height: 1)
                    .gridCellUnsizedAxes(.horizontal)
                duPontRow("ROE", years: years, emphasized: true) {
                    Format.percent($0.roe, digits: 2, includeUnit: false)
                }
            }
            Text("純利益率 × 総資産回転率 × 財務レバレッジ = ROE。純利益率・ROE は%、総資産回転率・財務レバレッジは倍です。純利益率は純利益 ÷ 売上、総資産回転率は売上 ÷ 総資産、財務レバレッジは総資産 ÷ 自己資本（いずれも期末）。")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.top, 8)
    }

    private func duPontRow(
        _ title: String,
        years: [FinancialsYear],
        emphasized: Bool = false,
        value: @escaping (FinancialsYear) -> String
    ) -> some View {
        GridRow {
            Text(title)
                .font(.caption.weight(emphasized ? .bold : .regular))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .fixedSize()
            ForEach(years) { year in
                Text(value(year))
                    .font(.caption.monospacedDigit().weight(emphasized ? .semibold : .regular))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

}

// MARK: - 労働生産性

/// 従業員数の推移（棒）と、従業員 1 人あたり売上高の推移（折れ線）。
private struct ProductivitySection: View {
    var years: [FinancialsYear]
    var currency: String?

    var body: some View {
        AnalysisCard(title: "労働生産性") {
            AnalysisSubheading(text: "従業員数")
            if years.contains(where: { $0.employees != nil }) {
                employeesChart
            } else {
                AnalysisNote(text: "従業員数は未集計です。")
            }
            AnalysisSubheading(text: "従業員あたりの売上高")
            if years.contains(where: { Self.salesPerEmployee($0) != nil }) {
                salesPerEmployeeChart
                if let scale {
                    AnalysisNote(text: "単位は\(scale.unit)です。従業員数は期末の連結従業員数です。")
                }
            } else {
                AnalysisNote(text: "従業員あたりの売上高は未算出です。")
            }
        }
    }

    private var labels: [String] { years.map { Format.fy($0.fyEnd) } }

    private var scale: Format.YenScale? {
        Format.commonScale(for: years.map(Self.salesPerEmployee), currency: currency)
    }

    static func salesPerEmployee(_ year: FinancialsYear) -> Double? {
        guard let sales = year.sales, let employees = year.employees, employees > 0 else { return nil }
        return sales / Double(employees)
    }

    private var employeesChart: some View {
        Chart {
            ForEach(years) { year in
                if let employees = year.employees {
                    let label = Format.fy(year.fyEnd)
                    BarMark(x: .value("年度", label), y: .value("従業員数", Double(employees)), width: .fixed(16))
                        .foregroundStyle(ChartStyle.primaryBar)
                        .cornerRadius(3)
                        .accessibilityLabel("\(label) 従業員数")
                        .accessibilityValue("\(Format.groupedNumber(Double(employees)))人")
                }
            }
        }
        .chartXScale(domain: labels)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: ChartStyle.grid)
                    .foregroundStyle(ChartStyle.gridColor)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text("\(Format.groupedNumber(number))人")
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .frame(height: 180)
    }

    private var salesPerEmployeeChart: some View {
        let points = ChartMath.linePoints(years, value: Self.salesPerEmployee)
        return Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("年度", point.label),
                    y: .value("1人あたり売上高", point.value),
                    series: .value("線", "sales-\(point.run)")
                )
                .foregroundStyle(ChartStyle.line)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                PointMark(x: .value("年度", point.label), y: .value("1人あたり売上高", point.value))
                    .foregroundStyle(ChartStyle.line)
                    .symbolSize(40)
                    .accessibilityLabel("\(point.label) 従業員あたりの売上高")
                    .accessibilityValue(Format.autoYen(point.value, currency: currency))
            }
        }
        .chartXScale(domain: labels)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: ChartStyle.grid)
                    .foregroundStyle(ChartStyle.gridColor)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(scale.map { Format.scaledYen(number, scale: $0) } ?? Format.autoYen(number))
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .frame(height: 180)
    }
}

/// 年次バー。0 を中央に置き、マイナスは左、プラスは右へ伸ばす。
private struct SignedBar: View {
    var value: Double
    var peak: Double

    var body: some View {
        GeometryReader { geo in
            let mid = geo.size.width / 2
            let magnitude = peak > 0 ? CGFloat(abs(value) / peak) * mid : 0
            let barWidth = value == 0 ? 0 : max(magnitude, 4)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.idleTab.opacity(0.55))
                    .frame(width: geo.size.width, height: geo.size.height)
                Rectangle()
                    .fill(Theme.text)
                    .frame(width: 1, height: geo.size.height)
                    .offset(x: mid)
                if value > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.positive)
                        .frame(width: barWidth, height: geo.size.height)
                        .offset(x: mid)
                } else if value < 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.negative)
                        .frame(width: barWidth, height: geo.size.height)
                        .offset(x: mid - barWidth)
                }
            }
        }
    }
}

/// 要因分解。符号に関わらず右へ伸ばし、色でプラス／マイナスを示す。
private struct MagnitudeBar: View {
    var value: Double
    var peak: Double

    var body: some View {
        GeometryReader { geo in
            let width = peak > 0 ? max(CGFloat(abs(value) / peak) * geo.size.width, value == 0 ? 0 : 4) : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.idleTab.opacity(0.55))
                    .frame(width: geo.size.width, height: geo.size.height)
                RoundedRectangle(cornerRadius: 2)
                    .fill(value >= 0 ? Theme.positive : Theme.negative)
                    .frame(width: width, height: geo.size.height)
            }
        }
    }
}
