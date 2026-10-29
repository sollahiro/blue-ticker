import Charts
import SwiftUI

enum BreakdownMetric: String, CaseIterable, Identifiable {
    case businessProfit
    case capitalEfficiency

    var id: String { rawValue }

    var title: String {
        switch self {
        case .businessProfit: "事業利益"
        case .capitalEfficiency: "資本効率"
        }
    }
}

struct BreakdownView: View {
    var code: String
    @Binding var metric: BreakdownMetric
    @State private var response: FinancialsResponse?
    @State private var errorMessage: String?
    @State private var selectedYearID: String?
    @State private var selectedFactor: FactorKind?

    var body: some View {
        Group {
            if let response {
                content(response)
            } else if let errorMessage {
                TickerStubView(title: "分解", detail: errorMessage)
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
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SegmentPills(
                    items: Array(BreakdownMetric.allCases),
                    selection: $metric,
                    title: { $0.title }
                )
                switch metric {
                case .businessProfit:
                    businessProfit(years)
                case .capitalEfficiency:
                    capitalEfficiency(years)
                }
            }
            .padding(Theme.cardContentInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .bltCardScroll()
        .onChange(of: metric) { _, _ in
            selectedFactor = nil
        }
    }

    @ViewBuilder
    private func businessProfit(_ years: [FinancialsYear]) -> some View {
        if years.contains(where: { $0.businessProfit != nil }) {
            yearBars(years)
        } else {
            Text("事業利益は未算出です。")
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
        }
        if let selectedYear = years.first(where: { $0.id == selectedYearID && isYearSelectable($0) }) {
            factorChart(selectedYear, years: years)
        } else {
            Text("年を選ぶと売上要因・利益率要因・販管費要因を表示します。")
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
        }
        Text("事業利益は売上総利益 − 販管費です。開示されている営業利益と一致しない場合がございます。")
            .font(.footnote)
            .foregroundStyle(Theme.textMuted)
    }

    private func yearBars(_ years: [FinancialsYear]) -> some View {
        let peak = years.compactMap(metricValue).map(abs).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(years) { year in
                let selectable = isYearSelectable(year)
                let selected = selectable && year.id == selectedYearID
                let row = HStack(spacing: 8) {
                    Text(Format.fy(year.fyEnd))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 48, alignment: .leading)
                    SignedBar(value: metricValue(year) ?? 0, peak: peak)
                        .frame(height: 18)
                    Text(metricLabel(year))
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

    /// 資本効率。ROIC と ROE の推移を1枚の折れ線に重ね、その下に ROE のデュポン分解を直近5年分並べる。
    @ViewBuilder
    private func capitalEfficiency(_ years: [FinancialsYear]) -> some View {
        if years.contains(where: { $0.roic != nil || $0.roe != nil }) {
            ratioLegend(years)
            ratioChart(years)
        } else {
            Text("ROIC・ROE は未算出です。")
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
        }
        duPontTable(Array(years.suffix(5)))
    }

    private enum RatioSeries: String, CaseIterable, Identifiable {
        case roic
        case roe

        var id: String { rawValue }

        var title: String {
            switch self {
            case .roic: "ROIC"
            case .roe: "ROE"
            }
        }

        var color: Color {
            switch self {
            case .roic: Theme.accent
            case .roe: Theme.growthTint
            }
        }

        func value(_ year: FinancialsYear) -> Double? {
            switch self {
            case .roic: year.roic
            case .roe: year.roe
            }
        }
    }

    /// 凡例。値は線の上に出さず、ここに直近の値を添える（2本の注記が重なるため）。
    private func ratioLegend(_ years: [FinancialsYear]) -> some View {
        HStack(spacing: 16) {
            ForEach(RatioSeries.allCases) { series in
                let latest = years.last { series.value($0) != nil }
                HStack(spacing: 6) {
                    Circle()
                        .fill(series.color)
                        .frame(width: 8, height: 8)
                    Text(series.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    if let latest {
                        Text("\(Format.percent(series.value(latest), digits: 2))（\(Format.fy(latest.fyEnd))）")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func ratioChart(_ years: [FinancialsYear]) -> some View {
        let labels = years.map { Format.fy($0.fyEnd) }
        let anchors = years.indices.filter { index in
            RatioSeries.allCases.allSatisfy { $0.value(years[index]) == nil }
        }
        return Chart {
            ForEach(RatioSeries.allCases) { series in
                ForEach(ratioSegments(series, years: years)) { segment in
                    ForEach(segment.points) { point in
                        LineMark(
                            x: .value("比率", point.value),
                            y: .value("年度", point.index),
                            series: .value("line", "\(series.rawValue)-\(segment.id)")
                        )
                        .foregroundStyle(series.color)
                        .lineStyle(StrokeStyle(lineWidth: 3))
                    }
                }
                ForEach(ratioPoints(series, years: years)) { point in
                    PointMark(
                        x: .value(series.title, point.value),
                        y: .value("年度", point.index)
                    )
                    .foregroundStyle(series.color)
                    .symbolSize(45)
                    .accessibilityLabel("\(labels[point.id]) \(series.title)")
                    .accessibilityValue(Format.percent(point.value, digits: 2))
                }
            }
            RuleMark(x: .value("zero", 0))
                .foregroundStyle(Theme.text)
                .lineStyle(StrokeStyle(lineWidth: 1))
            // 両方とも欠損の年も年度軸の domain に含め、目盛りと行間隔を全年度分保つ。
            // 値ではなく位置だけを表すので、読み上げ対象からは外す。
            ForEach(anchors, id: \.self) { index in
                PointMark(
                    x: .value("比率", 0),
                    y: .value("年度", Double(index))
                )
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false, reversed: true))
        .chartXAxis {
            AxisMarks(position: .bottom) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Theme.textMuted.opacity(0.35))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(Format.percent(number, digits: 1))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: years.indices.map { Double($0) }) { value in
                AxisValueLabel {
                    if let position = value.as(Double.self) {
                        let index = Int(position.rounded())
                        if labels.indices.contains(index) {
                            Text(labels[index])
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                }
            }
        }
        .frame(height: CGFloat(max(160, years.count * 35)))
        .padding(.top, 4)
    }

    private struct Segment: Identifiable {
        var id: Int
        var points: [SegmentPoint]
    }

    private struct SegmentPoint: Identifiable {
        var id: Int
        var index: Double
        var value: Double
    }

    /// 値のある年だけを、元の年度並びの位置（`index`）を保ったまま返す。
    private func ratioPoints(_ series: RatioSeries, years: [FinancialsYear]) -> [SegmentPoint] {
        years.enumerated().compactMap { index, year in
            series.value(year).map { SegmentPoint(id: index, index: Double(index), value: $0) }
        }
    }

    /// 隣り合う年どうしだけを結ぶ。欠損年を挟む区間は線を引かない。
    private func ratioSegments(_ series: RatioSeries, years: [FinancialsYear]) -> [Segment] {
        let points = ratioPoints(series, years: years)
        return zip(points, points.dropFirst()).compactMap { start, end in
            guard end.index == start.index + 1 else { return nil }
            let yearIndex = start.id
            return Segment(
                id: yearIndex,
                points: [
                    SegmentPoint(id: yearIndex * 2, index: start.index, value: start.value),
                    SegmentPoint(id: yearIndex * 2 + 1, index: end.index, value: end.value),
                ]
            )
        }
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

    private func metricValue(_ year: FinancialsYear) -> Double? {
        year.businessProfit
    }

    private func metricLabel(_ year: FinancialsYear) -> String {
        Format.autoYen(year.businessProfit, currency: year.currency)
    }

    private func load() async {
        if let cached = await APIClient.shared.cachedWaterfall(code: code) {
            response = cached
            errorMessage = nil
            if selectedYearID == nil {
                let years = Format.chronological(cached.years)
                selectedYearID = years.last { isYearSelectable($0) }?.id
            }
        }
        do {
            let loaded = try await APIClient.shared.waterfall(code: code)
            response = loaded
            errorMessage = nil
            if selectedYearID == nil {
                let years = Format.chronological(loaded.years)
                selectedYearID = years.last { isYearSelectable($0) }?.id
            }
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
