import SwiftData
import SwiftUI

struct FundPositionEditView: View {
    var item: WatchedCompany
    var onAddAccount: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quantityText = ""
    @State private var priceText = ""
    @State private var brokerText = ""
    @State private var accountTypeText = ""
    @State private var parseError: String?

    var body: some View {
        Form {
            Section("銘柄") {
                LabeledContent("社名", value: Format.displayName(item.name, fallback: item.code))
                LabeledContent("コード", value: item.code)
                LabeledContent("区分", value: item.kindLabel)
            }

            Section {
                TextField("株数", text: $quantityText)
                    .keyboardType(.decimalPad)
                TextField("取得単価（円/株）", text: $priceText)
                    .keyboardType(.decimalPad)
            } header: {
                Text("保有")
            } footer: {
                Text("株数と取得単価（円/株）の両方が入ると保有、片方だけならウォッチです。本表の百万円は使いません。")
            }

            Section {
                TextField("証券会社", text: $brokerText)
                    .textInputAutocapitalization(.never)
                TextField("口座区分", text: $accountTypeText)
                    .textInputAutocapitalization(.never)
            } header: {
                Text("口座（任意）")
            } footer: {
                Text("特定・NISA などは任意です。空白にできます。計算には使いません。")
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
                    onAddAccount()
                }
            }
        }
        .navigationTitle("保有の編集")
        .navigationBarTitleDisplayMode(.inline)
        .bltChrome()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("閉じる") {
                    if commit() {
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    if commit() {
                        dismiss()
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onDisappear {
            _ = commit()
        }
    }

    private func load() {
        quantityText = string(from: item.quantity)
        priceText = string(from: item.acquisitionPriceYen)
        brokerText = item.broker ?? ""
        accountTypeText = item.accountType ?? ""
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
        item.broker = WatchedCompany.nonEmpty(brokerText)
        item.accountType = WatchedCompany.nonEmpty(accountTypeText)
        parseError = nil
        return true
    }

    private func string(from value: Double?) -> String {
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
