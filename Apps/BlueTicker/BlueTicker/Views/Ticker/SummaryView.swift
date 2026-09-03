import SwiftUI

struct SummaryView: View {
    var code: String
    @State private var response: FinancialsResponse?
    @State private var errorMessage: String?

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

    private func commonScale(for response: FinancialsResponse) -> Format.YenScale? {
        let values = response.years.flatMap { [
            $0.sales, $0.grossProfit, $0.operatingProfit, $0.netProfit,
        ] }
        return Format.commonScale(for: values)
    }

    private func summaryTable(_ response: FinancialsResponse) -> some View {
        let years = Format.chronological(response.years)
        let scale = commonScale(for: response)
        let unit = scale?.unit ?? ""
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                            .frame(minWidth: 88, alignment: .leading)
                        ForEach(years) { year in
                            Text(Format.fy(year.fyEnd))
                                .gridHeader()
                        }
                    }
                    ForEach(SummaryRow.allCases) { row in
                        GridRow {
                            Text(row.displayTitle(unit: unit))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.text)
                                .frame(minWidth: 88, alignment: .leading)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            ForEach(years) { year in
                                Text(row.format(year, scale: scale))
                                    .gridCell(color: row.color(year))
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
        .padding(16)
    }

    private func load() async {
        do {
            response = try await APIClient.shared.financials(code: code)
            errorMessage = nil
        } catch APIClientError.http(let status, let message) where status == 404 {
            errorMessage = message.isEmpty ? "財務データは未集計です" : message
        } catch {
            errorMessage = error.localizedDescription
        }
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
    case roic
    case roe
    case netCash
    case netDe
    case cfo
    case cfi
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
        case .roic: "ROIC"
        case .roe: "ROE"
        case .netCash: "ネットキャッシュ"
        case .netDe: "ネットD/E"
        case .cfo: "営業CF"
        case .cfi: "投資CF"
        case .equityRatio: "自己資本比率"
        case .currentRatio: "流動比率"
        case .fixedRatio: "固定比率"
        }
    }

    func displayTitle(unit: String) -> String {
        let moneyRows: [SummaryRow] = [.sales, .grossProfit, .operatingProfit, .netProfit]
        if moneyRows.contains(self) && !unit.isEmpty {
            return "\(title)（\(unit)）"
        }
        return title
    }

    func format(_ year: FinancialsYear, scale: Format.YenScale?) -> String {
        switch self {
        case .sales: return yenString(year.sales, scale: scale)
        case .grossProfit: return yenString(year.grossProfit, scale: scale)
        case .grossMargin: return Format.percent(year.grossProfitMargin)
        case .operatingProfit: return yenString(year.operatingProfit, scale: scale)
        case .operatingMargin: return Format.percent(year.operatingMargin)
        case .netProfit: return yenString(year.netProfit, scale: scale)
        case .roic: return Format.percent(year.roic)
        case .roe: return Format.percent(year.roe)
        case .netCash: return Format.autoYen(year.netCash)
        case .netDe: return Format.times(year.netDe)
        case .cfo: return Format.autoYen(year.cfo)
        case .cfi: return Format.autoYen(year.cfi)
        case .equityRatio: return Format.percent(Format.equityRatio(year))
        case .currentRatio: return Format.percent(Format.currentRatio(year))
        case .fixedRatio: return Format.percent(Format.fixedRatio(year))
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
            .frame(maxWidth: .infinity, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    func gridCell(color: Color) -> some View {
        self.font(.caption.monospacedDigit())
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
