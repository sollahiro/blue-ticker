import Charts
import SwiftUI

enum BreakdownMetric: String, CaseIterable, Identifiable {
    case businessProfit
    case roic
    case roe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .businessProfit: "事業利益"
        case .roic: "ROIC"
        case .roe: "ROE"
        }
    }
}

struct BreakdownView: View {
    var code: String
    @State private var response: FinancialsResponse?
    @State private var errorMessage: String?
    @State private var metric: BreakdownMetric = .businessProfit
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
        let selectedYear = years.first { $0.id == selectedYearID && isYearSelectable($0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(BreakdownMetric.allCases) { item in
                        Button(item.title) { metric = item }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(metric == item ? Theme.selectedTab : Theme.idleTab)
                            .foregroundStyle(metric == item ? .white : Theme.text)
                    }
                }
                if metric == .businessProfit {
                    yearBars(years)
                } else if years.contains(where: { metricValue($0) != nil }) {
                    ratioChart(years)
                } else {
                    Text("\(metric.title) は未算出です。")
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                }
                if let selectedYear {
                    factorChart(selectedYear, years: years)
                } else {
                    Text(factorPrompt)
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                }
                if metric == .businessProfit {
                    Text("事業利益は売上総利益 − 販管費です。開示の営業利益行ではありません。")
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
        .padding(16)
        .onChange(of: metric) { _, _ in
            selectedFactor = nil
        }
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

    private func ratioChart(_ years: [FinancialsYear]) -> some View {
        let labels = years.map { Format.fy($0.fyEnd) }
        let points = ratioPoints(years)
        let anchors = ratioAnchors(years)
        let segments = ratioSegments(points)
        let xMin = min(points.map(\.value).min() ?? 0, 0)
        let xMax = max(points.map(\.value).max() ?? 0, 0)
        let selectedIndex = years.firstIndex { $0.id == selectedYearID && isYearSelectable($0) }
        let selectedSegment = selectedIndex.flatMap { index in
            segments.first { $0.points.last?.index == index }
        }
        return Chart {
            if let segment = selectedSegment, let start = segment.points.first?.index, let end = segment.points.last?.index, xMin < xMax {
                RectangleMark(
                    xStart: .value(metric.title, xMin),
                    xEnd: .value(metric.title, xMax),
                    yStart: .value("年度", start),
                    yEnd: .value("年度", end)
                )
                .foregroundStyle(segment.color.opacity(0.15))
            }
            ForEach(segments, id: \.id) { segment in
                ForEach(segment.points, id: \.id) { point in
                    LineMark(
                        x: .value(metric.title, point.value),
                        y: .value("年度", point.index)
                    )
                    .foregroundStyle(segment.color)
                    .lineStyle(StrokeStyle(lineWidth: 3))
                }
            }
            RuleMark(x: .value("zero", 0))
                .foregroundStyle(Theme.text)
                .lineStyle(StrokeStyle(lineWidth: 1))
            // 欠損年も年度軸の domain に含め、目盛りと行間隔を全年度分保つ。
            // 値ではなく位置だけを表すので、読み上げ対象からは外す。
            ForEach(anchors, id: \.self) { index in
                PointMark(
                    x: .value(metric.title, 0),
                    y: .value("年度", index)
                )
                .opacity(0)
                .accessibilityHidden(true)
            }
            ForEach(points, id: \.id) { point in
                PointMark(
                    x: .value(metric.title, point.value),
                    y: .value("年度", point.index)
                )
                .foregroundStyle(point.index == selectedIndex ? Theme.accent : Theme.text)
                .symbolSize(point.index == selectedIndex ? 90 : 45)
                .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                    Text(Format.percent(point.value, digits: 1))
                        .font(.caption2)
                        .foregroundStyle(Theme.text)
                }
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
            AxisMarks(position: .leading, values: Array(years.indices)) { value in
                AxisValueLabel {
                    if let index = value.as(Int.self), labels.indices.contains(index) {
                        Text(labels[index])
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plot = proxy.plotFrame, !years.isEmpty else { return }
                        let plotRect = geo[plot]
                        let y = location.y - plotRect.origin.y
                        var selected: Int?
                        if let dataY: Double = proxy.value(atY: y) {
                            selected = Int(dataY.rounded())
                        } else {
                            let normalized = max(0, min(1, y / plotRect.height))
                            selected = Int((Double(years.count - 1) * (1.0 - normalized)).rounded())
                        }
                        guard let selected, years.indices.contains(selected),
                            isYearSelectable(years[selected])
                        else { return }
                        selectedYearID = years[selected].id
                    }
            }
        }
        .frame(height: CGFloat(max(160, years.count * 35)))
        .padding(.top, 4)
    }

    private struct Segment: Identifiable {
        var id: Int
        var points: [SegmentPoint]
        var color: Color
    }

    private struct SegmentPoint: Identifiable {
        var id: Int
        var index: Int
        var value: Double
    }

    /// 値のある年だけを、元の年度並びの位置（`index`）を保ったまま返す。
    private func ratioPoints(_ years: [FinancialsYear]) -> [SegmentPoint] {
        years.enumerated().compactMap { index, year in
            metricValue(year).map { SegmentPoint(id: index, index: index, value: $0) }
        }
    }

    /// 値のない年の位置。年度軸が縮まないよう不可視マークを置くために使う。
    private func ratioAnchors(_ years: [FinancialsYear]) -> [Int] {
        years.indices.filter { metricValue(years[$0]) == nil }
    }

    /// 隣り合う年どうしだけを結ぶ。欠損年を挟む区間は線を引かない。
    private func ratioSegments(_ points: [SegmentPoint]) -> [Segment] {
        let band = metricBand
        var segments: [Segment] = []
        for (start, end) in zip(points, points.dropFirst()) where end.index == start.index + 1 {
            let midValue = (start.value + end.value) / 2
            segments.append(Segment(
                id: start.index,
                points: [
                    SegmentPoint(id: start.index * 2, index: start.index, value: start.value),
                    SegmentPoint(id: start.index * 2 + 1, index: end.index, value: end.value),
                ],
                color: band.color(for: midValue)
            ))
        }
        return segments
    }

    private var factorPrompt: String {
        switch metric {
        case .businessProfit:
            return "年を選ぶと売上要因・利益率要因・販管費要因を表示します。"
        case .roic:
            return "年を選ぶと利益率要因・回転率要因を表示します。"
        case .roe:
            return "年を選ぶと純利益率要因・回転率要因・レバレッジ要因を表示します。"
        }
    }

    private func factorChart(_ year: FinancialsYear, years: [FinancialsYear]) -> some View {
        let spec = factorSpec(year)
        let peak = (spec.factors.map { abs($0.value ?? 0) } + [abs(spec.totalValue ?? 0)]).max() ?? 0
        let prior = priorYear(of: year, in: years)
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(Format.fy(year.fyEnd)) の要因分解")
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
            if let selectedFactor, spec.factors.contains(where: { $0.kind == selectedFactor }) {
                let detail = selectedFactor.detail(year: year, prior: prior)
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedFactor.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                    ForEach(Array(detail.enumerated()), id: \.offset) { _, line in
                        Text(line)
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

    private enum FactorKind: String, CaseIterable {
        case salesChange
        case grossMarginChange
        case sgaChange
        case roicMargin
        case roicTurnover
        case roeNetMargin
        case roeTurnover
        case roeLeverage

        var title: String {
            switch self {
            case .salesChange: "売上要因"
            case .grossMarginChange, .roicMargin: "利益率要因"
            case .sgaChange: "販管費要因"
            case .roicTurnover, .roeTurnover: "回転率要因"
            case .roeNetMargin: "純利益率要因"
            case .roeLeverage: "レバレッジ要因"
            }
        }

        func detail(year: FinancialsYear, prior: FinancialsYear?) -> [String] {
            var lines = [blurb]
            lines.append(formula)
            if let substitution = substitution(year: year, prior: prior) {
                lines.append("= \(substitution)")
            }
            return lines
        }

        private var blurb: String {
            switch self {
            case .salesChange:
                return "売上高の増減を、前期の粗利率で利益に換算した寄与です。"
            case .grossMarginChange:
                return "同じ売上でも粗利率が変わった分の寄与です。"
            case .sgaChange:
                return "販管費の増減が事業利益を押し上げ・押し下げた分です。販管費が増えるとマイナスになります。"
            case .roicMargin:
                return "NOPATマージン（税引後営業利益率）の変化が ROIC に効いた分です。"
            case .roicTurnover:
                return "投下資本回転率の変化が ROIC に効いた分です。"
            case .roeNetMargin:
                return "純利益率の変化が ROE に効いた分です。"
            case .roeTurnover:
                return "総資産回転率の変化が ROE に効いた分です。"
            case .roeLeverage:
                return "財務レバレッジ（総資産 ÷ 自己資本）の変化が ROE に効いた分です。"
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
            case .roicMargin:
                return "(当期NOPATマージン − 前期NOPATマージン) × 前期投下資本回転率"
            case .roicTurnover:
                return "当期NOPATマージン × (当期回転率 − 前期回転率)"
            case .roeNetMargin:
                return "(当期純利益率 − 前期純利益率) × 前期総資産回転率 × 前期財務レバレッジ"
            case .roeTurnover:
                return "当期純利益率 × (当期回転率 − 前期回転率) × 前期財務レバレッジ"
            case .roeLeverage:
                return "当期純利益率 × 当期総資産回転率 × (当期レバレッジ − 前期レバレッジ)"
            }
        }

        private func substitution(year: FinancialsYear, prior: FinancialsYear?) -> String? {
            guard let prior else { return nil }
            switch self {
            case .salesChange:
                guard year.sales != nil, prior.sales != nil, prior.grossProfitMargin != nil else { return nil }
                return "(\(Format.autoYen(year.sales)) − \(Format.autoYen(prior.sales))) × \(Format.percent(prior.grossProfitMargin))"
            case .grossMarginChange:
                guard year.sales != nil, year.grossProfitMargin != nil, prior.grossProfitMargin != nil else { return nil }
                return "\(Format.autoYen(year.sales)) × (\(Format.percent(year.grossProfitMargin)) − \(Format.percent(prior.grossProfitMargin)))"
            case .sgaChange:
                guard year.sga != nil, prior.sga != nil else { return nil }
                return "−(\(Format.autoYen(year.sga)) − \(Format.autoYen(prior.sga)))"
            case .roicMargin:
                guard year.nopatMargin != nil, prior.nopatMargin != nil, prior.investedCapitalTurnover != nil else {
                    return nil
                }
                return "(\(Format.percent(year.nopatMargin)) − \(Format.percent(prior.nopatMargin))) × \(Format.times(prior.investedCapitalTurnover))"
            case .roicTurnover:
                guard year.nopatMargin != nil, year.investedCapitalTurnover != nil,
                    prior.investedCapitalTurnover != nil
                else { return nil }
                return "\(Format.percent(year.nopatMargin)) × (\(Format.times(year.investedCapitalTurnover)) − \(Format.times(prior.investedCapitalTurnover)))"
            case .roeNetMargin:
                guard year.netMargin != nil, prior.netMargin != nil, prior.assetTurnover != nil,
                    prior.financialLeverage != nil
                else { return nil }
                return "(\(Format.percent(year.netMargin)) − \(Format.percent(prior.netMargin))) × \(Format.times(prior.assetTurnover)) × \(Format.times(prior.financialLeverage))"
            case .roeTurnover:
                guard year.netMargin != nil, year.assetTurnover != nil, prior.assetTurnover != nil,
                    prior.financialLeverage != nil
                else { return nil }
                return "\(Format.percent(year.netMargin)) × (\(Format.times(year.assetTurnover)) − \(Format.times(prior.assetTurnover))) × \(Format.times(prior.financialLeverage))"
            case .roeLeverage:
                guard year.netMargin != nil, year.assetTurnover != nil, year.financialLeverage != nil,
                    prior.financialLeverage != nil
                else { return nil }
                return "\(Format.percent(year.netMargin)) × \(Format.times(year.assetTurnover)) × (\(Format.times(year.financialLeverage)) − \(Format.times(prior.financialLeverage)))"
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
        switch metric {
        case .businessProfit:
            return FactorSpec(
                factors: [
                    FactorRow(kind: .salesChange, value: year.salesChangeImpact),
                    FactorRow(kind: .grossMarginChange, value: year.grossMarginChangeImpact),
                    FactorRow(kind: .sgaChange, value: year.sgaChangeImpact),
                ],
                format: Format.autoYen,
                totalTitle: "前年差",
                totalValue: year.businessProfitChange
            )
        case .roic:
            return FactorSpec(
                factors: [
                    FactorRow(kind: .roicMargin, value: year.roicMarginEffect),
                    FactorRow(kind: .roicTurnover, value: year.roicTurnoverEffect),
                ],
                format: Format.percentPoints,
                totalTitle: "前年差",
                totalValue: year.roicDelta
            )
        case .roe:
            return FactorSpec(
                factors: [
                    FactorRow(kind: .roeNetMargin, value: year.roeNetMarginEffect),
                    FactorRow(kind: .roeTurnover, value: year.roeAssetTurnoverEffect),
                    FactorRow(kind: .roeLeverage, value: year.roeLeverageEffect),
                ],
                format: Format.percentPoints,
                totalTitle: "前年差",
                totalValue: year.roeDelta
            )
        }
    }

    private var metricBand: MetricBand {
        switch metric {
        case .roic:
            return .higherBetter(lowBelow: 4, midFrom: 6, midTo: 8, highFrom: 10)
        case .roe:
            return .higherBetter(lowBelow: 5, midFrom: 8, midTo: 10, highFrom: 15)
        case .businessProfit:
            return .none
        }
    }

    private func factorColor(_ value: Double?) -> Color {
        guard let value, value < 0 else { return Theme.text }
        return Theme.negative
    }

    /// 前年差（要因分解の合計）がある年度だけ選べる。
    private func isYearSelectable(_ year: FinancialsYear) -> Bool {
        switch metric {
        case .businessProfit:
            return year.businessProfitChange != nil
        case .roic:
            return year.roicDelta != nil
        case .roe:
            return year.roeDelta != nil
        }
    }

    private func priorYear(of year: FinancialsYear, in years: [FinancialsYear]) -> FinancialsYear? {
        guard let index = years.firstIndex(where: { $0.id == year.id }), index > 0 else { return nil }
        return years[index - 1]
    }

    private func metricValue(_ year: FinancialsYear) -> Double? {
        switch metric {
        case .businessProfit: year.businessProfit
        case .roic: year.roic
        case .roe: year.roe
        }
    }

    private func metricLabel(_ year: FinancialsYear) -> String {
        switch metric {
        case .businessProfit:
            return Format.autoYen(year.businessProfit)
        case .roic:
            return Format.percent(year.roic, digits: 2)
        case .roe:
            return Format.percent(year.roe, digits: 2)
        }
    }

    private func load() async {
        do {
            let loaded = try await APIClient.shared.waterfall(code: code)
            response = loaded
            errorMessage = nil
            if selectedYearID == nil {
                let years = Format.chronological(loaded.years)
                selectedYearID = years.last { isYearSelectable($0) }?.id
            }
        } catch APIClientError.http(let status, let message) where status == 404 {
            errorMessage = message.isEmpty ? "財務データは未集計です" : message
        } catch {
            errorMessage = error.localizedDescription
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
