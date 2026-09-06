import Foundation
import Security

/// Cloudflare Access の短命 JWT（`CF_Authorization`）。Service Token は扱わない。
enum AccessSession {
    static let cookieName = "CF_Authorization"
    private static let service = "com.sollahiro.BlueTicker.accessJWT"

    static func isLoopback(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    /// 本番 `api.sollahiro.com` だけ Access する。任意の https には載せない。
    static func usesAccess(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == APIConfiguration.productionBaseURL.host?.lowercased()
    }

    static func jwt(for url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        return readKeychain(account: host)
    }

    static func save(jwt: String, for url: URL) throws {
        guard let host = url.host, !host.isEmpty else {
            throw AccessSessionError.missingHost
        }
        let trimmed = jwt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLikelyJWT(trimmed), !isExpired(trimmed) else {
            throw AccessSessionError.invalidJWT
        }
        try writeKeychain(account: host, value: trimmed)
    }

    static func clear(for url: URL) {
        guard let host = url.host, !host.isEmpty else { return }
        deleteKeychain(account: host)
    }

    static func expiry(of jwt: String) -> Date? {
        guard isLikelyJWT(jwt) else { return nil }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = payload.count % 4
        if pad > 0 {
            payload += String(repeating: "=", count: 4 - pad)
        }
        guard let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let exp: TimeInterval?
        if let value = json["exp"] as? NSNumber {
            exp = value.doubleValue
        } else if let value = json["exp"] as? TimeInterval {
            exp = value
        } else if let value = json["exp"] as? Int {
            exp = TimeInterval(value)
        } else {
            exp = nil
        }
        guard let exp else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// 形が JWT でない、または `exp` が読めない・過ぎているものは期限切れとして扱う。
    static func isExpired(_ jwt: String) -> Bool {
        guard let expiry = expiry(of: jwt) else { return true }
        return expiry <= Date()
    }

    static func isLikelyJWT(_ jwt: String) -> Bool {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty }
    }

    private static func readKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(account: String, value: String) throws {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status: OSStatus
        if readKeychain(account: account) != nil {
            status = SecItemUpdate(
                base as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AccessSessionError.keychain(status) }
    }

    private static func deleteKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum AccessSessionError: LocalizedError {
    case missingHost
    case keychain(OSStatus)
    case cookieMissing
    case invalidJWT

    var errorDescription: String? {
        switch self {
        case .missingHost:
            return "サーバー URL に host がありません"
        case .keychain:
            return "ログイン状態を保存できませんでした"
        case .cookieMissing:
            return "Access の Cookie を取得できませんでした"
        case .invalidJWT:
            return "CF_Authorization が JWT として読めないか、期限切れです"
        }
    }
}

enum AccessChallenge {
    static func isLoginURL(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "cloudflareaccess.com" || host.hasSuffix(".cloudflareaccess.com")
    }

    static func isChallenge(_ response: HTTPURLResponse) -> Bool {
        if isLoginURL(response.url) { return true }
        if let location = response.value(forHTTPHeaderField: "Location"),
            let url = URL(string: location),
            isLoginURL(url)
        {
            return true
        }
        if response.statusCode == 403,
            response.value(forHTTPHeaderField: "cf-access-domain") != nil
                || response.value(forHTTPHeaderField: "cf-access-aud") != nil
        {
            return true
        }
        return false
    }
}

final class AccessRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        if AccessChallenge.isLoginURL(request.url) {
            return nil
        }
        let fromHost = task.originalRequest?.url?.host?.lowercased()
        let toHost = request.url?.host?.lowercased()
        guard fromHost != nil, fromHost == toHost else {
            return nil
        }
        return request
    }
}
