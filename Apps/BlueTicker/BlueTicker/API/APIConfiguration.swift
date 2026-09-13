import Foundation

enum APIConfiguration {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:3000")!
    /// 段階 A プレビュー（Cloudflare Access）。段階 B の公開扉は `productionHAPISGatewayBaseURL`。
    static let productionBaseURL = URL(string: "https://api.sollahiro.com")!
    /// HAPIS 制御面（challenge / sessions / refresh）。秘密ではない。
    static let defaultHAPISIssuerURL = URL(string: "https://hapis.sollahiro.workers.dev")!
    /// 段階 B のクライアント向け本番ゲートウェイ。blt-server origin ではない。
    static let productionHAPISGatewayBaseURL = URL(
        string: "https://hapis-blue-ticker-production.sollahiro.workers.dev")!
    /// Debug 実機で App Attest を試すときだけ `appAttest`。Release は常に App Attest。
    private static let attestModeStorageKey = "blt.hapis.attestMode"
    /// Access のログイン UI（App Launcher）。`api.*` 直叩きは 403 interstitial になる。
    static let accessLauncherURL = URL(string: "https://sollahiro.cloudflareaccess.com")!
    /// REST が `icon_url: null` のときの公開ホスト（秘密ではない。拡張子は会社ごとに違う）。
    static let defaultIconBaseURL = URL(string: "https://icons.sollahiro.com")!
    private static let storageKey = "blt.api.baseURL"
    private static let issuerStorageKey = "blt.hapis.issuerURL"
    private static let gatewayStorageKey = "blt.hapis.gatewayBaseURL"

    static var usesAccess: Bool { AccessSession.usesAccess(baseURL) }

    static var usesHAPISConsumer: Bool { usesHAPISConsumer(baseURL) }

    static func usesHAPISConsumer(_ url: URL) -> Bool {
        HAPISConsumerAuth.applies(
            to: url, gatewayBases: [hapisGatewayBaseURL, productionHAPISGatewayBaseURL])
    }

    /// Debug 既定は stub mint。Release / 本番ゲートウェイ経路は App Attest（enforce はサーバー側）。
    static var hapisAttestClientMode: HAPISAttestClientMode {
        #if DEBUG
            if let raw = UserDefaults.standard.string(forKey: attestModeStorageKey),
                let mode = HAPISAttestClientMode(rawValue: raw)
            {
                return mode
            }
            return .stub
        #else
            return .appAttest
        #endif
    }

    /// Debug だけ UserDefaults で上書き。Release は HAPIS 本番に固定（同じ Bundle ID の Debug 値を読まない）。
    static var hapisIssuerURL: URL {
        get {
            #if DEBUG
                if let raw = UserDefaults.standard.string(forKey: issuerStorageKey),
                    let url = validatedHAPISIssuerURL(from: raw)
                {
                    return url
                }
            #endif
            return defaultHAPISIssuerURL
        }
        set {
            #if DEBUG
                if let origin = HAPISIssuer.origin(of: newValue) {
                    UserDefaults.standard.set(origin.absoluteString, forKey: issuerStorageKey)
                }
            #endif
        }
    }

    static var hapisGatewayBaseURL: URL {
        get {
            #if DEBUG
                if let raw = UserDefaults.standard.string(forKey: gatewayStorageKey),
                    let url = validatedBaseURL(from: raw)
                {
                    return url
                }
            #endif
            return productionHAPISGatewayBaseURL
        }
        set {
            #if DEBUG
                UserDefaults.standard.set(newValue.absoluteString, forKey: gatewayStorageKey)
            #endif
        }
    }

    static var baseURL: URL {
        get {
            #if DEBUG
                if let raw = UserDefaults.standard.string(forKey: storageKey),
                    let url = validatedBaseURL(from: raw)
                {
                    return url
                }
                return defaultBaseURL
            #else
                return productionHAPISGatewayBaseURL
            #endif
        }
        set {
            #if DEBUG
                UserDefaults.standard.set(newValue.absoluteString, forKey: storageKey)
            #endif
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

    /// HAPIS 発行者は https origin だけ。path / query / http は落とす。
    static func validatedHAPISIssuerURL(from raw: String) -> URL? {
        guard let url = validatedBaseURL(from: raw) else { return nil }
        return HAPISIssuer.origin(of: url)
    }
}
