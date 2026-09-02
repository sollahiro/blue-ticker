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
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("").frame(width: 72, alignment: .leading)
                    Text("売上高").gridHeader()
                    Text("営業利益").gridHeader()
                    Text("純利益").gridHeader()
                }
                ForEach(response.years) { year in
                    GridRow {
                        Text(Format.fy(year.fyEnd))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                        Text(Format.millionYen(year.sales)).gridCell()
                        Text(Format.millionYen(year.operatingProfit)).gridCell()
                        Text(Format.millionYen(year.netProfit)).gridCell()
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

private extension Text {
    func gridHeader() -> some View {
        self.font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textMuted)
            .frame(width: 88, alignment: .trailing)
    }

    func gridCell() -> some View {
        self.font(.subheadline.monospacedDigit())
            .foregroundStyle(Theme.text)
            .frame(width: 88, alignment: .trailing)
    }
}
