import SwiftUI

struct SettingsPlaceholder: View {
    @State private var baseURL = APIConfiguration.baseURL.absoluteString
    @State private var saveError: String?
    @State private var showLogin = false
    @State private var loginStatus = LoginStatus.read()
    @State private var pastedJWT = ""
    @State private var pasteError: String?

    var body: some View {
        Form {
            Section("サーバー") {
                TextField("http://127.0.0.1:3000", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("保存") { saveBaseURL() }
                Button("本番サーバー") {
                    baseURL = APIConfiguration.productionBaseURL.absoluteString
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
            if APIConfiguration.usesAccess {
                Section("認証") {
                    Text(loginStatus.line)
                    Button("ログイン") { showLogin = true }
                    if loginStatus.hasJWT {
                        Button("ログアウト", role: .destructive) {
                            AccessSession.clear(for: APIConfiguration.baseURL)
                            loginStatus = LoginStatus.read()
                        }
                    }
                    SecureField("CF_Authorization を貼り付け", text: $pastedJWT)
                        .textInputAutocapitalization(.never)
                    Button("貼り付けたトークンを保存") { savePastedJWT() }
                    if let pasteError {
                        Text(pasteError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Text("WebView が白いときは、Mac の Safari で api.sollahiro.com に OTP ログインし、Cookie の CF_Authorization を貼るか、同じ Wi-Fi の http://<MacのIP>:3000 を使います。Service Token は入れません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("このサーバーは無認証です（loopback / http、または本番以外の https）。Access ログインは https://api.sollahiro.com のときだけ出ます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("設定")
        .bltChrome()
        .sheet(isPresented: $showLogin, onDismiss: { loginStatus = LoginStatus.read() }) {
            AccessLoginView(baseURL: APIConfiguration.baseURL) {
                loginStatus = LoginStatus.read()
            }
        }
        .onAppear { loginStatus = LoginStatus.read() }
    }

    private func saveBaseURL() {
        if let url = APIConfiguration.validatedBaseURL(from: baseURL) {
            APIConfiguration.baseURL = url
            baseURL = url.absoluteString
            saveError = nil
            loginStatus = LoginStatus.read()
        } else {
            saveError = "http または https の絶対 URL を入力してください"
        }
    }

    private func savePastedJWT() {
        let jwt = pastedJWT.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jwt.isEmpty else {
            pasteError = "トークンが空です"
            return
        }
        do {
            try AccessSession.save(jwt: jwt, for: APIConfiguration.baseURL)
            pastedJWT = ""
            pasteError = nil
            loginStatus = LoginStatus.read()
        } catch {
            pasteError = error.localizedDescription
        }
    }
}

private struct LoginStatus {
    var line: String
    var hasJWT: Bool

    static func read() -> LoginStatus {
        let url = APIConfiguration.baseURL
        guard AccessSession.usesAccess(url) else {
            return LoginStatus(line: "無認証", hasJWT: false)
        }
        guard let jwt = AccessSession.jwt(for: url) else {
            return LoginStatus(line: "未ログイン", hasJWT: false)
        }
        if AccessSession.isExpired(jwt) {
            return LoginStatus(line: "ログイン期限切れ", hasJWT: true)
        }
        if let expiry = AccessSession.expiry(of: jwt) {
            let text = expiry.formatted(date: .abbreviated, time: .shortened)
            return LoginStatus(line: "ログイン済み（期限 \(text)）", hasJWT: true)
        }
        return LoginStatus(line: "ログイン済み", hasJWT: true)
    }
}
