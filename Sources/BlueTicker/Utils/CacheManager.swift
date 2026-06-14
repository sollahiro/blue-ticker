import Foundation

// MARK: - CacheManager

/// derived キャッシュの読み書きを担当する actor。
/// キー prefix でサブディレクトリに振り分け、TTL と atomic write で一貫性を保つ。
actor CacheManager {
    private let dataDir: URL
    private let ttlDays: Int
    let enabled: Bool

    private var metadataCache: [String: String]?

    init(cacheDir: URL, enabled: Bool = true, ttlDays: Int = 7) {
        self.dataDir = cacheDir
        self.ttlDays = ttlDays
        self.enabled = enabled
    }

    func setCacheDir(_ cacheDir: URL) {
        // actor の stored property を再設定したい場合は新インスタンスを作成する設計。
        // ここでは cache_dir 変更は再起動相当と見なし、警告のみ。
    }

    // MARK: - Get / Set

    @available(*, unavailable, message: "Use getJSON(_:) or decode(_:as:) instead")
    func get(_ key: String) -> (any Decodable & Encodable)? { nil }

    func getJSON(_ key: String) -> sending [String: Any]? {
        guard enabled else { return nil }
        let file = cacheFilePath(key)
        guard fileExists(file) || fileExists(legacyCacheFilePath(key)) else { return nil }
        let actualFile = fileExists(file) ? file : legacyCacheFilePath(key)

        let meta = loadMetadata()
        if let dateStr = meta[key] {
            guard let cacheDate = ISO8601DateFormatter().date(from: dateStr) else { return nil }
            let days = Calendar.current.dateComponents([.day], from: cacheDate, to: Date()).day ?? 0
            if days >= ttlDays { return nil }
        }

        guard let data = try? Data(contentsOf: actualFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    func setJSON(_ key: String, value: [String: Any]) {
        guard enabled else { return }
        let file = cacheFilePath(key)
        guard let dir = Optional(file.deletingLastPathComponent()) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = dir.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        _ = try? FileManager.default.moveItem(at: tmp, to: file)

        var meta = loadMetadata()
        meta[key] = ISO8601DateFormatter().string(from: Date())
        saveMetadata(meta)
    }

    func keys() -> [String] {
        loadMetadata().keys.sorted()
    }

    func clearPrefix(_ prefix: String) -> Int {
        let matching = keys().filter { $0.hasPrefix(prefix) }
        for k in matching { clear(k) }
        return matching.count
    }

    func clear(_ key: String) {
        let file = cacheFilePath(key)
        try? FileManager.default.removeItem(at: file)
        let legacy = legacyCacheFilePath(key)
        try? FileManager.default.removeItem(at: legacy)

        let metaPath = metadataFilePath()
        var meta: [String: String] = [:]
        if let data = try? Data(contentsOf: metaPath),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            meta = decoded
        }
        meta.removeValue(forKey: key)
        if let encoded = try? JSONEncoder().encode(meta) {
            try? encoded.write(to: metaPath, options: .atomic)
        }
        metadataCache = meta
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: dataDir)
        let metaPath = metadataFilePath()
        try? FileManager.default.removeItem(at: metaPath)
        metadataCache = nil
    }

    // MARK: - Codable 版（型安全な read/write）

    func decode<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard enabled else { return nil }
        let file = cacheFilePath(key)
        let actual = fileExists(file) ? file : (fileExists(legacyCacheFilePath(key)) ? legacyCacheFilePath(key) : nil)
        guard let url = actual else { return nil }

        let meta = loadMetadata()
        if let dateStr = meta[key], let cacheDate = ISO8601DateFormatter().date(from: dateStr) {
            let days = Calendar.current.dateComponents([.day], from: cacheDate, to: Date()).day ?? 0
            if days >= ttlDays { return nil }
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func encode<T: Encodable>(_ key: String, value: T) {
        guard enabled else { return }
        let file = cacheFilePath(key)
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = dir.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        guard let data = try? JSONEncoder().encode(value) else { return }
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        _ = try? FileManager.default.moveItem(at: tmp, to: file)

        var meta = loadMetadata()
        meta[key] = ISO8601DateFormatter().string(from: Date())
        saveMetadata(meta)
    }

    // MARK: - Internals

    private func cacheFilePath(_ key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
                      .replacingOccurrences(of: "\\", with: "_")
                      .replacingOccurrences(of: " ", with: "_")
        return categoryDir(key).appendingPathComponent("\(safe).json")
    }

    private func legacyCacheFilePath(_ key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
                      .replacingOccurrences(of: "\\", with: "_")
                      .replacingOccurrences(of: " ", with: "_")
        return dataDir.deletingLastPathComponent().appendingPathComponent("\(safe).json")
    }

    private func categoryDir(_ key: String) -> URL {
        let sub: String
        if key.hasPrefix("individual_analysis_") { sub = "analysis" }
        else if key.hasPrefix("half_year_periods_") { sub = "half_year" }
        else if key.hasPrefix("edinet_docs_") { sub = "document_discovery" }
        else if key.hasPrefix("xbrl_parsed_") { sub = "xbrl_numeric_index" }
        else if key.hasPrefix("xbrl_sections_") { sub = "xbrl_sections" }
        else { sub = "misc" }
        return dataDir.appendingPathComponent(sub, isDirectory: true)
    }

    private func metadataFilePath() -> URL {
        dataDir.appendingPathComponent("metadata.json")
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func loadMetadata() -> [String: String] {
        if let cached = metadataCache { return cached }
        let path = metadataFilePath()
        guard let data = try? Data(contentsOf: path),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            metadataCache = [:]
            return [:]
        }
        metadataCache = decoded
        return decoded
    }

    private func saveMetadata(_ meta: [String: String]) {
        let path = metadataFilePath()
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = path.deletingLastPathComponent()
            .appendingPathComponent(".metadata.\(UUID().uuidString).tmp")
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.moveItem(at: tmp, to: path)
        }
        metadataCache = meta
    }
}
