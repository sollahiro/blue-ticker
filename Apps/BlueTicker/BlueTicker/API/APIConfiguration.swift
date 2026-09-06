import Foundation

enum APIConfiguration {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:3000")!
    static let productionBaseURL = URL(string: "https://api.sollahiro.com")!
    /// Access のログイン UI（App Launcher）。`api.*` 直叩きは 403 interstitial になる。
    static let accessLauncherURL = URL(string: "https://sollahiro.cloudflareaccess.com")!
    /// REST が `icon_url: null` のときの公開ホスト（秘密ではない。拡張子は会社ごとに違う）。
    static let defaultIconBaseURL = URL(string: "https://icons.sollahiro.com")!
    private static let storageKey = "blt.api.baseURL"

    static var usesAccess: Bool { AccessSession.usesAccess(baseURL) }

    static var baseURL: URL {
        get {
            if let raw = UserDefaults.standard.string(forKey: storageKey),
                let url = validatedBaseURL(from: raw)
            {
                return url
            }
            return defaultBaseURL
        }
        set {
            UserDefaults.standard.set(newValue.absoluteString, forKey: storageKey)
        }
    }

    /// `http`/`https` と host がある絶対 URL だけを受け付ける。相対パスやスキーム無しは拒否する。
    static func validatedBaseURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host != nil
        else {
            return nil
        }
        return url
    }
}
