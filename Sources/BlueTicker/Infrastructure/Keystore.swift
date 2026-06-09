import Foundation

// macOS: Security.framework (Keychain)
// Linux: secrets.json with chmod 0600 (same behaviour as Python fallback)

#if canImport(Security)
import Security
#endif

enum Keystore {
    static func setPassword(service: String, key: String, value: String) throws {
#if canImport(Security)
        try macSetPassword(service: service, key: key, value: value)
#else
        try fileSetPassword(key: key, value: value)
#endif
    }

    static func getPassword(service: String, key: String) -> String? {
#if canImport(Security)
        return macGetPassword(service: service, key: key)
#else
        return fileGetPassword(key: key)
#endif
    }
}

// MARK: - macOS Keychain

#if canImport(Security)
private func macSetPassword(service: String, key: String, value: String) throws {
    // 既存エントリを削除
    let deleteQuery: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: key,
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    guard let data = value.data(using: .utf8) else {
        throw KeystoreError.encodingFailed
    }
    let addQuery: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: key,
        kSecValueData: data,
    ]
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    guard status == errSecSuccess else {
        throw KeystoreError.keychainError(status)
    }
}

private func macGetPassword(service: String, key: String) -> String? {
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: key,
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let value = String(data: data, encoding: .utf8),
          !value.isEmpty
    else { return nil }
    return value
}
#endif

// MARK: - File fallback (Linux / no Keychain)

private func fileSetPassword(key: String, value: String) throws {
    let path = candidateSecretPaths()[0]
    let dir = path.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var data: [String: String] = [:]
    if let existing = try? Data(contentsOf: path),
       let decoded = try? JSONDecoder().decode([String: String].self, from: existing) {
        data = decoded
    }
    data[key] = value
    let encoded = try JSONEncoder().encode(data)
    try encoded.write(to: path, options: .atomic)
    // chmod 0600
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
}

private func fileGetPassword(key: String) -> String? {
    for path in candidateSecretPaths() {
        guard FileManager.default.fileExists(atPath: path.path),
              let raw = try? Data(contentsOf: path),
              let decoded = try? JSONDecoder().decode([String: String].self, from: raw),
              let value = decoded[key], !value.isEmpty
        else { continue }
        return value
    }
    return nil
}

// MARK: - Error

enum KeystoreError: Error {
    case encodingFailed
    case keychainError(OSStatus)
}
