import SwiftUI

struct SettingsView: View {
    #if DEBUG
        @State private var baseURL = APIConfiguration.baseURL.absoluteString
        @State private var issuerURL = APIConfiguration.hapisIssuerURL.absoluteString
        @State private var saveError: String?
    #endif

    var body: some View {
        Form {
            #if DEBUG
                Section("サーバー") {
                    TextField("http://127.0.0.1:3000", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button("保存") { saveBaseURL() }
                    Button("HAPIS 本番") {
                        baseURL = APIConfiguration.productionHAPISGatewayBaseURL.absoluteString
                        APIConfiguration.hapisGatewayBaseURL =
                            APIConfiguration.productionHAPISGatewayBaseURL
                        APIConfiguration.hapisAttestClientMode = .appAttest
                        saveBaseURL()
                    }
                    Button("ローカル") {
                        baseURL = APIConfiguration.defaultBaseURL.absoluteString
                        saveBaseURL()
                    }
                    if let saveError {
                        Text(saveError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                if APIConfiguration.usesHAPISConsumer {
                    Section("HAPIS") {
                        Text(hapisAttestHelp)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        TextField("発行者 URL", text: $issuerURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        Button("発行者 URL を保存") { saveIssuerURL() }
                        Button("トークンを破棄", role: .destructive) {
                            Task { await APIClient.shared.clearHAPISConsumerToken() }
                        }
                    }
                } else {
                    Section {
                        Text("このサーバーは無認証です（loopback / LAN http）。HAPIS の Bearer は設定した HAPIS ゲートウェイのときだけ付きます。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            #endif
        }
        .bltChrome("開発ラボ")
        #if DEBUG
            .onAppear {
                issuerURL = APIConfiguration.hapisIssuerURL.absoluteString
            }
        #endif
    }

    #if DEBUG
        private var hapisAttestHelp: String {
            switch APIConfiguration.hapisAttestClientMode {
            case .stub:
                return "短命の匿名トークンを制御面から自動発行します（クライアント stub mint）。本番 HAPIS は ATTEST_MODE=enforce のため、このままでは mint できません。実機の検索は Release を使います。"
            case .appAttest:
                return "短命の匿名トークンを制御面から自動発行します。mint は App Attest（challenge → attest / assertion）。Debug の App Attest 環境は development です。本番 HAPIS の既定は production。Debug の UserDefaults 上書きはプロセス起動時に読むので、変更後は再起動してください。"
            }
        }

        private func saveBaseURL() {
            if let url = APIConfiguration.validatedBaseURL(from: baseURL) {
                APIConfiguration.baseURL = url
                if APIConfiguration.usesHAPISConsumer(url) {
                    APIConfiguration.hapisGatewayBaseURL = url
                }
                baseURL = url.absoluteString
                saveError = nil
            } else {
                saveError = "http または https の絶対 URL を入力してください"
            }
        }

        private func saveIssuerURL() {
            if let url = APIConfiguration.validatedHAPISIssuerURL(from: issuerURL) {
                APIConfiguration.hapisIssuerURL = url
                issuerURL = url.absoluteString
                saveError = nil
            } else {
                saveError = "発行者 URL は https の origin を入力してください"
            }
        }
    #endif
}
