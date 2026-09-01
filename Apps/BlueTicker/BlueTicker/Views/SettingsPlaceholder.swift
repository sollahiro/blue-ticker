import SwiftUI

struct SettingsPlaceholder: View {
    @State private var baseURL = APIConfiguration.baseURL.absoluteString

    var body: some View {
        Form {
            Section("サーバー") {
                TextField("http://127.0.0.1:3000", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("保存") {
                    if let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        APIConfiguration.baseURL = url
                    }
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
    }
}
