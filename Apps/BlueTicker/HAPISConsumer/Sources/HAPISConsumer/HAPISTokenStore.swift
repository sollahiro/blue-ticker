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
    func load(issuer: URL) throws -> HAPISAttestKeyRecord?
    func save(_ record: HAPISAttestKeyRecord, issuer: URL) throws
    func clear(issuer: URL)
}

/// App Attest 鍵。`registered` は sessions が受理されたあとだけ true（assertion 可能）。
/// `attested` は `attestKey` 成功済み。Apple は同じ鍵で attest を繰り返せない。
struct HAPISAttestKeyRecord: Codable, Equatable, Sendable {
    var keyId: String
    var registered: Bool
    var attested: Bool

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case registered
        case attested
    }

    init(keyId: String, registered: Bool, attested: Bool = false) {
        self.keyId = keyId
        self.registered = registered
        self.attested = attested
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyId = try container.decode(String.self, forKey: .keyId)
        registered = try container.decode(Bool.self, forKey: .registered)
        attested = try container.decodeIfPresent(Bool.self, forKey: .attested) ?? false
    }
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

enum HAPISAttestKeyRecordCodec {
    static func decode(_ data: Data) -> HAPISAttestKeyRecord? {
        if let record = try? HAPISJSON.decoder.decode(HAPISAttestKeyRecord.self, from: data),
            !record.keyId.isEmpty
        {
            return record
        }
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : HAPISAttestKeyRecord(keyId: raw, registered: false)
    }
}

final class InMemoryHAPISAttestKeyStore: HAPISAttestKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: HAPISAttestKeyRecord] = [:]

    func load(issuer: URL) throws -> HAPISAttestKeyRecord? {
        lock.lock()
        defer { lock.unlock() }
        return keys[HAPISIssuer.attestKeyAccount(for: issuer)]
    }

    func save(_ record: HAPISAttestKeyRecord, issuer: URL) throws {
        lock.lock()
        keys[HAPISIssuer.attestKeyAccount(for: issuer)] = record
        lock.unlock()
    }

    func clear(issuer: URL) {
        lock.lock()
        keys[HAPISIssuer.attestKeyAccount(for: issuer)] = nil
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

/// App Attest の `keyId`。consumer JWT とは別サービス。
/// account は発行者 origin + App Attest 環境（development / production）。
/// プレーン文字列の旧形式は未登録として読む。Release は issuer-only の旧 account を読まない。
struct KeychainHAPISAttestKeyStore: HAPISAttestKeyStoring {
    var service: String

    init(service: String = "com.sollahiro.BlueTicker.hapisAttestKey") {
        self.service = service
    }

    func load(issuer: URL) throws -> HAPISAttestKeyRecord? {
        if let data = copy(account: HAPISIssuer.attestKeyAccount(for: issuer)) {
            return HAPISAttestKeyRecordCodec.decode(data)
        }
        #if DEBUG
            let legacy = HAPISIssuer.storageAccount(for: issuer)
            if let data = copy(account: legacy),
                let record = HAPISAttestKeyRecordCodec.decode(data)
            {
                try save(record, issuer: issuer)
                delete(account: legacy)
                return record
            }
        #endif
        return nil
    }

    func save(_ record: HAPISAttestKeyRecord, issuer: URL) throws {
        let account = HAPISIssuer.attestKeyAccount(for: issuer)
        let data = try HAPISJSON.encoder.encode(record)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status: OSStatus
        if copy(account: account) != nil {
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
        delete(account: HAPISIssuer.attestKeyAccount(for: issuer))
        #if DEBUG
            delete(account: HAPISIssuer.storageAccount(for: issuer))
        #endif
    }

    private func copy(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif
