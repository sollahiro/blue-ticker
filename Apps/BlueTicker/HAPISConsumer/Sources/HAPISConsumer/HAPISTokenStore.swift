import Foundation
#if canImport(Security)
import Security
#endif

protocol HAPISTokenStoring: Sendable {
    func load() throws -> HAPISConsumerToken?
    func save(_ token: HAPISConsumerToken) throws
    func clear()
}

final class InMemoryHAPISTokenStore: HAPISTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: HAPISConsumerToken?

    func load() throws -> HAPISConsumerToken? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func save(_ token: HAPISConsumerToken) throws {
        lock.lock()
        self.token = token
        lock.unlock()
    }

    func clear() {
        lock.lock()
        token = nil
        lock.unlock()
    }
}

#if canImport(Security)
/// 発行済み consumer JWT を Keychain に置く。`HAPIS_API_TOKEN` は扱わない。
struct KeychainHAPISTokenStore: HAPISTokenStoring {
    var service: String
    var account: String

    init(
        service: String = "com.sollahiro.BlueTicker.hapisConsumer",
        account: String = "issuer"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> HAPISConsumerToken? {
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

    func save(_ token: HAPISConsumerToken) throws {
        let data = try HAPISJSON.encoder.encode(token)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status: OSStatus
        if (try load()) != nil {
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

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif
