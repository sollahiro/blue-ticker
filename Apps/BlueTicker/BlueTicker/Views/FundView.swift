import SwiftData
import SwiftUI

struct FundView: View {
    @Query(sort: \WatchedCompany.sortOrder) private var companies: [WatchedCompany]
    @State private var perShareByCode: [String: FundMath.PerShare] = [:]

    var body: some View {
        List {
            Section {
                LabeledContent("純利益", value: Format.yenCash(snapshot.lookThroughProfitYen))
                LabeledContent("純資産", value: Format.yenCash(snapshot.lookThroughBookYen))
                LabeledContent("投資元本", value: Format.yenCash(snapshot.investedCapitalYen))
                LabeledContent("ファンドROE", value: Format.percent(snapshot.fundROEPercent))
            } header: {
                Text("保有株数に応じた業績")
            }

            if snapshot.tickerTotals.isEmpty {
                Section("あなたの保有している企業") {
                    Text("銘柄画面の保有情報で、株数と取得単価を入れるとここに出ます。")
                        .foregroundStyle(Theme.textMuted)
                }
            } else {
                Section("あなたの保有している企業") {
                    ForEach(snapshot.tickerTotals, id: \.code) { total in
                        NavigationLink(value: companyRef(for: total)) {
                            tickerTotalRow(total)
                        }
                        .listRowBackground(Theme.elevated)
                    }
                }
            }

            #if DEBUG
                Section("開発ラボ") {
                    NavigationLink("サーバー / Access / HAPIS") {
                        SettingsView()
                    }
                    NavigationLink(value: Self.debugTicker) {
                        Text("銘柄面（7203）")
                    }
                }
            #endif

            Section {
                VersionMarkFooter()
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
        }
        .bltChrome("ファンド")
        .onAppear {
            WatchedCompany.repairSortOrderIfNeeded(companies)
        }
        .task(id: companies.map(\.code).joined(separator: ",")) {
            await loadPerShare()
        }
    }

    private var snapshot: FundMath.Snapshot {
        FundMath.snapshot(positions: fundPositions, perShareByCode: perShareByCode)
    }

    private var fundPositions: [FundMath.Position] {
        companies.map {
            FundMath.Position(
                id: String(describing: $0.persistentModelID),
                code: $0.code,
                quantity: $0.quantity,
                acquisitionPriceYen: $0.acquisitionPriceYen
            )
        }
    }

    private func companyRef(for total: FundMath.TickerTotal) -> CompanyRef {
        let item = companies.first { $0.code == total.code }
        return CompanyRef(
            code: total.code,
            name: item?.name ?? total.code,
            sector: item?.sector ?? "",
            iconURL: item?.iconURL
        )
    }

    private func tickerTotalRow(_ total: FundMath.TickerTotal) -> some View {
        let item = companies.first { $0.code == total.code }
        let name = Format.displayName(item?.name ?? total.code, fallback: total.code)
        return HStack(alignment: .top, spacing: 12) {
            CompanyIconView(companyRef(for: total))
            VStack(alignment: .leading, spacing: 6) {
                Text("\(name) \(total.code)")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                metricRow("純利益", Format.yenCash(total.lookThroughProfitYen))
                metricRow("純資産", Format.yenCash(total.lookThroughBookYen))
                metricRow("投資元本", Format.yenCash(total.investedCapitalYen))
            }
        }
        .padding(.vertical, 4)
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.text)
        }
    }

    private func loadPerShare() async {
        var map: [String: FundMath.PerShare] = [:]
        for code in Set(companies.map(\.code)) {
            map[code] = await Self.perShare(for: code)
        }
        perShareByCode = map
    }

    private static func perShare(for code: String) async -> FundMath.PerShare {
        if let cached = await APIClient.shared.cachedFinancials(code: code) {
            return slice(cached)
        }
        if let loaded = try? await APIClient.shared.financials(code: code) {
            return slice(loaded)
        }
        return FundMath.PerShare()
    }

    private static func slice(_ response: FinancialsResponse) -> FundMath.PerShare {
        guard let year = Format.latestYear(response.years) else {
            return FundMath.PerShare()
        }
        return FundMath.PerShare(fyEnd: year.fyEnd, epsYen: year.eps, bpsYen: year.bps)
    }

    #if DEBUG
        /// 通信なしで銘柄面 → 保有情報まで行く。リストやフィードには入れない。
        static let debugTicker = CompanyRef(
            code: "7203", name: "トヨタ自動車", sector: "輸送用機器")
    #endif
}
