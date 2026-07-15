import Foundation

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
            v.serverURL = file.serverURL ?? v.serverURL
            v.cfAccessSsoEnabled = file.cfAccessSsoEnabled ?? v.cfAccessSsoEnabled
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
        case .cacheDir:
            return values.cacheDir
        case .serverURL:
            return values.serverURL.isEmpty ? nil : values.serverURL
        }
    }

    func getBool(_ key: SettingsBoolKey) -> Bool {
        switch key {
        case .cfAccessSsoEnabled:
            return values.cfAccessSsoEnabled
        }
    }

    func set(_ key: SettingsKey, value: String) {
        switch key {
        case .cacheDir:
            values.cacheDir = value
        case .serverURL:
            values.serverURL = value
        }
    }

    func set(_ key: SettingsBoolKey, value: Bool) {
        switch key {
        case .cfAccessSsoEnabled:
            values.cfAccessSsoEnabled = value
        }
    }

    @discardableResult
    func save() -> Bool {
        let payload = SettingsFile(
            cacheDir: values.cacheDir,
            serverURL: values.serverURL.isEmpty ? nil : values.serverURL,
            cfAccessSsoEnabled: values.cfAccessSsoEnabled ? true : nil
        )
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        do {
            try data.write(to: configPath, options: .atomic)
            return true
        } catch {
            return false
        }
    }

}

// MARK: - Supporting types

enum SettingsKey {
    case cacheDir
    case serverURL
}

enum SettingsBoolKey {
    case cfAccessSsoEnabled
}

private struct SettingsValues {
    var cacheDir: String
    var serverURL: String = Api.defaultRemoteServerURL
    // ticker login（cloudflared access login）成功時に立てるフラグ。秘密情報ではなく
    // JWT 自体は cloudflared 側のローカルストレージが保持するため config.json に保存してよい。
    var cfAccessSsoEnabled: Bool = false
}

private struct SettingsFile: Codable {
    var cacheDir: String?
    var serverURL: String?
    var cfAccessSsoEnabled: Bool?
}

// MARK: - Global singleton

let settingsStore = SettingsStore()
