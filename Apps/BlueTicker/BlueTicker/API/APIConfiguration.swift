import Foundation

enum APIConfiguration {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:3000")!
    /// HAPIS 制御面（challenge / sessions / refresh）。秘密ではない。
    static let defaultHAPISIssuerURL = URL(string: "https://hapis.sollahiro.workers.dev")!
    /// クライアント向け本番ゲートウェイ。blt-server origin ではない。
    static let productionHAPISGatewayBaseURL = URL(
        string: "https://hapis-blue-ticker-production.sollahiro.workers.dev")!
    /// Debug の「HAPIS 本番」は App Attest。`stub` 上書きは Simulator / ローカル用。Release は常に App Attest。
    private static let attestModeStorageKey = "blt.hapis.attestMode"
    /// REST が `icon_url: null` のときの公開ホスト（秘密ではない。拡張子は会社ごとに違う）。
    static let defaultIconBaseURL = URL(string: "https://icons.sollahiro.com")!
    private static let storageKey = "blt.api.baseURL"
    private static let issuerStorageKey = "blt.hapis.issuerURL"
    private static let gatewayStorageKey = "blt.hapis.gatewayBaseURL"

    static var usesHAPISConsumer: Bool { usesHAPISConsumer(baseURL) }

    static func usesHAPISConsumer(_ url: URL) -> Bool {
        HAPISConsumerAuth.applies(
            to: url, gatewayBases: [hapisGatewayBaseURL, productionHAPISGatewayBaseURL])
    }

    /// Debug の HAPIS ゲートウェイ経路は App Attest。ローカルは stub。Release は常に App Attest。
    static var hapisAttestClientMode: HAPISAttestClientMode {
        get {
            #if DEBUG
                if let raw = UserDefaults.standard.string(forKey: attestModeStorageKey),
                    let mode = HAPISAttestClientMode(rawValue: raw)
                {
                    return mode
                }
                return usesHAPISConsumer ? .appAttest : .stub
            #else
                return .appAttest
            #endif
        }
        set {
            #if DEBUG
                UserDefaults.standard.set(newValue.rawValue, forKey: attestModeStorageKey)
            #endif
        }
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
                    if url.scheme?.lowercased() == "https",
                        url.host?.lowercased() == "api.sollahiro.com"
                    {
                        let replacement = productionHAPISGatewayBaseURL
                        UserDefaults.standard.set(replacement.absoluteString, forKey: storageKey)
                        hapisGatewayBaseURL = replacement
                        hapisAttestClientMode = .appAttest
                        return replacement
                    }
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
