import SwiftUI

/// 銘柄ページの「セグメント」「地域」カード。収益構造の次に並べる。
/// セグメントは `/waterfall/segment`（外部売上の年次推移）と `/breakdown?axis=segment`（最新期の利益）、
/// 地域は `/breakdown?axis=geography` を年ごとに取る。取れない会社（単一セグメント・未算出・地域が
/// セグメントそのもの）ではカードを出さない。
struct BreakdownSections: View {
    /// 読み込み前・取得失敗は nil。読み込みは親が持つ（中身が空の View に付けた `.task` は動かないため）。
    var model: BreakdownModel?

    var body: some View {
        Group {
            if let segment = model?.segment {
                SegmentCard(model: segment)
            }
            if let region = model?.region {
                RegionCard(model: region)
            }
        }
    }
}

// MARK: - 取得

struct SegmentCardModel {
    var columns: [BreakdownColumnInput]
    var layout: BreakdownLayout
    var rows: [SegmentSummaryRow]
}

struct RegionCardModel {
    var columns: [BreakdownColumnInput]
    var layout: BreakdownLayout
    var rows: [ShareSummaryRow]
}

struct BreakdownModel {
    var segment: SegmentCardModel?
    var region: RegionCardModel?

    /// 失敗や 404 はカードを出さないだけ（分析ページ全体のエラーにしない）。
    static func load(code: String) async -> BreakdownModel {
        guard let waterfall = try? await APIClient.shared.segmentWaterfall(code: code, years: 3) else {
            return BreakdownModel()
        }
        // 再編で統合された旧区分は、過去の年も 1 本にまとめる（流れを追う必要はない）。
        let columns = BreakdownBuilder.collapsingReorgs(
            BreakdownBuilder.segmentColumns(waterfall) { Format.fy($0.fyEnd) })
        // 区分が 1 つだけでは構成も推移も見えない。
        guard let latest = columns.last, latest.items.count >= 2 else { return BreakdownModel() }

        // 利益（最新期）と地域（年ごと）は互いに待たず、同時に取る。
        async let detail = try? APIClient.shared.breakdown(code: code, axis: "segment")
        async let regionResponses = loadRegionResponses(code: code, waterfall: waterfall)
        let detailRows = await detail?.breakdown?.rows ?? []
        var profitByKey: [String: Double] = [:]
        for row in detailRows {
            if let profit = row.profit?.value { profitByKey[row.segmentKey ?? row.label] = profit }
        }
        let layout = StackedLayout.make(columns: columns)
        let segment = SegmentCardModel(
            columns: columns, layout: layout,
            rows: BreakdownSummary.segmentRows(columns: columns, layout: layout, profitByKey: profitByKey))

        // 地域がセグメントそのものの会社は、セグメントカードに出ているので重ねない。
        let geographic = detailRows.contains { $0.segmentBasis == "geographic" }
        let region = geographic ? nil : regionModel(waterfall: waterfall, responses: await regionResponses)
        return BreakdownModel(segment: segment, region: region)
    }

    /// 年ごとの地域別売上を並列に取る。取れなかった年は nil。結果は `waterfall.years` と同じ並び（新しい年が先頭）。
    private static func loadRegionResponses(
        code: String, waterfall: SegmentWaterfallResponse
    ) async -> [BreakdownResponse?] {
        await withTaskGroup(of: (Int, BreakdownResponse?).self) { group in
            for (index, year) in waterfall.years.enumerated() {
                guard let docId = year.docId else { continue }
                group.addTask {
                    (index, try? await APIClient.shared.breakdown(code: code, axis: "geography", docId: docId))
                }
            }
            var results = [BreakdownResponse?](repeating: nil, count: waterfall.years.count)
            for await (index, response) in group { results[index] = response }
            return results
        }
    }

    private static func regionModel(
        waterfall: SegmentWaterfallResponse, responses: [BreakdownResponse?]
    ) -> RegionCardModel? {
        var columns: [BreakdownColumnInput] = []
        for (year, response) in zip(waterfall.years, responses).reversed() {
            guard let response else { continue }
            let previous = columns.last.map { Set($0.items.map(\.label)) }
            let column = BreakdownBuilder.geographyColumn(
                label: Format.fy(year.fyEnd), previousLabels: previous, response: response)
            if !column.items.isEmpty { columns.append(column) }
        }
        guard let latest = columns.last, latest.items.count >= 2 else { return nil }
        let layout = StackedLayout.make(columns: columns)
        return RegionCardModel(
            columns: columns, layout: layout, rows: BreakdownSummary.shareRows(columns: columns, layout: layout))
    }
}

// MARK: - カード

private struct SegmentCard: View {
    var model: SegmentCardModel

    var body: some View {
        AnalysisCard(title: "セグメント") {
            StackedBarChart(layout: model.layout, accessibilityText: "セグメント別の外部売上の年次推移")
            segmentTable
            AnalysisNote(text: "棒は外部売上。利益と利益率は最新期のセグメント利益（消去・全社を除く）です。前年と結べない区分（組替・新設）の前年比は出しません。")
        }
    }

    private var segmentTable: some View {
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text(model.layout.columnLabels.last ?? "")
                    .gridColumnAlignment(.leading)
                Text("前年比")
                Text("利益")
                Text("利益率")
            }
            .font(.caption)
            .foregroundStyle(Theme.textMuted)
            ForEach(model.rows) { row in
                GridRow {
                    SeriesLabel(label: row.label, colorIndex: row.colorIndex, mark: row.mark)
                        .gridColumnAlignment(.leading)
                    Text(BreakdownFormat.signedPercent(row.yoy))
                        .foregroundStyle(BreakdownFormat.signColor(row.yoy))
                    Text(row.profit.map { Format.autoYen($0) } ?? "—")
                        .foregroundStyle(BreakdownFormat.signColor(row.profit, neutralPositive: true))
                    Text(row.margin.map { Format.percent($0 * 100) } ?? "—")
                        .foregroundStyle(Theme.text)
                }
                .font(.footnote.monospacedDigit())
            }
        }
    }
}

private struct RegionCard: View {
    var model: RegionCardModel

    var body: some View {
        AnalysisCard(title: "地域") {
            StackedBarChart(layout: model.layout, accessibilityText: "地域別売上の年次推移")
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(model.layout.columnLabels.last ?? "")
                        .gridColumnAlignment(.leading)
                    Text("構成比")
                    Text("前年差")
                }
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
                ForEach(model.rows) { row in
                    GridRow {
                        SeriesLabel(label: row.label, colorIndex: row.colorIndex, mark: .none)
                            .gridColumnAlignment(.leading)
                        Text(Format.percent(row.share * 100, digits: 0))
                            .foregroundStyle(Theme.text)
                        Text(BreakdownFormat.signedPoints(row.deltaPoints))
                            .foregroundStyle(BreakdownFormat.signColor(row.deltaPoints))
                    }
                    .font(.footnote.monospacedDigit())
                }
            }
            AnalysisNote(text: "地域別売上高。地域の区分は会社ごとの開示のままで、前年と区分が違う行の前年差は出しません（—）。")
        }
    }
}

private struct SeriesLabel: View {
    var label: String
    var colorIndex: Int
    var mark: BreakdownMark

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(BreakdownPalette.color(colorIndex))
                .frame(width: 10, height: 10)
            Text(label)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if let text = BreakdownPalette.markText(mark) {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }
}

// MARK: - 表示の部品

enum BreakdownPalette {
    private static let colors: [Color] = [
        Color(red: 0.29, green: 0.64, blue: 1.00),
        Color(red: 1.00, green: 0.62, blue: 0.04),
        Color(red: 0.19, green: 0.82, blue: 0.35),
        Color(red: 0.75, green: 0.35, blue: 0.95),
        Color(red: 0.39, green: 0.82, blue: 1.00),
        Color(red: 1.00, green: 0.84, blue: 0.04),
        Color(red: 1.00, green: 0.39, blue: 0.51),
        Color(red: 0.56, green: 0.56, blue: 0.58),
    ]

    static func color(_ index: Int) -> Color { colors[index % colors.count] }

    static func markText(_ mark: BreakdownMark) -> String? {
        switch mark {
        case .none: return nil
        case .reorg: return "再編"
        case .new: return "新規"
        case .ended: return "終了"
        }
    }
}

enum BreakdownFormat {
    static func signedPercent(_ ratio: Double?) -> String {
        guard let ratio else { return "—" }
        return String(format: "%+.1f%%", ratio * 100)
    }

    static func signedPoints(_ points: Double?) -> String {
        guard let points else { return "—" }
        return String(format: "%+.1fpt", points)
    }

    /// 増減は緑・赤。値なしと 0 は文字色。利益（`neutralPositive`）は黒字を文字色のままにし、赤字だけ赤にする。
    static func signColor(_ value: Double?, neutralPositive: Bool = false) -> Color {
        guard let value, value != 0 else { return Theme.text }
        if value < 0 { return Theme.negative }
        return neutralPositive ? Theme.text : Theme.positive
    }
}

/// 年次の積み上げ棒。棒と、年の間のつなぎ（connect）と、棒の中の印（再編・新規・終了）を `Canvas` で描く。
/// 配置は `StackedLayout`（`swift test` 済み）が決める。0 の線は太く明るくする。
private struct StackedBarChart: View {
    var layout: BreakdownLayout
    var accessibilityText: String

    private let chartHeight: CGFloat = 200
    private let labelBand: CGFloat = 22

    var body: some View {
        Canvas { context, size in
            let plotHeight = size.height - labelBand
            func x(_ value: Double) -> CGFloat { CGFloat(value) * size.width }
            func y(_ value: Double) -> CGFloat { CGFloat(value) * plotHeight }

            for ribbon in layout.ribbons {
                var path = Path()
                let midX = (x(ribbon.leftX) + x(ribbon.rightX)) / 2
                path.move(to: CGPoint(x: x(ribbon.leftX), y: y(ribbon.leftTop)))
                path.addCurve(
                    to: CGPoint(x: x(ribbon.rightX), y: y(ribbon.rightTop)),
                    control1: CGPoint(x: midX, y: y(ribbon.leftTop)),
                    control2: CGPoint(x: midX, y: y(ribbon.rightTop)))
                path.addLine(to: CGPoint(x: x(ribbon.rightX), y: y(ribbon.rightBottom)))
                path.addCurve(
                    to: CGPoint(x: x(ribbon.leftX), y: y(ribbon.leftBottom)),
                    control1: CGPoint(x: midX, y: y(ribbon.rightBottom)),
                    control2: CGPoint(x: midX, y: y(ribbon.leftBottom)))
                path.closeSubpath()
                context.fill(path, with: .color(BreakdownPalette.color(ribbon.colorIndex).opacity(0.22)))
            }

            for column in layout.bars {
                for bar in column {
                    let rect = CGRect(x: x(bar.x), y: y(bar.y), width: x(bar.width), height: y(bar.height))
                    context.fill(Path(rect), with: .color(BreakdownPalette.color(bar.colorIndex)))
                    context.stroke(Path(rect), with: .color(Theme.card), lineWidth: 1.5)
                    if let text = BreakdownPalette.markText(bar.mark), rect.height >= 14 {
                        let label = context.resolve(
                            Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.black.opacity(0.78)))
                        context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                    }
                }
            }

            // 0 の線。
            var zero = Path()
            zero.move(to: CGPoint(x: 14, y: plotHeight))
            zero.addLine(to: CGPoint(x: size.width, y: plotHeight))
            context.stroke(zero, with: .color(Theme.text.opacity(0.85)), lineWidth: 1.5)
            context.draw(
                context.resolve(Text("0").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text)),
                at: CGPoint(x: 0, y: plotHeight), anchor: .leading)

            for (index, center) in layout.columnCenters.enumerated() {
                context.draw(
                    context.resolve(
                        Text(layout.columnLabels[index]).font(.caption2).foregroundStyle(Theme.textMuted)),
                    at: CGPoint(x: x(center), y: plotHeight + labelBand / 2 + 2), anchor: .center)
                let top = layout.bars[index].map(\.y).min() ?? 1
                context.draw(
                    context.resolve(
                        Text(Format.autoYen(layout.columnTotals[index])).font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.text)),
                    at: CGPoint(x: x(center), y: y(top) - 9), anchor: .center)
            }
        }
        .frame(height: chartHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}
