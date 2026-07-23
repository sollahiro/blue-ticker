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
        }
    }

    func set(_ key: SettingsKey, value: String) {
        switch key {
        case .cacheDir:
            values.cacheDir = value
        }
    }

    @discardableResult
    func save() -> Bool {
        let payload = SettingsFile(cacheDir: values.cacheDir)
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
}

private struct SettingsValues {
    var cacheDir: String
}

private struct SettingsFile: Codable {
    var cacheDir: String?
}

// MARK: - Global singleton

let settingsStore = SettingsStore()
