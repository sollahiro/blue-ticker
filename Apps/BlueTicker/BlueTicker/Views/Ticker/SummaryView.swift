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

    private func summaryTable(_ response: FinancialsResponse) -> some View {
        let years = Format.chronological(response.years)
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("金額は桁に応じて百万円・億円・十億円・兆円。比率は%。ネットD/Eは倍。古い年度が左です。")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
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
                            Text(row.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.text)
                                .frame(minWidth: 88, alignment: .leading)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            ForEach(years) { year in
                                Text(row.format(year))
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

    func format(_ year: FinancialsYear) -> String {
        switch self {
        case .sales: Format.autoYen(year.sales)
        case .grossProfit: Format.autoYen(year.grossProfit)
        case .grossMargin: Format.percent(year.grossProfitMargin)
        case .operatingProfit: Format.autoYen(year.operatingProfit)
        case .operatingMargin: Format.percent(year.operatingMargin)
        case .netProfit: Format.autoYen(year.netProfit)
        case .roic: Format.percent(year.roic)
        case .roe: Format.percent(year.roe)
        case .netCash: Format.autoYen(year.netCash)
        case .netDe: Format.times(year.netDe)
        case .cfo: Format.autoYen(year.cfo)
        case .cfi: Format.autoYen(year.cfi)
        case .equityRatio: Format.percent(Format.equityRatio(year))
        case .currentRatio: Format.percent(Format.currentRatio(year))
        case .fixedRatio: Format.percent(Format.fixedRatio(year))
        }
    }

    func color(_ year: FinancialsYear) -> Color {
        switch self {
        case .operatingProfit:
            return deficitColor(year.operatingProfit)
        case .netProfit:
            return deficitColor(year.netProfit)
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
