import Foundation

enum APIConfiguration {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:3000")!
    /// REST が `icon_url: null` のときの公開ホスト（秘密ではない。拡張子は会社ごとに違う）。
    static let defaultIconBaseURL = URL(string: "https://icons.sollahiro.com")!
    private static let storageKey = "blt.api.baseURL"

    static var baseURL: URL {
        get {
            if let raw = UserDefaults.standard.string(forKey: storageKey),
                let url = URL(string: raw)
            {
                return url
            }
            return defaultBaseURL
        }
        set {
            UserDefaults.standard.set(newValue.absoluteString, forKey: storageKey)
        }
    }
}
