import SwiftData
import SwiftUI

struct FundView: View {
    @Query(sort: \WatchedCompany.sortOrder) private var companies: [WatchedCompany]
    @Environment(\.modelContext) private var modelContext
    @State private var perShareByCode: [String: FundMath.PerShare] = [:]
    @State private var editing: WatchedCompany?

    var body: some View {
        List {
            Section {
                metricRow(
                    title: "ルックスルー利益",
                    value: Format.yenCash(snapshot.lookThroughProfitYen),
                    detail: "最新FY EPS（円/株）×株数"
                )
                metricRow(
                    title: "ルックスルー純資産",
                    value: Format.yenCash(snapshot.lookThroughBookYen),
                    detail: "最新FY BPS（円/株）×株数"
                )
                metricRow(
                    title: "投下資本",
                    value: Format.yenCash(snapshot.investedCapitalYen),
                    detail: "取得単価（円/株）×株数"
                )
                metricRow(
                    title: "ファンドROE",
                    value: Format.percent(snapshot.fundROEPercent),
                    detail: "ルックスルー利益 ÷ 投下資本"
                )
            } header: {
                Text("ルックスルー")
            } footer: {
                Text(lookThroughFooter)
            }

            if snapshot.tickerTotals.count > 1 {
                Section("銘柄別") {
                    ForEach(snapshot.tickerTotals, id: \.code) { total in
                        tickerTotalRow(total)
                    }
                }
            }

            Section {
                if companies.isEmpty {
                    Text("銘柄画面からリストに追加し、ここで株数と取得単価を入れると保有になります。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                } else {
                    ForEach(companies) { item in
                        HStack(alignment: .center, spacing: 8) {
                            NavigationLink(value: CompanyRef(item)) {
                                fundRow(item)
                            }
                            Button {
                                editing = item
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("保有を編集")
                        }
                        .listRowBackground(Theme.elevated)
                    }
                    .onDelete(perform: delete)
                }
            } header: {
                Text("明細")
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
        .sheet(item: $editing) { item in
            NavigationStack {
                FundPositionEditView(item: item) {
                    addAccount(from: item)
                }
            }
        }
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

    private var lookThroughFooter: String {
        let fy = uniqueFyEnds
        let fyText = fy.isEmpty ? "最新FY" : fy.sorted().map(Format.fy).joined(separator: "・")
        return """
        一株は円/株、合計は円です。有報本表の百万円とは単位が違います。EPS/BPS 欠測は — で合計から外します。\(fyText)。バージョン \(Self.versionText)
        """
    }

    private var uniqueFyEnds: [String] {
        Array(
            Set(
                companies.compactMap { perShareByCode[$0.code]?.fyEnd }.filter { !$0.isEmpty }
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

    private func metricRow(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(value)
                    .font(.headline)
                    .monospacedDigit()
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
        }
        .listRowBackground(Theme.elevated)
    }

    private func tickerTotalRow(_ total: FundMath.TickerTotal) -> some View {
        let name = companies.first { $0.code == total.code }?.name ?? total.code
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(Format.displayName(name, fallback: total.code)) \(total.code)")
                .font(.subheadline.weight(.semibold))
            HStack {
                labeled("利益", Format.yenCash(total.lookThroughProfitYen))
                labeled("純資産", Format.yenCash(total.lookThroughBookYen))
                labeled("投下", Format.yenCash(total.investedCapitalYen))
            }
            .font(.caption)
        }
        .listRowBackground(Theme.elevated)
    }

    private func fundRow(_ item: WatchedCompany) -> some View {
        let share = perShareByCode[item.code] ?? FundMath.PerShare()
        let metrics = FundMath.rowMetrics(
            position: FundMath.Position(
                id: String(describing: item.persistentModelID),
                code: item.code,
                quantity: item.quantity,
                acquisitionPriceYen: item.acquisitionPriceYen
            ),
            perShare: share
        )
        return VStack(alignment: .leading, spacing: 6) {
            CompanyRowView(
                company: CompanyRef(item),
                caption: item.accountCaption,
                kindLabel: item.kindLabel
            )
            if metrics.isHolding {
                HStack {
                    labeled("利益", Format.yenCash(metrics.lookThroughProfitYen))
                    labeled("純資産", Format.yenCash(metrics.lookThroughBookYen))
                    labeled("投下", Format.yenCash(metrics.investedCapitalYen))
                }
                .font(.caption)
            } else {
                Text("株数と取得単価（円/株）を入れると保有になります")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .foregroundStyle(Theme.text)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func delete(at offsets: IndexSet) {
        let removed = offsets.map { companies[$0] }
        let removedCodes = Set(removed.map(\.code))
        for item in removed {
            modelContext.delete(item)
        }
        let remaining = companies.filter { item in
            !removed.contains { $0.persistentModelID == item.persistentModelID }
        }
        for code in removedCodes where !remaining.contains(where: { $0.code == code }) {
            Task { await APIClient.shared.unpinCode(code) }
        }
    }

    private func addAccount(from item: WatchedCompany) {
        let copy = item.duplicateAccountRow(
            sortOrder: WatchedCompany.nextSortOrder(among: companies)
        )
        modelContext.insert(copy)
        editing = copy
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
