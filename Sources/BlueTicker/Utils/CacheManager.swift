import Foundation

// MARK: - CacheManager

/// derived キャッシュの読み書きを担当する actor。
/// キー prefix でサブディレクトリに振り分け、TTL（ファイル mtime ベース）と
/// アトミック書き込みで一貫性を保つ。
///
/// TTL をキャッシュファイル自身の更新日時で判定するため、複数の blue-ticker
/// プロセスが別々のキー（銘柄）を並行で書き込んでも競合しない。
/// （旧版は metadata.json を read-modify-write しており、プロセス間で更新が失われた）
actor CacheManager {
    private let dataDir: URL
    private let ttlDays: Int
    let enabled: Bool

    init(cacheDir: URL, enabled: Bool = true, ttlDays: Int = 7) {
        self.dataDir = cacheDir
        self.ttlDays = ttlDays
        self.enabled = enabled
    }

    // MARK: - Get / Set

    func getJSON(_ key: String) -> sending [String: Any]? {
        guard enabled else { return nil }
        let file = cacheFilePath(key)
        let actual = fileExists(file) ? file
            : (fileExists(legacyCacheFilePath(key)) ? legacyCacheFilePath(key) : nil)
        guard let url = actual, !isExpired(url) else { return nil }

        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    func setJSON(_ key: String, value: [String: Any]) {
        guard enabled else { return }
        let file = cacheFilePath(key)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return }
        // Data.write(.atomic) は一時ファイル経由の rename で上書きまでアトミックに行う。
        // FileManager.moveItem は宛先が既存だと失敗するため使わない。
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - Internals

    private func cacheFilePath(_ key: String) -> URL {
        categoryDir(key).appendingPathComponent("\(safeName(key)).json")
    }

    private func legacyCacheFilePath(_ key: String) -> URL {
        dataDir.deletingLastPathComponent().appendingPathComponent("\(safeName(key)).json")
    }

    private func safeName(_ key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_")
           .replacingOccurrences(of: "\\", with: "_")
           .replacingOccurrences(of: " ", with: "_")
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

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func isExpired(_ url: URL) -> Bool {
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return true }
        let days = Calendar.current.dateComponents([.day], from: mtime, to: Date()).day ?? 0
        return days >= ttlDays
    }
}
