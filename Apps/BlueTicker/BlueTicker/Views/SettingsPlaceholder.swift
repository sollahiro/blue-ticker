import SwiftUI

struct SettingsPlaceholder: View {
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = APIConfiguration.baseURL.absoluteString

    var body: some View {
        NavigationStack {
            Form {
                Section("サーバー") {
                    TextField("http://127.0.0.1:3000", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button("保存") {
                        if let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            APIConfiguration.baseURL = url
                        }
                        dismiss()
                    }
                }
                Section {
                    Text("設定の中身は未決です。Service Token はアプリに入れません。開発はローカル無認証が既定です。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .bltChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
