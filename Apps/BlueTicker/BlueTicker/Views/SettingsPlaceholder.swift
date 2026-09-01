import SwiftUI

struct SettingsPlaceholder: View {
    @State private var baseURL = APIConfiguration.baseURL.absoluteString
    @State private var saveError: String?

    var body: some View {
        Form {
            Section("サーバー") {
                TextField("http://127.0.0.1:3000", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("保存") {
                    if let url = APIConfiguration.validatedBaseURL(from: baseURL) {
                        APIConfiguration.baseURL = url
                        baseURL = url.absoluteString
                        saveError = nil
                    } else {
                        saveError = "http または https の絶対 URL を入力してください"
                    }
                }
                if let saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(.red)
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
