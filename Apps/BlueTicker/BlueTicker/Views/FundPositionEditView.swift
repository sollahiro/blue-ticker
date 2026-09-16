import SwiftData
import SwiftUI

struct FundPositionEditView: View {
    @State private var current: WatchedCompany
    var onAddAccount: () -> WatchedCompany

    @Environment(\.dismiss) private var dismiss
    @State private var quantityText = ""
    @State private var priceText = ""
    @State private var parseError: String?

    init(item: WatchedCompany, onAddAccount: @escaping () -> WatchedCompany) {
        _current = State(initialValue: item)
        self.onAddAccount = onAddAccount
        _quantityText = State(initialValue: Self.string(from: item.quantity))
        _priceText = State(initialValue: Self.string(from: item.acquisitionPriceYen))
    }

    var body: some View {
        @Bindable var model = current
        Form {
            Section("銘柄") {
                LabeledContent("社名", value: Format.displayName(current.name, fallback: current.code))
                LabeledContent("コード", value: current.code)
            }

            Section {
                Picker("証券会社", selection: optionalChoice($model.broker)) {
                    Text("未選択").tag(String?.none)
                    ForEach(
                        WatchedCompany.choices(WatchedCompany.brokerChoices, including: current.broker),
                        id: \.self
                    ) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .pickerStyle(.menu)
                Picker("口座", selection: optionalChoice($model.accountType)) {
                    Text("未選択").tag(String?.none)
                    ForEach(
                        WatchedCompany.choices(
                            WatchedCompany.accountTypeChoices, including: current.accountType),
                        id: \.self
                    ) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("口座（任意）")
            } footer: {
                Text("未選択のままでも、この行に株数を入れられます。計算には使いません。")
            }

            Section {
                TextField("株数", text: $quantityText)
                    .keyboardType(.decimalPad)
                TextField("取得単価（円/株）", text: $priceText)
                    .keyboardType(.decimalPad)
            } header: {
                Text("この口座の保有")
            } footer: {
                Text("株数は口座ごとです。株数と取得単価の両方が入るとファンド明細に出ます。")
            }

            if let parseError {
                Section {
                    Text(parseError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("同じ銘柄を別口座で追加") {
                    guard commit() else { return }
                    current = onAddAccount()
                    loadAmounts()
                }
            }
        }
        .navigationTitle("保有情報")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .bltChrome()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完了") {
                    if commit() {
                        dismiss()
                    }
                }
            }
        }
        .onDisappear {
            _ = commit()
        }
    }

    private func loadAmounts() {
        quantityText = Self.string(from: current.quantity)
        priceText = Self.string(from: current.acquisitionPriceYen)
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
            current.quantity = quantity
        } else if quantityText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.quantity = nil
            parseError = nil
        } else {
            parseError = "株数は数値で入力してください"
            return false
        }
        if let price = parseOptionalDouble(priceText) {
            current.acquisitionPriceYen = price
        } else if priceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.acquisitionPriceYen = nil
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

struct TickerAccountListView: View {
    var code: String
    var onAddAccount: () -> WatchedCompany

    @Query(sort: \WatchedCompany.sortOrder) private var watched: [WatchedCompany]
    @State private var editingID: PersistentIdentifier?

    var body: some View {
        List {
            if rows.count >= 2 {
                Section {
                    LabeledContent("合計保有数量", value: Format.shares(lot.quantity))
                    LabeledContent("平均取得単価", value: Format.yenPerShare(lot.averageAcquisitionYen))
                }
            }
            Section {
                ForEach(rows) { item in
                    Button {
                        editingID = item.persistentModelID
                    } label: {
                        accountRow(item)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.elevated)
                }
                Button("口座を追加") {
                    let created = onAddAccount()
                    editingID = created.persistentModelID
                }
            } header: {
                if rows.count >= 2 {
                    Text("口座")
                }
            }
        }
        .navigationTitle("保有情報")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .bltChrome()
        .navigationDestination(item: $editingID) { id in
            if let item = rows.first(where: { $0.persistentModelID == id }) {
                FundPositionEditView(item: item, onAddAccount: onAddAccount)
            }
        }
    }

    private var rows: [WatchedCompany] {
        watched.filter { $0.code == code && !$0.isBlankHoldingsRow }
    }

    private var lot: (quantity: Double?, averageAcquisitionYen: Double?) {
        FundMath.lotAverage(
            positions: rows.map {
                FundMath.Position(
                    id: String(describing: $0.persistentModelID),
                    code: $0.code,
                    quantity: $0.quantity,
                    acquisitionPriceYen: $0.acquisitionPriceYen
                )
            }
        )
    }

    private func accountRow(_ item: WatchedCompany) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.shares(item.quantity))
                Text(Format.yenPerShare(item.acquisitionPriceYen))
            }
        } label: {
            if let caption = item.accountCaption {
                Text(caption)
            }
        }
    }
}
