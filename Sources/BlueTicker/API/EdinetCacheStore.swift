import Foundation
import ZIPFoundation

// MARK: - EdinetCacheStore

/// EDINET の日別検索結果と XBRL 展開ディレクトリをローカルで管理する。
/// Python 版 EdinetCacheStore と同じディレクトリ構造・ファイル形式を維持する。
final class EdinetCacheStore: Sendable {
    let cacheDir: URL
    let documentsByDateDir: URL
    let documentIndexesDir: URL
    let xbrlRootDir: URL
    let locksDir: URL

    private let searchEmptyTTLDays: Int
    private let searchHitTTLDays: Int
    private let searchPastTTLDays: Int
    private let searchTodayTTLHours: Int
    private let maxXbrlBytes: Int64?

    init(
        cacheDir: URL,
        searchEmptyTTLDays: Int = Api.searchEmptyTTLDays,
        searchHitTTLDays: Int = Api.searchHitTTLDays,
        searchPastTTLDays: Int = Api.searchPastTTLDays,
        searchTodayTTLHours: Int = Api.searchTodayTTLHours,
        maxXbrlBytes: Int64? = Api.xbrlMaxBytes
    ) {
        self.cacheDir = cacheDir
        self.documentsByDateDir = cacheDir.appendingPathComponent("documents_by_date", isDirectory: true)
        self.documentIndexesDir = cacheDir.appendingPathComponent("document_indexes", isDirectory: true)
        self.xbrlRootDir = cacheDir.appendingPathComponent("xbrl", isDirectory: true)
        self.locksDir = cacheDir.appendingPathComponent("locks", isDirectory: true)
        self.searchEmptyTTLDays = searchEmptyTTLDays
        self.searchHitTTLDays = searchHitTTLDays
        self.searchPastTTLDays = searchPastTTLDays
        self.searchTodayTTLHours = searchTodayTTLHours
        self.maxXbrlBytes = maxXbrlBytes
    }

    // MARK: - 日別検索キャッシュ

    func searchCacheKey(_ dateStr: String) -> String { "search_\(dateStr).json" }

    func loadSearchCache(_ filename: String, allowExpired: Bool = false) -> [[String: Any]]? {
        let path = documentsByDateDir.appendingPathComponent(filename)
        guard fm.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        if !allowExpired && isSearchCacheExpired(path, hasResults: !obj.isEmpty) { return nil }
        return obj
    }

    func saveSearchCache(_ filename: String, data: [[String: Any]]) {
        let path = documentsByDateDir.appendingPathComponent(filename)
        try? fm.createDirectory(at: documentsByDateDir, withIntermediateDirectories: true)
        guard let encoded = try? JSONSerialization.data(withJSONObject: data) else { return }
        try? encoded.write(to: path, options: .atomic)
    }

    // MARK: - 年次書類インデックス

    func documentIndexCacheKey(_ year: Int) -> String { "doc_index_\(year).json" }

    func loadDocumentIndex(_ year: Int, requiredThrough: String? = nil, allowStale: Bool = false) -> [[String: Any]]? {
        guard let info = loadDocumentIndexInfo(year, requiredThrough: requiredThrough, allowStale: allowStale)
        else { return nil }
        return info["documents"] as? [[String: Any]]
    }

    func loadDocumentIndexInfo(_ year: Int, requiredThrough: String? = nil, allowStale: Bool = false) -> [String: Any]? {
        let file = documentIndexesDir.appendingPathComponent(documentIndexCacheKey(year))
        guard fm.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard (payload["_cache_version"] as? String) == Api.documentIndexVersion,
              (payload["year"] as? Int) == year
        else { return nil }
        if !allowStale, let req = requiredThrough {
            guard let built = payload["built_through"] as? String, built >= req else { return nil }
        }
        guard payload["documents"] is [[String: Any]] else { return nil }
        return payload.filter { $0.key != "_cache_version" }
    }

    func saveDocumentIndex(_ year: Int, documents: [[String: Any]], builtThrough: String) {
        let path = documentIndexesDir.appendingPathComponent(documentIndexCacheKey(year))
        try? fm.createDirectory(at: documentIndexesDir, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "_cache_version": Api.documentIndexVersion,
            "year": year,
            "built_through": builtThrough,
            "documents": documents,
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? encoded.write(to: path, options: .atomic)
    }

    func clearDocumentIndex(_ year: Int) {
        let path = documentIndexesDir.appendingPathComponent(documentIndexCacheKey(year))
        try? fm.removeItem(at: path)
    }

    // MARK: - XBRL

    func xbrlDir(_ docID: String, saveDir: URL? = nil) -> URL {
        let root = saveDir ?? xbrlRootDir
        return root.appendingPathComponent("\(docID)_xbrl", isDirectory: true)
    }

    func hasXbrlDir(_ docID: String, saveDir: URL? = nil) -> Bool {
        let dest = xbrlDir(docID, saveDir: saveDir)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue else { return false }
        // 空ディレクトリはキャッシュヒットとみなさない。展開失敗（非 ZIP の混入等）で残った
        // 空ディレクトリを「取得済み」と誤判定すると、再取得されず facts=0 で永続的に失敗するため。
        let entries = (try? fm.contentsOfDirectory(atPath: dest.path)) ?? []
        return !entries.isEmpty
    }

    /// 展開済み XBRL ディレクトリがある docID の集合。内訳取り込みの処理順で
    /// 「既にダウンロード済みの書類」を先に回すために使う（EDINET 再取得を減らす）。
    func cachedXbrlDocIDs() -> Set<String> {
        let suffix = "_xbrl"
        let names = (try? fm.contentsOfDirectory(atPath: xbrlRootDir.path)) ?? []
        var ids: Set<String> = []
        for name in names where name.hasSuffix(suffix) {
            let docID = String(name.dropLast(suffix.count))
            if !docID.isEmpty, hasXbrlDir(docID) { ids.insert(docID) }
        }
        return ids
    }

    func touchXbrlDir(_ docID: String, saveDir: URL? = nil) {
        let dest = xbrlDir(docID, saveDir: saveDir)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
    }

    func storeXbrlZip(_ docID: String, content: Data, saveDir: URL? = nil) throws -> URL {
        let root = saveDir ?? xbrlRootDir
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let dest = xbrlDir(docID, saveDir: root)
        let zipPath = root.appendingPathComponent("\(docID).zip")
        try content.write(to: zipPath)
        defer { try? fm.removeItem(at: zipPath) }
        do {
            try extractZip(at: zipPath, to: dest)
        } catch {
            // 展開失敗時に残る dest（多くは空）を消す。残すと hasXbrlDir が誤ヒットしてキャッシュが汚染される。
            try? fm.removeItem(at: dest)
            throw error
        }
        evictXbrlIfNeeded(root: root)
        return dest
    }

    // MARK: - ファイルロック（マルチプロセス間）
    // Task.sleep でポーリングするため async。
    // クロージャも async にすることで EdinetAPIClient 側が
    // ロック保持中にセマフォ取得・API 呼び出しを行える。

    func withFileLock<T>(_ name: String, work: @Sendable () async throws -> T) async throws -> sending T {
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : Character("_") })
        let lockPath = locksDir.appendingPathComponent("\(safe).lock")
        try? fm.createDirectory(at: locksDir, withIntermediateDirectories: true)

        let start = Date()
        var noticeShown = false

        // 非同期ポーリングでロック取得
        while true {
            let acquired: Bool = {
                guard let fd = try? lockPath.path.withCString({ ptr -> Int32 in
                    let fd = open(ptr, O_CREAT | O_EXCL | O_WRONLY, 0o644)
                    if fd < 0 { throw LockError.busy }
                    return fd
                }) else { return false }
                let payload = "pid=\(ProcessInfo.processInfo.processIdentifier)\n"
                _ = payload.withCString { write(fd, $0, strlen($0)) }
                close(fd)
                return true
            }()

            if acquired { break }

            // ステールロック（プロセスがクラッシュして残ったもの）を rename で除去して即リトライ
            // moveItem は原子的なため、同時に除去しようとしたプロセスの一方のみ成功する（TOCTOU 回避）
            if let mtime = (try? fm.attributesOfItem(atPath: lockPath.path))?[.modificationDate] as? Date,
               Date().timeIntervalSince(mtime) >= Api.cacheLockStaleSeconds {
                let stalePath = locksDir.appendingPathComponent(
                    "\(safe).stale.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)")
                if (try? fm.moveItem(at: lockPath, to: stalePath)) != nil {
                    try? fm.removeItem(at: stalePath)
                }
                continue
            }

            let elapsed = Date().timeIntervalSince(start)
            if !noticeShown && elapsed >= Api.cacheLockNoticeSeconds {
                printError("EDINETキャッシュを準備中です。別のblue-tickerプロセスの完了を待っています...\n")
                noticeShown = true
            }
            if elapsed >= Api.cacheLockTimeoutSeconds {
                throw LockError.timeout(name)
            }
            try await Task.sleep(nanoseconds: UInt64(Api.cacheLockPollSeconds * 1_000_000_000))
        }

        if noticeShown {
            printError("EDINETキャッシュの準備が完了しました。処理を続行します。\n")
        }
        defer { try? fm.removeItem(at: lockPath) }
        return try await work()
    }

    // MARK: - Private helpers

    private var fm: FileManager { .default }

    private func isSearchCacheExpired(_ path: URL, hasResults: Bool) -> Bool {
        guard let mtime = (try? fm.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        else { return true }
        let stem = path.deletingPathExtension().lastPathComponent
        let datePart = stem.hasPrefix("search_") ? String(stem.dropFirst("search_".count)) : stem
        // 当日分は EDINET が営業時間中随時更新するため、日単位 TTL（暦日境界でしか経過を
        // 検知できない）では同日内の複数回 sync 実行で再取得されない。時間単位で区切る。
        if let date = parseDateString(datePart), utcCalendar.isDate(date, inSameDayAs: Date()) {
            return elapsedHoursUTC(since: mtime) >= Double(searchTodayTTLHours)
        }
        let ttl = searchCacheTTL(datePart, hasResults: hasResults)
        return elapsedDaysUTC(since: mtime) >= ttl
    }

    private func searchCacheTTL(_ datePart: String, hasResults: Bool) -> Int {
        if let date = parseDateString(datePart), date < utcCalendar.date(byAdding: .day, value: -1, to: Date())! {
            return searchPastTTLDays
        }
        return hasResults ? searchHitTTLDays : searchEmptyTTLDays
    }

    private func extractZip(at zipURL: URL, to destURL: URL) throws {
        // ZIPFoundation を使う
        try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
        // パストラバーサル防止チェックは ZIPFoundation が行う
        try fm.unzipItem(at: zipURL, to: destURL)
    }

    private func evictXbrlIfNeeded(root: URL) {
        guard let maxBytes = maxXbrlBytes else { return }
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        let xbrlDirs = dirs
            .filter { $0.lastPathComponent.hasSuffix("_xbrl") }
            .sorted {
                let m0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let m1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return m0 < m1
            }
        var total = xbrlDirs.reduce(Int64(0)) { $0 + directorySize($1) }
        for dir in xbrlDirs {
            if total <= maxBytes { break }
            let size = directorySize(dir)
            try? fm.removeItem(at: dir)
            total -= size
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return enumerator.compactMap { $0 as? URL }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(Int64(0)) { $0 + Int64($1) }
    }
}

enum LockError: Error {
    case busy
    case timeout(String)
}
