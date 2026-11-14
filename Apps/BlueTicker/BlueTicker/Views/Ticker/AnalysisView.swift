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

/// 売上高と純利益の棒。売上高は左軸、純利益は右軸（0 の位置は共通）。
private struct PerformanceSection: View {
    var years: [FinancialsYear]
    var currency: String?

    var body: some View {
        AnalysisCard(title: "業績") {
            if years.contains(where: { $0.sales != nil || $0.netProfit != nil }) {
                chart
                ChartLegend(items: [
                    LegendItem(title: "売上高（左軸）", color: ChartStyle.primaryBar, shape: .bar),
                    LegendItem(title: "純利益（右軸）", color: ChartStyle.secondaryBar, shape: .bar),
                ])
                if let salesUnit = salesScale?.unit {
                    AnalysisNote(text: "左軸は売上高（\(salesUnit)）、右軸は純利益（\(netScale?.unit ?? salesUnit)）です。")
                }
            } else {
                AnalysisNote(text: "業績は未集計です。")
            }
        }
    }

    private var labels: [String] { years.map { Format.fy($0.fyEnd) } }

    private var salesValues: [Double?] { years.map(\.sales) }
    private var netValues: [Double?] { years.map(\.netProfit) }

    private var salesScale: Format.YenScale? {
        Format.commonScale(for: salesValues, currency: currency)
    }

    private var netScale: Format.YenScale? {
        Format.commonScale(for: netValues, currency: currency)
    }

    private var salesTicks: [Double] {
        let values = salesValues.compactMap { $0 }
        return ChartMath.niceTicks(lower: values.min() ?? 0, upper: values.max() ?? 0)
    }

    private var netTicks: [Double] {
        let values = netValues.compactMap { $0 }
        return ChartMath.niceTicks(lower: values.min() ?? 0, upper: values.max() ?? 0)
    }

    /// 純利益を左軸（売上高）の目盛りに重ねる倍率。0 は共通。
    /// どの年も純利益の棒が売上高の棒より高く見えないよう、年ごとの 売上高 ÷ 純利益 の最小値で頭打ちにする
    /// （左右の軸が違うことで、売上高より大きな純利益と誤読されるのを防ぐ）。
    private var netFactor: Double {
        let leftUpper = salesTicks.max() ?? 0
        let leftLower = salesTicks.min() ?? 0
        let rightUpper = netTicks.max() ?? 0
        let rightLower = netTicks.min() ?? 0
        var ratios: [Double] = []
        if leftUpper > 0, rightUpper > 0 { ratios.append(leftUpper / rightUpper) }
        if leftLower < 0, rightLower < 0 { ratios.append(leftLower / rightLower) }
        for year in years {
            if let sales = year.sales, let net = year.netProfit, sales > 0, net > 0 {
                ratios.append(sales / net)
            }
        }
        return ratios.min() ?? 1
    }

    private var domain: ClosedRange<Double> {
        let factor = netFactor
        let lower = min(salesTicks.min() ?? 0, (netTicks.min() ?? 0) * factor)
        let upper = max(salesTicks.max() ?? 0, (netTicks.max() ?? 0) * factor)
        let pad = (upper - lower) * 0.05
        return (lower - (lower < 0 ? pad : 0))...(upper + pad)
    }

    private var chart: some View {
        let factor = netFactor
        return Chart {
            ForEach(years) { year in
                let label = Format.fy(year.fyEnd)
                if let sales = year.sales {
                    BarMark(x: .value("年度", label), y: .value("売上高", sales), width: .fixed(12))
                        .position(by: .value("系列", "売上高"))
                        .foregroundStyle(ChartStyle.primaryBar)
                        .cornerRadius(3)
                        .accessibilityLabel("\(label) 売上高")
                        .accessibilityValue(Format.autoYen(sales, currency: currency))
                }
                if let net = year.netProfit {
                    BarMark(x: .value("年度", label), y: .value("純利益", net * factor), width: .fixed(12))
                        .position(by: .value("系列", "純利益"))
                        .foregroundStyle(net < 0 ? Theme.negative : ChartStyle.secondaryBar)
                        .cornerRadius(3)
                        .accessibilityLabel("\(label) 純利益")
                        .accessibilityValue(Format.autoYen(net, currency: currency))
                }
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
            AxisMarks(position: .leading, values: salesTicks) { value in
                AxisGridLine(stroke: ChartStyle.grid)
                    .foregroundStyle(ChartStyle.gridColor)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(salesScale.map { Format.scaledYen(number, scale: $0) } ?? Format.autoYen(number))
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
            AxisMarks(position: .trailing, values: netTicks.map { $0 * factor }) { value in
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        let net = factor == 0 ? 0 : number / factor
                        Text(netScale.map { Format.scaledYen(net, scale: $0) } ?? Format.autoYen(net))
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

/// 事業利益の推移。年ごとの事業利益の棒の間に前年差の浮き棒を置く。前年差をダブルタップすると
/// 同じグラフの中で、前年度・今年度の事業利益が両端に寄り、間が要因のウォーターフォールに変わる。
private struct BusinessProfitSection: View {
    var years: [FinancialsYear]
    var currency: String?
    /// ダブルタップで拡大している前年差の年。
    @State private var expandedYearID: String?
    /// 拡大の遷移（棒の動き）が終わったら、1 年ごとに止まる横スライドのページ送りへ切り替える。
    @State private var pagerReady = false
    /// ページ送りで今見えている年。
    @State private var pageID: String?

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

        func value(_ year: FinancialsYear) -> Double? {
            switch self {
            case .salesChange: year.salesChangeImpact
            case .grossMarginChange: year.grossMarginChangeImpact
            case .sgaChange: year.sgaChangeImpact
            }
        }
    }

    var body: some View {
        AnalysisCard(title: "収益構造") {
            AnalysisSubheading(text: "事業利益の推移")
            if years.contains(where: { $0.businessProfit != nil }) {
                chartArea
                if expandedDelta == nil {
                    ChartLegend(items: [
                        LegendItem(title: "事業利益", color: ChartStyle.primaryBar, shape: .bar),
                        LegendItem(title: "増益", color: Theme.positive, shape: .bar),
                        LegendItem(title: "減益", color: Theme.negative, shape: .bar),
                    ])
                    AnalysisNote(text: "前年差をダブルタップすると、売上要因・利益率要因・販管費要因に分解します。")
                } else {
                    ChartLegend(items: [
                        LegendItem(title: "事業利益", color: ChartStyle.primaryBar, shape: .bar),
                        LegendItem(title: "プラス要因", color: Theme.positive, shape: .bar),
                        LegendItem(title: "マイナス要因", color: Theme.negative, shape: .bar),
                    ])
                    Button {
                        collapse()
                    } label: {
                        Label("推移に戻る", systemImage: "chevron.left")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    AnalysisNote(text: "左右にスライドすると、ほかの年度の前年差を見られます。ダブルタップでも元に戻ります。")
                }
            } else {
                AnalysisNote(text: "事業利益は未算出です。")
            }
            AnalysisNote(text: "事業利益は売上総利益 − 販管費です。開示されている営業利益と一致しない場合がございます。")
        }
    }

    private func collapse() {
        // ページ送りから、同じ見た目の単独グラフに戻してから、元の推移へ動かす。
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { pagerReady = false }
        withAnimation(.snappy(duration: 0.45)) {
            expandedYearID = nil
        }
    }

    private func expand(_ delta: ProfitDelta) {
        withAnimation(.snappy(duration: 0.45)) {
            expandedYearID = delta.id
        }
        // 遷移が終わったら、見た目を変えずにページ送りへ切り替える。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            guard let current = expandedYearID else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pageID = current
                pagerReady = true
            }
        }
    }

    @ViewBuilder
    private var chartArea: some View {
        if pagerReady {
            pager
        } else {
            profitChart(expanded: expandedDelta)
        }
    }

    /// 年度ごとに 1 ページ。左から前年度の棒・3 要因・今年度の棒が並び、1 ページずつ止まるので両端は常に事業利益になる。
    private var pager: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(deltas) { delta in
                    profitChart(expanded: delta)
                        .containerRelativeFrame(.horizontal)
                        .id(delta.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pageID)
        .onChange(of: pageID) { _, newValue in
            if let newValue { expandedYearID = newValue }
        }
        .frame(height: ChartStyle.height)
    }

    private var expandedDelta: ProfitDelta? {
        guard let expandedYearID else { return nil }
        return deltas.first { $0.id == expandedYearID }
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

    /// 拡大中に並べる 3 つの要因の x カテゴリ（棒の名前）。
    private static func factorSlot(_ delta: ProfitDelta, _ kind: FactorKind) -> String { "\(delta.label)|\(kind.rawValue)" }

    /// x カテゴリが要因の棒なら、その要因の名前。
    private static func factorTitle(of slot: String) -> String? {
        FactorKind.allCases.first { slot.hasSuffix("|\($0.rawValue)") }?.title
    }

    /// 業績カードと同じ形の縦棒。事業利益の棒の間に前年差の浮き棒を置き、点線で段をつなぐ。
    /// `expanded` を渡すと、その年の 前年度事業利益 → 3 要因 → 今年度事業利益 のウォーターフォール（データラベル付き）になる。
    /// 推移 ⇄ 拡大は、同じグラフの棒が動くアニメーションで遷移する。
    private func profitChart(expanded: ProfitDelta?) -> some View {
        let deltas = deltas
        let yearLabels = years.map { Format.fy($0.fyEnd) }
        let slots: [String] = years.flatMap { year -> [String] in
            let label = Format.fy(year.fyEnd)
            guard let delta = deltas.first(where: { $0.id == year.id }) else { return [label] }
            return [delta.slot, label]
        }
        let expandedSlots: [String] = expanded.map { delta in
            [delta.priorLabel] + FactorKind.allCases.map { Self.factorSlot(delta, $0) } + [delta.label]
        } ?? []
        let visibleYears: [FinancialsYear] = {
            guard let expanded, let prior = priorYear(of: expanded.year, in: years) else { return years }
            return [prior, expanded.year]
        }()
        let scale = Format.commonScale(for: years.map(\.businessProfit), currency: currency)
        return Chart {
            ForEach(visibleYears) { year in
                if let profit = year.businessProfit {
                    let label = Format.fy(year.fyEnd)
                    BarMark(x: .value("年度", label), y: .value("金額", profit), width: .fixed(16))
                        .foregroundStyle(profit < 0 ? Theme.negative : ChartStyle.primaryBar)
                        .cornerRadius(3)
                        .annotation(position: profit < 0 ? .bottom : .top, spacing: 2) {
                            if expanded != nil {
                                dataLabel(Format.autoYen(profit, currency: currency))
                            }
                        }
                        .accessibilityLabel("\(label) 事業利益")
                        .accessibilityValue(Format.autoYen(profit, currency: currency))
                }
            }
            if let expanded {
                expandedMarks(expanded)
            } else {
                ForEach(deltas) { delta in
                    BarMark(
                        x: .value("年度", delta.slot), yStart: .value("金額", delta.start), yEnd: .value("金額", delta.end),
                        width: .fixed(12)
                    )
                    .foregroundStyle(delta.end >= delta.start ? Theme.positive : Theme.negative)
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
            }
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(ChartStyle.zeroLine)
                .lineStyle(StrokeStyle(lineWidth: 0.5))
        }
        .chartXScale(domain: expanded == nil ? slots : expandedSlots)
        // 遷移の前後で縦軸（棒の高さ）が変わらないよう、全年の事業利益・前年差・要因の積み上げを含む範囲に固定する。
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks { value in
                // 通常は前年差の枠にラベルを出さない。拡大中は要因名も出す（重ならないよう小さくする）。
                if let slot = value.as(String.self), yearLabels.contains(slot) || (expanded != nil && Self.factorTitle(of: slot) != nil) {
                    AxisValueLabel {
                        Text(Self.factorTitle(of: slot) ?? slot)
                            .font(.system(size: expanded == nil ? 11 : 9))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
        // 前年の棒の中心から当年の棒の中心までを、その前年差のダブルタップ範囲にする。
        // 細い浮き棒の枠だけだと狙いにくいため。スクロールを奪わないようタップだけ拾う。
        .chartGesture { proxy in
            SpatialTapGesture(count: 2)
                .onEnded { value in
                    if expandedYearID != nil {
                        collapse()
                        return
                    }
                    guard let hit = hitDelta(at: value.location.x, proxy: proxy, deltas: deltas) else { return }
                    expand(hit)
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

    private func dataLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .fixedSize()
    }

    private var yDomain: ClosedRange<Double> {
        var values: [Double] = [0]
        values += years.compactMap(\.businessProfit)
        for delta in deltas {
            var running = delta.start
            values += [delta.start, delta.end]
            for factor in FactorKind.allCases {
                running += factor.value(delta.year) ?? 0
                values.append(running)
            }
        }
        let lower = values.min() ?? 0
        let upper = values.max() ?? 0
        // データラベルの分の余白を上下に取る。
        let pad = (upper - lower) * 0.1
        return (lower - pad)...(upper + pad)
    }

    /// 拡大中の中間の棒。前年度事業利益から要因を順に積み、各段を点線で次へつなぐ。
    @ChartContentBuilder
    private func expandedMarks(_ delta: ProfitDelta) -> some ChartContent {
        let factors: [(slot: String, kind: FactorKind, value: Double)] = FactorKind.allCases.map {
            (Self.factorSlot(delta, $0), $0, $0.value(delta.year) ?? 0)
        }
        // 各要因の始点・終点。
        let levels: [(start: Double, end: Double)] = {
            var running = delta.start
            return factors.map { factor in
                defer { running += factor.value }
                return (running, running + factor.value)
            }
        }()
        ForEach(Array(factors.enumerated()), id: \.element.slot) { index, factor in
            let level = levels[index]
            BarMark(
                x: .value("年度", factor.slot), yStart: .value("金額", level.start), yEnd: .value("金額", level.end),
                width: .fixed(16)
            )
            .foregroundStyle(factor.value >= 0 ? Theme.positive : Theme.negative)
            .cornerRadius(3)
            .annotation(position: factor.value >= 0 ? .top : .bottom, spacing: 2) {
                dataLabel((factor.value > 0 ? "+" : "") + Format.autoYen(factor.value, currency: currency))
            }
            .accessibilityLabel(factor.kind.title)
            .accessibilityValue(Format.autoYen(factor.value, currency: currency))
        }
        // 前年度の棒の上端 → 各要因の終点 → 今年度の棒の上端。
        ForEach(0..<4, id: \.self) { index in
            let level = index == 0 ? delta.start : levels[index - 1].end
            let from = index == 0 ? delta.priorLabel : factors[index - 1].slot
            let to = index < 3 ? factors[index].slot : delta.label
            LineMark(x: .value("年度", from), y: .value("金額", level), series: .value("線", "step-\(delta.id)-\(index)"))
                .foregroundStyle(ChartStyle.gridColor)
                .lineStyle(ChartStyle.grid)
            LineMark(x: .value("年度", to), y: .value("金額", level), series: .value("線", "step-\(delta.id)-\(index)"))
                .foregroundStyle(ChartStyle.gridColor)
                .lineStyle(ChartStyle.grid)
        }
    }

    private func hitDelta(at x: CGFloat, proxy: ChartProxy, deltas: [ProfitDelta]) -> ProfitDelta? {
        deltas.first { delta in
            guard let from = proxy.position(forX: delta.priorLabel),
                  let to = proxy.position(forX: delta.label)
            else { return false }
            return x >= min(from, to) && x <= max(from, to)
        }
    }

    /// 事業利益は前年差（要因分解の合計）がある年度だけ選べる。
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

/// 従業員数の推移（棒・左軸）と、従業員 1 人あたり売上高の推移（折れ線・右軸）を 1 枚に重ねる。
private struct ProductivitySection: View {
    var years: [FinancialsYear]
    var currency: String?

    private var hasEmployees: Bool { years.contains { $0.employees != nil } }
    private var hasSalesPerEmployee: Bool { years.contains { Self.salesPerEmployee($0) != nil } }

    var body: some View {
        AnalysisCard(title: "労働生産性") {
            if hasEmployees || hasSalesPerEmployee {
                chart
                ChartLegend(items: [
                    LegendItem(title: "従業員数（左軸）", color: ChartStyle.primaryBar, shape: .bar),
                    LegendItem(title: "1人あたり売上高（右軸）", color: ChartStyle.line, shape: .line),
                ])
                if let scale {
                    AnalysisNote(text: "右軸の単位は\(scale.unit)です。")
                }
                if !hasEmployees {
                    AnalysisNote(text: "従業員数は未集計です。")
                } else if !hasSalesPerEmployee {
                    AnalysisNote(text: "従業員あたりの売上高は未算出です。")
                }
            } else {
                AnalysisNote(text: "従業員数は未集計です。")
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

    private var employeeTicks: [Double] {
        let values = years.compactMap { $0.employees.map(Double.init) }
        return ChartMath.niceTicks(lower: values.min() ?? 0, upper: values.max() ?? 0)
    }

    private var salesTicks: [Double] {
        let values = years.compactMap(Self.salesPerEmployee)
        return ChartMath.niceTicks(lower: values.min() ?? 0, upper: values.max() ?? 0)
    }

    /// 1 人あたり売上高を左軸（従業員数）の目盛りに重ねる倍率。0 は共通。
    private var lineFactor: Double {
        let leftTop = employeeTicks.max() ?? 0
        let rightTop = salesTicks.max() ?? 0
        guard leftTop > 0, rightTop > 0 else { return 1 }
        return leftTop / rightTop
    }

    private var domain: ClosedRange<Double> {
        let factor = lineFactor
        let lower = min(employeeTicks.min() ?? 0, (salesTicks.min() ?? 0) * factor)
        let upper = max(employeeTicks.max() ?? 0, (salesTicks.max() ?? 0) * factor)
        let pad = (upper - lower) * 0.05
        return (lower - (lower < 0 ? pad : 0))...(upper + pad)
    }

    private var chart: some View {
        let factor = lineFactor
        let points = ChartMath.linePoints(years, value: Self.salesPerEmployee)
        return Chart {
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
            ForEach(points) { point in
                LineMark(
                    x: .value("年度", point.label),
                    y: .value("1人あたり売上高", point.value * factor),
                    series: .value("線", "sales-\(point.run)")
                )
                .foregroundStyle(ChartStyle.line)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                PointMark(x: .value("年度", point.label), y: .value("1人あたり売上高", point.value * factor))
                    .foregroundStyle(ChartStyle.line)
                    .symbolSize(40)
                    .accessibilityLabel("\(point.label) 従業員あたりの売上高")
                    .accessibilityValue(Format.autoYen(point.value, currency: currency))
            }
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(ChartStyle.zeroLine)
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
            AxisMarks(position: .leading, values: employeeTicks) { value in
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
            AxisMarks(position: .trailing, values: salesTicks.map { $0 * factor }) { value in
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        let amount = number / factor
                        Text(scale.map { Format.scaledYen(amount, scale: $0) } ?? Format.autoYen(amount))
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
