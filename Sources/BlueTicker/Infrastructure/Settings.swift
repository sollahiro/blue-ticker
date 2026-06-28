import Foundation

private let keychainService = "blue-ticker"

actor SettingsStore {
    private var values: SettingsValues
    let userDataPath: URL
    let cacheDir: URL
    let configPath: URL

    init() {
        let base = defaultUserDataPath()
        let cacheDir = base.appendingPathComponent("analysis_cache", isDirectory: true)
        let configPath = base.appendingPathComponent("config.json")

        // Swift 6: actor-isolated メソッドを init から呼べないため、ここに直接展開する
        var v = SettingsValues(cacheDir: cacheDir.path)
        if FileManager.default.fileExists(atPath: configPath.path),
           let data = try? Data(contentsOf: configPath),
           let file = try? JSONDecoder().decode(SettingsFile.self, from: data) {
            v.cacheDir = file.cacheDir ?? v.cacheDir
            v.cacheEnabled = file.cacheEnabled ?? v.cacheEnabled
            if let backend = file.edinetBackend, backend == "local" || backend == "remote" {
                v.edinetBackend = backend
            }
            v.serverURL = file.serverURL ?? v.serverURL
        }

        self.userDataPath = base
        self.cacheDir = cacheDir
        self.configPath = configPath
        self.values = v

        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    func get(_ key: SettingsKey) -> String? {
        switch key {
        case .edinetApiKey:
            return Keystore.getPassword(service: keychainService, key: key.rawValue)
                ?? (values.edinetApiKey.isEmpty ? nil : values.edinetApiKey)
        case .cacheDir:
            return values.cacheDir
        case .edinetBackend:
            return values.edinetBackend
        case .serverURL:
            return values.serverURL.isEmpty ? nil : values.serverURL
        case .authToken:
            return Keystore.getPassword(service: keychainService, key: key.rawValue)
                ?? (values.authToken.isEmpty ? nil : values.authToken)
        case .cfAccessClientId:
            return Keystore.getPassword(service: keychainService, key: key.rawValue)
                ?? (values.cfAccessClientId.isEmpty ? nil : values.cfAccessClientId)
        case .cfAccessClientSecret:
            return Keystore.getPassword(service: keychainService, key: key.rawValue)
                ?? (values.cfAccessClientSecret.isEmpty ? nil : values.cfAccessClientSecret)
        }
    }

    func getBool(_ key: SettingsBoolKey) -> Bool {
        switch key {
        case .cacheEnabled:
            return values.cacheEnabled
        }
    }

    func set(_ key: SettingsKey, value: String) throws {
        switch key {
        case .edinetApiKey:
            try Keystore.setPassword(service: keychainService, key: key.rawValue, value: value)
            values.edinetApiKey = ""
        case .cacheDir:
            values.cacheDir = value
        case .edinetBackend:
            guard value == "local" || value == "remote" else { return }
            values.edinetBackend = value
        case .serverURL:
            values.serverURL = value
        case .authToken:
            try Keystore.setPassword(service: keychainService, key: key.rawValue, value: value)
            values.authToken = ""
        case .cfAccessClientId:
            try Keystore.setPassword(service: keychainService, key: key.rawValue, value: value)
            values.cfAccessClientId = ""
        case .cfAccessClientSecret:
            try Keystore.setPassword(service: keychainService, key: key.rawValue, value: value)
            values.cfAccessClientSecret = ""
        }
    }

    func set(_ key: SettingsBoolKey, value: Bool) {
        switch key {
        case .cacheEnabled:
            values.cacheEnabled = value
        }
    }

    @discardableResult
    func save() -> Bool {
        let payload = SettingsFile(
            cacheDir: values.cacheDir,
            cacheEnabled: values.cacheEnabled,
            edinetBackend: values.edinetBackend,
            serverURL: values.serverURL.isEmpty ? nil : values.serverURL
        )
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        do {
            try data.write(to: configPath, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func maskedApiKey() -> String {
        mask(get(.edinetApiKey))
    }

    func maskedAuthToken() -> String {
        mask(get(.authToken))
    }

    func maskedCfAccessClientId() -> String {
        mask(get(.cfAccessClientId))
    }

    func maskedCfAccessClientSecret() -> String {
        mask(get(.cfAccessClientSecret))
    }

    private func mask(_ secret: String?) -> String {
        guard let s = secret, !s.isEmpty else { return "****" }
        return s.count > 8 ? String(s.prefix(4)) + "****" + String(s.suffix(4)) : "****"
    }

}

// MARK: - Supporting types

enum SettingsKey: String {
    case edinetApiKey
    case cacheDir
    case edinetBackend
    case serverURL
    case authToken
    case cfAccessClientId
    case cfAccessClientSecret
}

enum SettingsBoolKey {
    case cacheEnabled
}

private struct SettingsValues {
    var edinetApiKey: String = ""
    var cacheDir: String
    var cacheEnabled: Bool = true
    var edinetBackend: String = "local"
    var serverURL: String = ""
    // 機密のため通常は keychain に保存し、values には載せない（keychain 不在環境のフォールバックのみ）。
    var authToken: String = ""
    // Cloudflare Access Service Token の鍵ペア。authToken と同様 keychain 管理。
    var cfAccessClientId: String = ""
    var cfAccessClientSecret: String = ""
}

private struct SettingsFile: Codable {
    var cacheDir: String?
    var cacheEnabled: Bool?
    var edinetBackend: String?
    var serverURL: String?
    // authToken は config ファイルに保存しない（keychain 管理。edinetApiKey と同様）。
}

// MARK: - Global singleton

let settingsStore = SettingsStore()
