import Foundation

// Port of blue_ticker/services/cache_pruner.py

struct PruneSummary {
    var removedFiles: Int = 0
    var removedDirs: Int = 0
    var freedBytes: Int64 = 0
    var scannedFiles: Int = 0
    var scannedDirs: Int = 0

    func merging(_ other: PruneSummary) -> PruneSummary {
        PruneSummary(
            removedFiles: removedFiles + other.removedFiles,
            removedDirs: removedDirs + other.removedDirs,
            freedBytes: freedBytes + other.freedBytes,
            scannedFiles: scannedFiles + other.scannedFiles,
            scannedDirs: scannedDirs + other.scannedDirs
        )
    }
}

struct CachePruner {
    let cacheDir: URL
    private let edinetDir: URL
    private let fm = FileManager.default

    init(cacheDir: URL) {
        self.cacheDir = cacheDir
        self.edinetDir = edinetCacheDir(cacheDir)
    }

    /// EDINET キャッシュを指定条件で整理する。
    func prune(
        dryRun: Bool = true,
        edinetSearchDays: Int? = nil,
        edinetXbrlDays: Int? = nil,
        edinetDocIndexYears: Int? = Api.documentIndexKeepYears
    ) -> PruneSummary {
        var summary = PruneSummary()
        if let days = edinetSearchDays {
            summary = summary.merging(pruneEdinetSearch(days: days, dryRun: dryRun))
        }
        if let days = edinetXbrlDays {
            summary = summary.merging(pruneEdinetXbrl(days: days, dryRun: dryRun))
        }
        if let years = edinetDocIndexYears {
            summary = summary.merging(pruneEdinetDocIndexes(keepYears: years, dryRun: dryRun))
        }
        return summary
    }

    // MARK: - 個別プルーナー

    private func pruneEdinetSearch(days: Int, dryRun: Bool) -> PruneSummary {
        let files = edinetSearchFiles().filter { ageDays($0) >= days }
        let freed = files.compactMap { fileSize($0) }.reduce(Int64(0), +)
        if !dryRun { files.forEach { try? fm.removeItem(at: $0) } }
        return PruneSummary(
            removedFiles: dryRun ? 0 : files.count,
            freedBytes: freed,
            scannedFiles: files.count
        )
    }

    private func pruneEdinetXbrl(days: Int, dryRun: Bool) -> PruneSummary {
        let dirs = edinetXbrlDirs().filter { ageDays($0) >= days }
        let freed = dirs.map { pathSize($0) }.reduce(Int64(0), +)
        if !dryRun { dirs.forEach { try? fm.removeItem(at: $0) } }
        return PruneSummary(
            removedDirs: dryRun ? 0 : dirs.count,
            freedBytes: freed,
            scannedDirs: dirs.count
        )
    }

    private func pruneEdinetDocIndexes(keepYears: Int, dryRun: Bool) -> PruneSummary {
        let currentYear = utcCalendar.component(.year, from: Date())
        let thresholdYear = keepYears <= 0 ? currentYear + 1 : currentYear - keepYears + 1
        let files = edinetDocIndexFiles().filter { url in
            guard let year = docIndexYear(url) else { return false }
            return year < thresholdYear
        }
        let freed = files.compactMap { fileSize($0) }.reduce(Int64(0), +)
        if !dryRun { files.forEach { try? fm.removeItem(at: $0) } }
        return PruneSummary(
            removedFiles: dryRun ? 0 : files.count,
            freedBytes: freed,
            scannedFiles: files.count
        )
    }

    // MARK: - ファイル列挙

    private func edinetSearchFiles() -> [URL] {
        globFiles(edinetDir.appendingPathComponent("documents_by_date"), prefix: "search_", suffix: ".json")
    }

    private func edinetDocIndexFiles() -> [URL] {
        globFiles(edinetDir.appendingPathComponent("document_indexes"), prefix: "doc_index_", suffix: ".json")
    }

    private func edinetXbrlDirs() -> [URL] {
        globDirs(edinetDir.appendingPathComponent("xbrl"), suffix: "_xbrl")
    }

    // MARK: - Helpers

    private func globFiles(_ dir: URL, prefix: String, suffix: String) -> [URL] {
        guard fm.fileExists(atPath: dir.path) else { return [] }
        return (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey]))?
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix(prefix) && name.hasSuffix(suffix)
            } ?? []
    }

    private func globDirs(_ dir: URL, suffix: String) -> [URL] {
        guard fm.fileExists(atPath: dir.path) else { return [] }
        return (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return isDir && url.lastPathComponent.hasSuffix(suffix)
            } ?? []
    }

    private func ageDays(_ url: URL) -> Int {
        guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return 0 }
        return elapsedDaysUTC(since: mtime)
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Int64($0) }
    }

    private func pathSize(_ url: URL) -> Int64 {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return enumerator.compactMap { $0 as? URL }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(Int64(0)) { $0 + Int64($1) }
    }

    private func docIndexYear(_ url: URL) -> Int? {
        let stem = url.deletingPathExtension().lastPathComponent
        return Int(stem.replacingOccurrences(of: "doc_index_", with: ""))
    }
}
