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

    /// 直近 5 年（取れる分だけ）。
    static let years = 5

    /// 失敗や 404 はカードを出さないだけ（分析ページ全体のエラーにしない）。
    /// 取れたところから `update` で順に渡す（セグメントの棒 → 利益 → 地域）。全部そろうのを待たない。
    static func load(code: String, update: @MainActor (BreakdownModel) -> Void) async {
        // 利益（最新期）は積み上げの取得を待たずに始める。
        async let detail = try? APIClient.shared.breakdown(code: code, axis: "segment")
        guard let waterfall = try? await APIClient.shared.segmentWaterfall(code: code, years: years) else {
            return
        }
        // 再編で統合された旧区分は、過去の年も 1 本にまとめる（流れを追う必要はない）。
        let columns = BreakdownBuilder.collapsingReorgs(
            BreakdownBuilder.segmentColumns(waterfall) { Format.fy($0.fyEnd) })
        // 区分が 1 つだけでは構成も推移も見えない。
        guard let latest = columns.last, latest.items.count >= 2 else { return }
        let layout = StackedLayout.make(columns: columns)
        func segmentModel(_ profitByKey: [String: Double]) -> SegmentCardModel {
            SegmentCardModel(
                columns: columns, layout: layout,
                rows: BreakdownSummary.segmentRows(columns: columns, layout: layout, profitByKey: profitByKey))
        }

        // 地域は利益を待たずに始める。年次推移の API（地域名を正規化済み）が取れなければ、年ごとの内訳から組む。
        async let regionWaterfall = try? APIClient.shared.geographyWaterfall(code: code, years: years)

        // 1 段目: 棒と、利益なしの表。
        await update(BreakdownModel(segment: segmentModel([:]), region: nil))

        // 2 段目: 利益。地域がセグメントそのものの会社は、地域カードを出さない。
        let detailRows = await detail?.breakdown?.rows ?? []
        var profitByKey: [String: Double] = [:]
        for row in detailRows {
            if let profit = row.profit?.value { profitByKey[row.segmentKey ?? row.label] = profit }
        }
        let segment = segmentModel(profitByKey)
        await update(BreakdownModel(segment: segment, region: nil))

        // 3 段目: 地域。
        let geographic = detailRows.contains { $0.segmentBasis == "geographic" }
        var region: RegionCardModel?
        if !geographic {
            if let response = await regionWaterfall,
                let model = regionModel(
                    columns: BreakdownBuilder.geographyColumns(response) { Format.fy($0.fyEnd) })
            {
                region = model
            } else {
                let responses = await loadRegionResponses(code: code, waterfall: waterfall)
                region = regionModel(waterfall: waterfall, responses: responses)
            }
        }
        await update(BreakdownModel(segment: segment, region: region))
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
        return regionModel(columns: columns)
    }

    private static func regionModel(columns: [BreakdownColumnInput]) -> RegionCardModel? {
        guard let latest = columns.last, latest.items.count >= 2 else { return nil }
        let layout = StackedLayout.make(columns: columns)
        return RegionCardModel(
            columns: columns, layout: layout, rows: BreakdownSummary.shareRows(columns: columns, layout: layout))
    }
}

// MARK: - カード

private struct SegmentCard: View {
    var model: SegmentCardModel

    private let profitWidth: CGFloat = 88
    private let marginWidth: CGFloat = 52

    /// 利益の列は 1 つの単位にそろえる（行ごとに億円・百万円が混ざらない）。
    private var profitScale: Format.YenScale? {
        Format.commonScale(for: model.rows.map(\.profit))
    }

    private func profitText(_ profit: Double?) -> String {
        guard let profit, let scale = profitScale else { return "—" }
        let scaled = profit / scale.divisor
        // 単位に比べて小さい値は小数 1 桁まで出す（0 に丸めて見えなくしない）。
        let small = model.rows.contains { row in
            guard let value = row.profit else { return false }
            return value != 0 && abs(value / scale.divisor) < 10
        }
        return Format.groupedNumber(scaled, fractionDigits: small ? max(scale.fractionDigits, 1) : scale.fractionDigits)
    }

    /// 利益率。小数 1 桁で 0 になる値は符号を付けない（-0.0% を出さない）。
    private func marginText(_ ratio: Double?) -> String {
        guard let ratio else { return "—" }
        let percent = (ratio * 1000).rounded() / 10
        return Format.percent(percent == 0 ? 0 : ratio * 100)
    }

    var body: some View {
        AnalysisCard(title: "セグメント別売上高") {
            StackedBarChart(layout: model.layout, accessibilityText: "セグメント別の外部売上の年次推移")
            segmentTable
            AnalysisNote(text: "棒は外部売上（\(model.layout.unitName)）。利益は最新期のセグメント利益（消去・全社を除く）です。")
        }
    }

    /// 長いセグメント名は折り返して全部見せる。数字の列は幅を固定して左に揃える。
    private var segmentTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.layout.columnLabels.last ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(profitScale.map { "利益（\($0.unit)）" } ?? "利益").frame(width: profitWidth, alignment: .leading)
                Text("利益率").frame(width: marginWidth, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(Theme.textMuted)
            ForEach(model.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    SeriesLabel(label: row.label, colorIndex: row.colorIndex, mark: row.mark)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(profitText(row.profit))
                        .foregroundStyle(BreakdownFormat.signColor(row.profit, neutralPositive: true))
                        .frame(width: profitWidth, alignment: .leading)
                    Text(marginText(row.margin))
                        .foregroundStyle(Theme.text)
                        .frame(width: marginWidth, alignment: .leading)
                }
                .font(.footnote.monospacedDigit())
            }
        }
    }
}

private struct RegionCard: View {
    var model: RegionCardModel

    var body: some View {
        AnalysisCard(title: "地域別売上高") {
            StackedBarChart(layout: model.layout, accessibilityText: "地域別売上の年次推移")
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.layout.columnLabels.last ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("構成比").frame(width: 56, alignment: .trailing)
                    Text("前年差").frame(width: 64, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
                ForEach(model.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        SeriesLabel(label: row.label, colorIndex: row.colorIndex, mark: .none)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Format.percent(row.share * 100, digits: 0))
                            .foregroundStyle(Theme.text)
                            .frame(width: 56, alignment: .trailing)
                        Text(BreakdownFormat.signedPoints(row.deltaPoints))
                            .foregroundStyle(BreakdownFormat.signColor(row.deltaPoints))
                            .frame(width: 64, alignment: .trailing)
                    }
                    .font(.footnote.monospacedDigit())
                }
            }
            AnalysisNote(text: "棒は地域別売上高（\(model.layout.unitName)）。区分が前年と違う行の前年差は出しません。")
        }
    }
}

private struct SeriesLabel: View {
    var label: String
    var colorIndex: Int
    var mark: BreakdownMark

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(BreakdownPalette.color(colorIndex))
                .frame(width: 10, height: 10)
            Text(label)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let text = BreakdownPalette.markText(mark) {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }
}

// MARK: - 表示の部品

extension BreakdownLayout {
    /// 縦軸の単位名（最大の合計から決める。例: 億円）。
    var unitName: String {
        Format.commonScale(for: [columnTotals.max()])?.unit ?? "円"
    }
}

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
        // 「新規」「終了」は断定しない（地域名の表記ゆれや再編で出がち）ので棒の中には出さない。
        case .new, .ended: return nil
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

    private let chartHeight: CGFloat = 220
    private let baseLabelBand: CGFloat = 22
    /// 年ラベルの下に「再編」を出す年があるときだけ、下の余白を広げる。
    private var labelBand: CGFloat { layout.columnReorged.contains(true) ? baseLabelBand + 12 : baseLabelBand }
    /// 縦軸の文字を置く左の余白。
    private let axisInset: CGFloat = 40

    var body: some View {
        Canvas { context, size in
            let plotHeight = size.height - labelBand
            let plotWidth = size.width - axisInset
            let totalUnit = Format.commonScale(for: [layout.columnTotals.max()])
            func x(_ value: Double) -> CGFloat { axisInset + CGFloat(value) * plotWidth }
            func w(_ value: Double) -> CGFloat { CGFloat(value) * plotWidth }
            func y(_ value: Double) -> CGFloat { CGFloat(value) * plotHeight }

            // 目盛り線（他のグラフと同じ破線・色）と縦軸の文字（共通の単位、単位名は注記）。
            let maxTotal = layout.columnTotals.max() ?? 0
            if maxTotal > 0 {
                let scale = (1 - layout.headroom) / maxTotal
                let unit = Format.commonScale(for: [maxTotal])
                for tick in NiceTicks.make(lower: 0, upper: maxTotal) {
                    let position = 1 - tick * scale
                    guard position >= 0, position <= 1 else { continue }
                    var line = Path()
                    line.move(to: CGPoint(x: axisInset, y: y(position)))
                    line.addLine(to: CGPoint(x: size.width, y: y(position)))
                    context.stroke(line, with: .color(ChartStyle.gridColor), style: ChartStyle.grid)
                    let text = unit.map { Format.scaledYen(tick, scale: $0) } ?? Format.autoYen(tick)
                    context.draw(
                        context.resolve(Text(text).font(.caption2).foregroundStyle(Theme.textMuted)),
                        at: CGPoint(x: axisInset - 6, y: y(position)), anchor: .trailing)
                }
            }

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
                // 再編の塊のつなぎ（色なし）は中立色で、系列のつなぎよりさらに薄く。
                let base = ribbon.colorIndex < 0 ? Theme.textMuted : BreakdownPalette.color(ribbon.colorIndex)
                context.fill(path, with: .color(base.opacity(ribbon.colorIndex < 0 ? 0.16 : 0.22)))
            }

            for column in layout.bars {
                for bar in column {
                    let rect = CGRect(x: x(bar.x), y: y(bar.y), width: w(bar.width), height: y(bar.height))
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
            zero.move(to: CGPoint(x: axisInset, y: plotHeight))
            zero.addLine(to: CGPoint(x: size.width, y: plotHeight))
            context.stroke(zero, with: .color(Theme.text.opacity(0.85)), lineWidth: 1.5)

            for (index, center) in layout.columnCenters.enumerated() {
                context.draw(
                    context.resolve(
                        Text(layout.columnLabels[index]).font(.caption2).foregroundStyle(Theme.textMuted)),
                    at: CGPoint(x: x(center), y: plotHeight + baseLabelBand / 2 + 2), anchor: .center)
                if index < layout.columnReorged.count, layout.columnReorged[index] {
                    context.draw(
                        context.resolve(
                            Text("再編").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.textMuted.opacity(0.8))),
                        at: CGPoint(x: x(center), y: plotHeight + baseLabelBand + 6), anchor: .center)
                }
                let top = layout.bars[index].map(\.y).min() ?? 1
                context.draw(
                    context.resolve(
                        Text(totalUnit.map { Format.scaledYen(layout.columnTotals[index], scale: $0) } ?? Format.autoYen(layout.columnTotals[index])).font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.text)),
                    at: CGPoint(x: x(center), y: y(top) - 9), anchor: .center)
            }
        }
        .frame(height: chartHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}
