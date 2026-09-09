import Foundation
#if canImport(Security)
import Security
#endif

protocol HAPISTokenStoring: Sendable {
    func load(issuer: URL) throws -> HAPISConsumerToken?
    func save(_ token: HAPISConsumerToken, issuer: URL) throws
    func clear(issuer: URL)
}

protocol HAPISAttestKeyStoring: Sendable {
    func loadKeyId(issuer: URL) throws -> String?
    func saveKeyId(_ keyId: String, issuer: URL) throws
    func clearKeyId(issuer: URL)
}

enum HAPISAttestKeyStores {
    static func make() -> any HAPISAttestKeyStoring {
        #if canImport(Security)
            return KeychainHAPISAttestKeyStore()
        #else
            return InMemoryHAPISAttestKeyStore()
        #endif
    }
}

final class InMemoryHAPISAttestKeyStore: HAPISAttestKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]

    func loadKeyId(issuer: URL) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keys[HAPISIssuer.storageAccount(for: issuer)]
    }

    func saveKeyId(_ keyId: String, issuer: URL) throws {
        lock.lock()
        keys[HAPISIssuer.storageAccount(for: issuer)] = keyId
        lock.unlock()
    }

    func clearKeyId(issuer: URL) {
        lock.lock()
        keys[HAPISIssuer.storageAccount(for: issuer)] = nil
        lock.unlock()
    }
}

final class InMemoryHAPISTokenStore: HAPISTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: HAPISConsumerToken] = [:]

    func load(issuer: URL) throws -> HAPISConsumerToken? {
        lock.lock()
        defer { lock.unlock() }
        return tokens[HAPISIssuer.storageAccount(for: issuer)]
    }

    func save(_ token: HAPISConsumerToken, issuer: URL) throws {
        lock.lock()
        tokens[HAPISIssuer.storageAccount(for: issuer)] = token
        lock.unlock()
    }

    func clear(issuer: URL) {
        lock.lock()
        tokens[HAPISIssuer.storageAccount(for: issuer)] = nil
        lock.unlock()
    }
}

#if canImport(Security)
/// 発行済み consumer JWT を Keychain に置く。`HAPIS_API_TOKEN` は扱わない。
/// account は発行者 origin（host）ごと。
struct KeychainHAPISTokenStore: HAPISTokenStoring {
    var service: String

    init(service: String = "com.sollahiro.BlueTicker.hapisConsumer") {
        self.service = service
    }

    func load(issuer: URL) throws -> HAPISConsumerToken? {
        let account = HAPISIssuer.storageAccount(for: issuer)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try HAPISJSON.decoder.decode(HAPISConsumerToken.self, from: data)
    }

    func save(_ token: HAPISConsumerToken, issuer: URL) throws {
        let account = HAPISIssuer.storageAccount(for: issuer)
        let data = try HAPISJSON.encoder.encode(token)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status: OSStatus
        if (try load(issuer: issuer)) != nil {
            status = SecItemUpdate(
                base as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw HAPISConsumerError.transport("keychain \(status)")
        }
    }

    func clear(issuer: URL) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: HAPISIssuer.storageAccount(for: issuer),
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// App Attest の `keyId`。consumer JWT とは別サービス。account は発行者 origin。
struct KeychainHAPISAttestKeyStore: HAPISAttestKeyStoring {
    var service: String

    init(service: String = "com.sollahiro.BlueTicker.hapisAttestKey") {
        self.service = service
    }

    func loadKeyId(issuer: URL) throws -> String? {
        let account = HAPISIssuer.storageAccount(for: issuer)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        let keyId = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return keyId.isEmpty ? nil : keyId
    }

    func saveKeyId(_ keyId: String, issuer: URL) throws {
        let account = HAPISIssuer.storageAccount(for: issuer)
        let data = Data(keyId.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status: OSStatus
        if (try loadKeyId(issuer: issuer)) != nil {
            status = SecItemUpdate(
                base as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw HAPISConsumerError.transport("keychain \(status)")
        }
    }

    func clearKeyId(issuer: URL) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: HAPISIssuer.storageAccount(for: issuer),
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif
