import Foundation

private let keychainService = "blue-ticker"

actor SettingsStore {
    private var values: SettingsValues
    let userDataPath: URL
    let cacheDir: URL
    let configPath: URL

    init() {
        let base = defaultUserDataPath()
        self.userDataPath = base
        self.cacheDir = base.appendingPathComponent("analysis_cache", isDirectory: true)
        self.configPath = base.appendingPathComponent("config.json")
        self.values = SettingsValues(cacheDir: self.cacheDir.path)

        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
        loadFromFile()
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
            edinetBackend: values.edinetBackend
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
        guard let key = get(.edinetApiKey), !key.isEmpty else { return "****" }
        return key.count > 8
            ? String(key.prefix(4)) + "****" + String(key.suffix(4))
            : "****"
    }

    // MARK: - Private

    private func loadFromFile() {
        guard FileManager.default.fileExists(atPath: configPath.path),
              let data = try? Data(contentsOf: configPath),
              let file = try? JSONDecoder().decode(SettingsFile.self, from: data)
        else { return }

        values.cacheDir = file.cacheDir ?? values.cacheDir
        values.cacheEnabled = file.cacheEnabled ?? values.cacheEnabled
        if let backend = file.edinetBackend, backend == "local" || backend == "remote" {
            values.edinetBackend = backend
        }
    }
}

// MARK: - Supporting types

enum SettingsKey: String {
    case edinetApiKey
    case cacheDir
    case edinetBackend
}

enum SettingsBoolKey {
    case cacheEnabled
}

private struct SettingsValues {
    var edinetApiKey: String = ""
    var cacheDir: String
    var cacheEnabled: Bool = true
    var edinetBackend: String = "local"
}

private struct SettingsFile: Codable {
    var cacheDir: String?
    var cacheEnabled: Bool?
    var edinetBackend: String?
}

// MARK: - Global singleton

let settingsStore = SettingsStore()
