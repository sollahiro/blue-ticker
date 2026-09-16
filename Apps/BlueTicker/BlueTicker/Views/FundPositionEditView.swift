import SwiftData
import SwiftUI

struct TickerHoldingsView: View {
    var code: String
    var onAddAccount: () -> WatchedCompany

    @Query(sort: \WatchedCompany.sortOrder) private var watched: [WatchedCompany]
    @Environment(\.dismiss) private var dismiss
    @State private var addedBlankIDs: Set<PersistentIdentifier> = []

    var body: some View {
        Form {
            if filledRows.count >= 2 {
                Section {
                    LabeledContent("合計保有数量", value: Format.shares(lot.quantity))
                    LabeledContent("平均取得単価", value: Format.yenPerShare(lot.averageAcquisitionYen))
                }
            }
            ForEach(Array(rows.enumerated()), id: \.element.persistentModelID) { index, item in
                HoldingsAccountGroup(
                    item: item,
                    heading: rows.count >= 2 ? (item.accountCaption ?? "口座 \(index + 1)") : nil
                )
            }
            Section {
                Button("口座を追加") {
                    let created = onAddAccount()
                    addedBlankIDs.insert(created.persistentModelID)
                }
            } footer: {
                Text("株数と取得単価の両方が入るとファンド明細に出ます。")
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle("保有情報")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .bltChrome()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完了") { dismiss() }
            }
        }
    }

    private var matching: [WatchedCompany] {
        watched.filter { $0.code == code }
    }

    private var filledRows: [WatchedCompany] {
        matching.filter { !$0.isBlankHoldingsRow }
    }

    private var rows: [WatchedCompany] {
        matching.filter { item in
            if !item.isBlankHoldingsRow { return true }
            return filledRows.isEmpty || addedBlankIDs.contains(item.persistentModelID)
        }
    }

    private var lot: (quantity: Double?, averageAcquisitionYen: Double?) {
        FundMath.lotAverage(
            positions: filledRows.map {
                FundMath.Position(
                    id: String(describing: $0.persistentModelID),
                    code: $0.code,
                    quantity: $0.quantity,
                    acquisitionPriceYen: $0.acquisitionPriceYen
                )
            }
        )
    }
}

private struct HoldingsAccountGroup: View {
    @Bindable var item: WatchedCompany
    var heading: String?
    @State private var quantityText: String
    @State private var priceText: String
    @State private var parseError: String?

    init(item: WatchedCompany, heading: String?) {
        self.item = item
        self.heading = heading
        _quantityText = State(initialValue: Self.string(from: item.quantity))
        _priceText = State(initialValue: Self.string(from: item.acquisitionPriceYen))
    }

    var body: some View {
        Section {
            Picker("証券会社", selection: optionalChoice($item.broker)) {
                Text("未選択").tag(String?.none)
                ForEach(
                    WatchedCompany.choices(WatchedCompany.brokerChoices, including: item.broker),
                    id: \.self
                ) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            .pickerStyle(.menu)
            Picker("口座", selection: optionalChoice($item.accountType)) {
                Text("未選択").tag(String?.none)
                ForEach(
                    WatchedCompany.choices(
                        WatchedCompany.accountTypeChoices, including: item.accountType),
                    id: \.self
                ) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            .pickerStyle(.menu)
            TextField("株数", text: $quantityText)
                .keyboardType(.decimalPad)
            TextField("取得単価（円/株）", text: $priceText)
                .keyboardType(.decimalPad)
            if let parseError {
                Text(parseError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            if let heading {
                Text(heading)
            }
        }
        .onChange(of: quantityText) { _, _ in _ = commit() }
        .onChange(of: priceText) { _, _ in _ = commit() }
        .onDisappear { _ = commit() }
    }

    /// 空文字は未選択。`tag("")` だと Picker が選択を戻す。
    private func optionalChoice(_ value: Binding<String?>) -> Binding<String?> {
        Binding(
            get: { WatchedCompany.nonEmpty(value.wrappedValue) },
            set: { value.wrappedValue = WatchedCompany.nonEmpty($0) }
        )
    }

    @discardableResult
    private func commit() -> Bool {
        if let quantity = parseOptionalDouble(quantityText) {
            item.quantity = quantity
        } else if quantityText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.quantity = nil
            parseError = nil
        } else {
            parseError = "株数は数値で入力してください"
            return false
        }
        if let price = parseOptionalDouble(priceText) {
            item.acquisitionPriceYen = price
        } else if priceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.acquisitionPriceYen = nil
            parseError = nil
        } else {
            parseError = "取得単価は円/株の数値で入力してください"
            return false
        }
        parseError = nil
        return true
    }

    private static func string(from value: Double?) -> String {
        guard let value else { return "" }
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    private func parseOptionalDouble(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        if trimmed.isEmpty { return nil }
        return Double(trimmed)
    }
}
