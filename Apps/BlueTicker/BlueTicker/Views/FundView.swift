import SwiftData
import SwiftUI

struct FundView: View {
    @Query(sort: \WatchedCompany.sortOrder) private var companies: [WatchedCompany]
    @State private var perShareByCode: [String: FundMath.PerShare] = [:]

    var body: some View {
        List {
            Section {
                LabeledContent("ルックスルー利益", value: Format.yenCash(snapshot.lookThroughProfitYen))
                LabeledContent("ルックスルー純資産", value: Format.yenCash(snapshot.lookThroughBookYen))
                LabeledContent("投下資本", value: Format.yenCash(snapshot.investedCapitalYen))
                LabeledContent("ファンドROE", value: Format.percent(snapshot.fundROEPercent))
            } header: {
                Text("ルックスルー")
            } footer: {
                Text(lookThroughFooter)
            }

            if snapshot.tickerTotals.isEmpty {
                Section {
                    Text("銘柄の保有情報から、口座ごとの株数と取得単価を入れると保有になります。")
                        .foregroundStyle(Theme.textMuted)
                }
            } else {
                Section("銘柄別") {
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
                }
            #endif
        }
        .navigationTitle("ファンド")
        .bltChrome()
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

    private var holdings: [WatchedCompany] {
        companies.filter(\.isHolding)
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

    private var lookThroughFooter: String {
        let fy = uniqueFyEnds
        let fyText = fy.isEmpty ? "最新FY" : fy.sorted().map(Format.fy).joined(separator: "・")
        return """
        利益＝最新FY EPS（円/株）×株数。純資産＝BPS（円/株）×株数。投下＝取得単価（円/株）×株数。ROE＝利益÷投下（EPSがある保有のみ）。本表の百万円とは単位が違います。欠測は —。\(fyText)。バージョン \(Self.versionText)
        """
    }

    private var uniqueFyEnds: [String] {
        Array(
            Set(
                holdings.compactMap { perShareByCode[$0.code]?.fyEnd }.filter { !$0.isEmpty }
            ))
    }

    private static var versionText: String {
        let short =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, !build.isEmpty {
            return "\(short) (\(build))"
        }
        return short
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
        return HStack(spacing: 12) {
            CompanyIconView(companyRef(for: total))
            LabeledContent {
                Text(Format.yenCash(total.lookThroughProfitYen))
            } label: {
                Text(
                    "\(Format.displayName(item?.name ?? total.code, fallback: total.code)) \(total.code)"
                )
                Text(
                    "純資産 \(Format.yenCash(total.lookThroughBookYen)) · 投下 \(Format.yenCash(total.investedCapitalYen))"
                )
            }
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
}
