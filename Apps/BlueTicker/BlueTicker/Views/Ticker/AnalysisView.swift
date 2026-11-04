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
                BusinessProfitSection(years: years, currency: currency)
                CapitalEfficiencySection(years: years)
                CashAllocationSection(years: years, currency: currency)
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
    /// 目盛り線と、ウォーターフォールの段をつなぐ点線。0 の線より薄くする。
    static let grid = StrokeStyle(lineWidth: 0.5, dash: [3, 3])
    static let gridColor = Theme.textMuted.opacity(0.35)
    static let primaryBar = Color(white: 0.88)
    static let secondaryBar = Color(white: 0.45)
    static let line = Color(red: 0.30, green: 0.52, blue: 0.95)
    /// 0 の線。Swift Charts の `RuleMark` と横棒で同じ色にする。
    static let zeroLine = Theme.textMuted.opacity(0.6)
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

/// 事業利益の推移。年ごとの事業利益の棒の間に前年差の浮き棒を置き、前年差をタップすると
/// 売上・利益率・販管費の要因を出す。
private struct BusinessProfitSection: View {
    var years: [FinancialsYear]
    var currency: String?
    @State private var selectedYearID: String?
    @State private var selectedFactor: FactorKind?

    var body: some View {
        AnalysisCard(title: "収益構造") {
            AnalysisSubheading(text: "事業利益の推移")
            if years.contains(where: { $0.businessProfit != nil }) {
                profitChart
                ChartLegend(items: [
                    LegendItem(title: "事業利益", color: ChartStyle.primaryBar, shape: .bar),
                    LegendItem(title: "増益", color: Theme.positive, shape: .bar),
                    LegendItem(title: "減益", color: Theme.negative, shape: .bar),
                ])
            } else {
                AnalysisNote(text: "事業利益は未算出です。")
            }
            if let selectedYear = years.first(where: { $0.id == currentYearID && isYearSelectable($0) }) {
                factorChart(selectedYear, years: years)
            } else {
                AnalysisNote(text: "前年差をタップすると売上要因・利益率要因・販管費要因を表示します。")
            }
            AnalysisNote(text: "事業利益は売上総利益 − 販管費です。開示されている営業利益と一致しない場合がございます。")
        }
    }

    /// 未選択なら、前年差がある最新の年。
    private var currentYearID: String? {
        selectedYearID ?? years.last { isYearSelectable($0) }?.id
    }

    /// 年をまたぐ前年差の段。`start` は前年、`end` は当年の事業利益。
    private struct ProfitDelta: Identifiable {
        var year: FinancialsYear
        var priorLabel: String
        var label: String
        var start: Double
        var end: Double
        var id: String { year.id }
        /// x 軸のカテゴリ。年のラベルと重ならないようにし、軸には出さない。
        var slot: String { "差\(label)" }
    }

    /// 前年差の要因がある年だけ、前年と当年の事業利益の間に段を置く。
    private var deltas: [ProfitDelta] {
        years.compactMap { year in
            guard isYearSelectable(year), let end = year.businessProfit,
                  let prior = priorYear(of: year, in: years), let start = prior.businessProfit
            else { return nil }
            return ProfitDelta(
                year: year, priorLabel: Format.fy(prior.fyEnd), label: Format.fy(year.fyEnd), start: start, end: end)
        }
    }

    /// 業績カードと同じ形の縦棒。事業利益の棒の間に前年差の浮き棒を置き、点線で段をつなぐ。
    /// 前年差をタップすると下の要因分解がその年に切り替わる。選んでいない前年差は薄くする。
    private var profitChart: some View {
        let deltas = deltas
        let yearLabels = years.map { Format.fy($0.fyEnd) }
        let slots: [String] = years.flatMap { year -> [String] in
            let label = Format.fy(year.fyEnd)
            guard let delta = deltas.first(where: { $0.id == year.id }) else { return [label] }
            return [delta.slot, label]
        }
        let scale = Format.commonScale(for: years.map(\.businessProfit), currency: currency)
        let selectedID = currentYearID
        return Chart {
            ForEach(years) { year in
                if let profit = year.businessProfit {
                    let label = Format.fy(year.fyEnd)
                    BarMark(x: .value("年度", label), y: .value("金額", profit), width: .fixed(16))
                        .foregroundStyle(profit < 0 ? Theme.negative : ChartStyle.primaryBar)
                        .cornerRadius(3)
                        .accessibilityLabel("\(label) 事業利益")
                        .accessibilityValue(Format.autoYen(profit, currency: currency))
                }
            }
            ForEach(deltas) { delta in
                let selected = delta.id == selectedID
                BarMark(
                    x: .value("年度", delta.slot), yStart: .value("金額", delta.start), yEnd: .value("金額", delta.end),
                    width: .fixed(12)
                )
                .foregroundStyle((delta.end >= delta.start ? Theme.positive : Theme.negative).opacity(selected ? 1 : 0.4))
                .cornerRadius(3)
                .accessibilityLabel("\(delta.label) 前年差")
                .accessibilityValue(Format.autoYen(delta.end - delta.start, currency: currency))
                // 前年の棒の上端 → 前年差 → 当年の棒の上端を点線でつなぐ。
                ForEach([(delta.priorLabel, delta.start, "a"), (delta.label, delta.end, "b")], id: \.2) { label, value, side in
                    LineMark(x: .value("年度", label), y: .value("金額", value), series: .value("線", "\(delta.id)-\(side)"))
                        .foregroundStyle(ChartStyle.gridColor)
                        .lineStyle(ChartStyle.grid)
                    LineMark(x: .value("年度", delta.slot), y: .value("金額", value), series: .value("線", "\(delta.id)-\(side)"))
                        .foregroundStyle(ChartStyle.gridColor)
                        .lineStyle(ChartStyle.grid)
                }
            }
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(ChartStyle.zeroLine)
                .lineStyle(StrokeStyle(lineWidth: 0.5))
        }
        .chartXScale(domain: slots)
        .chartXAxis {
            AxisMarks { value in
                // 前年差の枠にはラベルを出さない。
                if let slot = value.as(String.self), yearLabels.contains(slot) {
                    AxisValueLabel()
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        // 前年の棒の中心から当年の棒の中心までを、その前年差のタップ範囲にする。
        // 細い浮き棒の枠だけだと狙いにくいため。スクロールを奪わないようタップだけ拾う。
        .chartGesture { proxy in
            SpatialTapGesture().onEnded { value in
                let x = value.location.x
                let hit = deltas.first { delta in
                    guard let from = proxy.position(forX: delta.priorLabel),
                          let to = proxy.position(forX: delta.label)
                    else { return false }
                    return x >= min(from, to) && x <= max(from, to)
                }
                guard let hit else { return }
                selectedYearID = hit.id
                selectedFactor = nil
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
        .chartLegend(.hidden)
        .frame(height: ChartStyle.height)
    }

    private func factorChart(_ year: FinancialsYear, years: [FinancialsYear]) -> some View {
        let spec = factorSpec(year)
        let prior = priorYear(of: year, in: years)
        return VStack(alignment: .leading, spacing: 8) {
            Text(yearOutcomeTitle(year, total: spec.totalValue))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
            WaterfallChart(steps: factorSteps(spec), selectedID: selectedFactor?.rawValue) { id in
                guard let kind = FactorKind(rawValue: id) else { return }
                selectedFactor = (selectedFactor == kind ? nil : kind)
            }
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

    /// 売上・利益率・販管費の要因を順に積み、前年差は 0 から伸ばす。
    private func factorSteps(_ spec: FactorSpec) -> [WaterfallStep] {
        var running = 0.0
        var steps: [WaterfallStep] = spec.factors.map { factor in
            let value = factor.value ?? 0
            defer { running += value }
            return WaterfallStep(
                id: factor.kind.rawValue,
                title: factor.kind.title,
                start: running,
                end: running + value,
                valueText: spec.format(factor.value),
                valueColor: factorColor(factor.value),
                isTotal: false
            )
        }
        steps.append(
            WaterfallStep(
                id: "total",
                title: spec.totalTitle,
                start: 0,
                end: spec.totalValue ?? running,
                valueText: spec.format(spec.totalValue),
                valueColor: factorColor(spec.totalValue),
                isTotal: true
            ))
        return steps
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
        guard let value else { return Theme.text }
        if value < 0 { return Theme.negative }
        if value > 0 { return Theme.positive }
        return Theme.text
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

    /// ROE のデュポン3要素。最新年度の値を並べ、隣に直近 5 年の推移をスパークラインで添える。
    /// 純利益率 × 総資産回転率 × 財務レバレッジ = ROE。
    private func duPontTable(_ years: [FinancialsYear]) -> some View {
        let latest = years.last { $0.roe != nil } ?? years.last
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("ROEのデュポン分解")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                if let latest {
                    Text(Format.fy(latest.fyEnd))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            duPontRow("純利益率", years: years, latest: latest, value: \.netMargin) {
                Format.percent($0, includeUnit: true)
            }
            duPontRow("総資産回転率", years: years, latest: latest, value: \.assetTurnover) {
                Format.times($0)
            }
            duPontRow("財務レバレッジ", years: years, latest: latest, value: \.financialLeverage) {
                Format.times($0)
            }
            Rectangle()
                .fill(Theme.textMuted.opacity(0.45))
                .frame(height: 1)
            duPontRow("ROE", years: years, latest: latest, value: \.roe, emphasized: true) {
                Format.percent($0, digits: 2, includeUnit: true)
            }
        }
        .padding(.top, 8)
    }

    private func duPontRow(
        _ title: String,
        years: [FinancialsYear],
        latest: FinancialsYear?,
        value: KeyPath<FinancialsYear, Double?>,
        emphasized: Bool = false,
        format: (Double?) -> String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.caption.weight(emphasized ? .bold : .regular))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            Text(format(latest?[keyPath: value]))
                .font(.callout.monospacedDigit().weight(emphasized ? .bold : .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 76, alignment: .trailing)
            Sparkline(
                labels: years.map { Format.fy($0.fyEnd) },
                points: ChartMath.linePoints(years) { $0[keyPath: value] },
                color: emphasized ? RatioSeries.roe.color : ChartStyle.line
            )
            .frame(height: 30)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 軸のない小さな折れ線。各年度に丸を打つ。欠損年を挟んだら線を切る。
private struct Sparkline: View {
    var labels: [String]
    var points: [LinePoint]
    var color: Color

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("年度", point.label),
                    y: .value("値", point.value),
                    series: .value("線", "spark-\(point.run)")
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                PointMark(x: .value("年度", point.label), y: .value("値", point.value))
                    .foregroundStyle(color)
                    .symbolSize(18)
            }
        }
        .chartXScale(domain: labels)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartLegend(.hidden)
        .chartPlotStyle { $0.padding(.vertical, 4) }
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
                    AnalysisNote(text: "単位は\(scale.unit)です。")
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

// MARK: - 資金配分

/// フリーCF から現金増減までのウォーターフォールと、現金残高の増減（期末の現金の棒・正味現金の折れ線）。
/// 値は CF の符号（収入が正、支出が負）。換算差額とその他の現金増減は「その他」にまとめる。
private struct CashAllocationSection: View {
    var years: [FinancialsYear]
    var currency: String?
    @State private var selectedYearID: String?

    var body: some View {
        AnalysisCard(title: "資金配分") {
            AnalysisSubheading(text: "フリーCFの使い道")
            if selectableYears.isEmpty {
                AnalysisNote(text: "キャッシュ・フロー計算書の内訳は未集計です。")
            } else {
                yearPicker
                if let year = selectableYears.first(where: { $0.id == currentYearID }) {
                    waterfall(year)
                }
            }
            AnalysisSubheading(text: "現金残高の増減")
            if years.contains(where: { $0.cashEquivalents != nil }) {
                balanceChart
                ChartLegend(items: [
                    LegendItem(title: "現金及び現金同等物", color: ChartStyle.primaryBar, shape: .bar),
                    LegendItem(title: "正味現金", color: ChartStyle.line, shape: .line),
                ])
            } else {
                AnalysisNote(text: "現金及び現金同等物は未集計です。")
            }
        }
    }

    private var selectableYears: [FinancialsYear] {
        years.filter { $0.cfCashChange != nil && $0.cfc != nil && $0.cff != nil }
    }

    private var currentYearID: String? {
        selectedYearID ?? selectableYears.last?.id
    }

    private var yearPicker: some View {
        YearPicker(years: selectableYears, selectedID: currentYearID) { selectedYearID = $0 }
    }

    private struct Step: Identifiable {
        var title: String
        var value: Double
        var start: Double
        var end: Double
        var isTotal: Bool
        var id: String { title }
    }

    /// 銀行など借入・配当の内訳が無い年は、財務CF を 1 行で出す。
    private static func steps(_ year: FinancialsYear) -> [Step] {
        var items: [(String, Double)] = [("フリーCF", year.cfc ?? 0)]
        if let debt = year.cfDebtChange, let dividends = year.cfDividendsParent, let other = year.cfOtherFinancing {
            items.append(("借入の増減", debt))
            // 無配の年は配当の段を出さない。
            if dividends != 0 { items.append(("配当", dividends)) }
            // 自己株式の取得が無い年（旧データで cf_buyback が無い年を含む）は段を出さない。
            if let buyback = year.cfBuyback, buyback != 0 { items.append(("自己株式取得", buyback)) }
            items.append(("その他財務CF", other))
        } else {
            items.append(("財務CF", year.cff ?? 0))
        }
        items.append(("その他", (year.cfFxEffect ?? 0) + (year.cfOtherCashChange ?? 0)))
        var running = 0.0
        var steps: [Step] = items.map { title, value in
            defer { running += value }
            return Step(title: title, value: value, start: running, end: running + value, isTotal: false)
        }
        let total = year.cfCashChange ?? running
        steps.append(Step(title: "現金の増減", value: total, start: 0, end: total, isTotal: true))
        return steps
    }

    private func waterfall(_ year: FinancialsYear) -> some View {
        let steps = Self.steps(year)
        // 行ごとに単位が変わると桁を比べにくいので、カード内は共通の単位にそろえる。
        let yearCurrency = year.currency ?? currency
        let scale = Format.commonScale(for: steps.map(\.value), currency: yearCurrency)
        let format: (Double) -> String = { value in
            scale.map { Format.scaledYen(value, scale: $0) + $0.unit } ?? Format.autoYen(value, currency: yearCurrency)
        }
        return VStack(alignment: .leading, spacing: 8) {
            WaterfallChart(
                steps: steps.map { step in
                    WaterfallStep(
                        id: step.id,
                        title: step.title,
                        start: step.start,
                        end: step.end,
                        valueText: format(step.value),
                        valueColor: step.value > 0 ? Theme.positive : step.value < 0 ? Theme.negative : Theme.text,
                        isTotal: step.isTotal
                    )
                })
        }
        .padding(.top, 4)
    }

    /// 現金の棒と正味現金の折れ線。正味現金はマイナスになり得るので 0 の線を引く。
    private var balanceChart: some View {
        let labels = years.map { Format.fy($0.fyEnd) }
        let scale = Format.commonScale(
            for: years.map(\.cashEquivalents) + years.map(\.netCash), currency: currency)
        let netCash = ChartMath.linePoints(years) { $0.netCash }
        return Chart {
            ForEach(years) { year in
                if let cash = year.cashEquivalents {
                    let label = Format.fy(year.fyEnd)
                    BarMark(x: .value("年度", label), y: .value("金額", cash), width: .fixed(16))
                        .foregroundStyle(ChartStyle.primaryBar)
                        .cornerRadius(3)
                        .accessibilityLabel("\(label) 現金及び現金同等物")
                        .accessibilityValue(Format.autoYen(cash, currency: currency))
                }
            }
            ForEach(netCash) { point in
                LineMark(
                    x: .value("年度", point.label),
                    y: .value("金額", point.value),
                    series: .value("線", "net-cash-\(point.run)")
                )
                .foregroundStyle(ChartStyle.line)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                PointMark(x: .value("年度", point.label), y: .value("金額", point.value))
                    .foregroundStyle(ChartStyle.line)
                    .symbolSize(40)
                    .accessibilityLabel("\(point.label) 正味現金")
                    .accessibilityValue(Format.autoYen(point.value, currency: currency))
            }
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(Theme.textMuted.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 0.5))
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
                        Text(scale.map { Format.scaledYen(number, scale: $0) } ?? Format.autoYen(number))
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

/// ウォーターフォールの 1 段。合計の段は `start` を 0 にして 0 から伸ばす。
private struct WaterfallStep: Identifiable {
    var id: String
    var title: String
    var start: Double
    var end: Double
    var valueText: String
    var valueColor: Color
    var isTotal: Bool
}

/// 浮き棒のウォーターフォール（資金配分・収益構造で共通）。
/// 各段の終点から次の段へ点線を引く。
/// 段をまたぐ点線をつなげるため、棒は行ごとでなく全段まとめて 1 枚の背景に描く。
private struct WaterfallChart: View {
    var steps: [WaterfallStep]
    var selectedID: String?
    /// 渡すと合計以外の段をタップで選べる。
    var onSelect: ((String) -> Void)?

    private static let sideWidth: CGFloat = 88
    private static let columnSpacing: CGFloat = 8
    private static let barHeight: CGFloat = 16
    private static let rowPadding: CGFloat = 2
    private static let rowSpacing: CGFloat = 8
    /// 合計の前の区切り線（1pt と上下 2pt）。
    private static let dividerHeight: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(steps) { step in
                if step.isTotal {
                    Rectangle()
                        .fill(Theme.textMuted.opacity(0.45))
                        .frame(height: 1)
                        .padding(.vertical, 2)
                }
                row(step)
            }
        }
        .background(alignment: .topLeading) {
            GeometryReader { geo in
                bars(width: geo.size.width)
            }
        }
    }

    @ViewBuilder
    private func row(_ step: WaterfallStep) -> some View {
        let selected = step.id == selectedID
        let content = HStack(spacing: Self.columnSpacing) {
            Text(step.title)
                .font(.caption.weight(selected || step.isTotal ? .bold : .regular))
                .foregroundStyle(selected ? Theme.accent : Theme.text)
                .frame(width: Self.sideWidth, alignment: .leading)
            Spacer(minLength: 0)
            Text(step.valueText)
                .font(.caption.monospacedDigit().weight(step.isTotal ? .semibold : .regular))
                .foregroundStyle(step.valueColor)
                .frame(width: Self.sideWidth, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(height: Self.barHeight + Self.rowPadding * 2)
        .background(selected ? Theme.accent.opacity(0.12) : Color.clear)
        .accessibilityElement(children: .combine)
        if let onSelect, !step.isTotal {
            content
                .contentShape(Rectangle())
                .onTapGesture { onSelect(step.id) }
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        } else {
            content
        }
    }

    /// 各段の棒の上端。合計の段は区切り線の分だけ下がる。
    private var barTops: [CGFloat] {
        var y: CGFloat = 0
        return steps.map { step in
            if step.isTotal { y += Self.dividerHeight + Self.rowSpacing }
            defer { y += Self.barHeight + Self.rowPadding * 2 + Self.rowSpacing }
            return y + Self.rowPadding
        }
    }

    private func bars(width: CGFloat) -> some View {
        let bounds: [Double] = steps.flatMap { step -> [Double] in [step.start, step.end] } + [0.0]
        let lower = bounds.min() ?? 0
        let upper = bounds.max() ?? 0
        let left = Self.sideWidth + Self.columnSpacing
        let span = max(width - left * 2, 0)
        let x: (Double) -> CGFloat = { upper > lower ? left + CGFloat(($0 - lower) / (upper - lower)) * span : left }
        let tops = barTops
        return ZStack(alignment: .topLeading) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                let barLeft = x(min(step.start, step.end))
                let barWidth = step.end == step.start ? 0 : max(x(max(step.start, step.end)) - barLeft, 4)
                // 0 から伸ばす最初と合計の段は 0 軸側を直角に、間の段は両端を控えめに丸める。
                UnevenRoundedRectangle.horizontalBar(
                    growsRight: step.end >= step.start, fromZero: index == 0 || step.isTotal
                )
                .fill(step.end >= step.start ? Theme.positive : Theme.negative)
                    .frame(width: barWidth, height: Self.barHeight)
                    .offset(x: barLeft, y: tops[index])
            }
            Path { path in
                for index in steps.indices.dropLast() {
                    let connectorX = x(steps[index].end)
                    path.move(to: CGPoint(x: connectorX, y: tops[index] + Self.barHeight))
                    path.addLine(to: CGPoint(x: connectorX, y: tops[index + 1]))
                }
            }
            .stroke(ChartStyle.gridColor, style: ChartStyle.grid)
            if let first = tops.first, let last = tops.last {
                Rectangle()
                    .fill(ChartStyle.zeroLine)
                    .frame(width: 0.5, height: last + Self.barHeight - first)
                    .offset(x: x(0), y: first)
            }
        }
        .accessibilityHidden(true)
    }
}

private extension UnevenRoundedRectangle {
    /// 横棒。0 から伸ばす棒は 0 軸側を直角にし、伸びた先の端だけ控えめに丸める。
    /// 0 に接しない棒（ウォーターフォールの間の段）は両端とも丸める。
    static func horizontalBar(growsRight: Bool, fromZero: Bool = true) -> UnevenRoundedRectangle {
        let radius: CGFloat = 3
        let start: CGFloat = fromZero ? 0 : radius
        return growsRight
            ? UnevenRoundedRectangle(
                topLeadingRadius: start, bottomLeadingRadius: start,
                bottomTrailingRadius: radius, topTrailingRadius: radius)
            : UnevenRoundedRectangle(
                topLeadingRadius: radius, bottomLeadingRadius: radius,
                bottomTrailingRadius: start, topTrailingRadius: start)
    }
}

/// 年を選ぶボタンの行（収益構造の要因分解・資金配分のウォーターフォールで共通）。
private struct YearPicker: View {
    var years: [FinancialsYear]
    var selectedID: String?
    var onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(years) { year in
                    let selected = year.id == selectedID
                    Button {
                        onSelect(year.id)
                    } label: {
                        Text(Format.fy(year.fyEnd))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selected ? Theme.text : Theme.textMuted)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(selected ? Theme.accent.opacity(0.18) : Theme.idleTab.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}
