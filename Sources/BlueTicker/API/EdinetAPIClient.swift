import Foundation

// MARK: - EdinetAPIClient

/// EDINET API v2 クライアント。URLSession + async/await で実装。
actor EdinetAPIClient {
    var apiKey: String?
    private let cacheStore: EdinetCacheStore

    private let dateFetchSemaphore = AsyncSemaphore(value: 10)
    private let xbrlDownloadSemaphore = AsyncSemaphore(value: 4)
    private var documentIndexLocks: [Int: AsyncLock] = [:]
    private var downloadLocks: [String: AsyncLock] = [:]

    init(apiKey: String? = nil, cacheDir: URL? = nil, cacheStore: EdinetCacheStore? = nil) {
        self.apiKey = apiKey
        if let store = cacheStore {
            self.cacheStore = store
        } else {
            let dir = cacheDir ?? URL(fileURLWithPath: "tmp_cache/edinet")
            self.cacheStore = EdinetCacheStore(cacheDir: edinetCacheDir(dir))
        }
    }

    func updateApiKey(_ key: String?) {
        self.apiKey = key?.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 日別ドキュメント取得

    func getDocumentsForDate(_ dateStr: String) async -> [[String: Any]]? {
        let cacheKey = cacheStore.searchCacheKey(dateStr)
        if let cached = cacheStore.loadSearchCache(cacheKey) { return cached }

        // ファイルロックでプロセス間の重複取得を防ぎ、セマフォで並列API呼び出し数を制限する
        do {
            return try await cacheStore.withFileLock("search_\(dateStr)") {
                if let cached = self.cacheStore.loadSearchCache(cacheKey) { return cached }
                await self.dateFetchSemaphore.wait()
                defer { self.dateFetchSemaphore.signal() }
                if let cached = self.cacheStore.loadSearchCache(cacheKey) { return cached }
                let data = try await self.request("/documents.json", params: ["date": dateStr, "type": "2"])
                let docs = data["results"] as? [[String: Any]] ?? []
                self.cacheStore.saveSearchCache(cacheKey, data: docs)
                return docs
            }
        } catch {
            return cacheStore.loadSearchCache(cacheKey, allowExpired: true)
        }
    }

    // MARK: - 年次書類インデックス

    func ensureDocumentIndexForYear(_ year: Int) async -> [[String: Any]] {
        let today = Date()
        let yearEnd = Calendar.current.date(from: DateComponents(year: year, month: 12, day: 31))!
        let requiredThrough = isoDate(min(yearEnd, today))

        if let cached = cacheStore.loadDocumentIndex(year, requiredThrough: requiredThrough, allowStale: true) {
            return cached
        }

        do {
            return try await cacheStore.withFileLock("doc_index_\(year)") {
                if let cached = self.cacheStore.loadDocumentIndex(year, requiredThrough: requiredThrough, allowStale: true) {
                    return cached
                }
                let lock = self.documentIndexLock(for: year)
                await lock.lock()
                defer { lock.unlock() }
                if let cached = self.cacheStore.loadDocumentIndex(year, requiredThrough: requiredThrough, allowStale: true) {
                    return cached
                }
                guard let docs = await self.buildDocumentIndexForYear(year, requiredThrough: min(yearEnd, today)) else {
                    return []
                }
                self.cacheStore.saveDocumentIndex(year, documents: docs, builtThrough: requiredThrough)
                return docs
            }
        } catch {
            return cacheStore.loadDocumentIndex(year, requiredThrough: requiredThrough, allowStale: true) ?? []
        }
    }

    func refreshDocumentIndexForYear(_ year: Int) async -> [[String: Any]] {
        let today = Date()
        let yearEnd = Calendar.current.date(from: DateComponents(year: year, month: 12, day: 31))!
        let requiredThrough = isoDate(min(yearEnd, today))

        do {
            return try await cacheStore.withFileLock("doc_index_\(year)") {
                let lock = self.documentIndexLock(for: year)
                await lock.lock()
                defer { lock.unlock() }
                self.cacheStore.clearDocumentIndex(year)
                guard let docs = await self.buildDocumentIndexForYear(year, requiredThrough: min(yearEnd, today))
                else { return [] }
                self.cacheStore.saveDocumentIndex(year, documents: docs, builtThrough: requiredThrough)
                return docs
            }
        } catch {
            return []
        }
    }

    func catchupDocumentIndexForYear(_ year: Int) async -> [[String: Any]] {
        let today = Date()
        let yearEnd = Calendar.current.date(from: DateComponents(year: year, month: 12, day: 31))!
        let requiredThrough = isoDate(min(yearEnd, today))
        let requiredDate = min(yearEnd, today)

        do {
            return try await cacheStore.withFileLock("doc_index_\(year)") {
                let lock = self.documentIndexLock(for: year)
                await lock.lock()
                defer { lock.unlock() }

                guard let info = self.cacheStore.loadDocumentIndexInfo(year, requiredThrough: requiredThrough, allowStale: true) else {
                    guard let docs = await self.buildDocumentIndexForYear(year, requiredThrough: requiredDate) else { return [] }
                    self.cacheStore.saveDocumentIndex(year, documents: docs, builtThrough: requiredThrough)
                    return docs
                }

                let existingDocs = info["documents"] as? [[String: Any]] ?? []
                guard let builtStr = info["built_through"] as? String,
                      let builtDate = parseDateString(builtStr),
                      builtDate < requiredDate
                else { return existingDocs }

                let startDate = Calendar.current.date(byAdding: .day, value: 1, to: builtDate)!
                if startDate > requiredDate {
                    self.cacheStore.saveDocumentIndex(year, documents: existingDocs, builtThrough: requiredThrough)
                    return existingDocs
                }

                let newByDate = await self.getDocumentsForDateRange(start: startDate, end: requiredDate, useIndex: false)
                if newByDate.values.contains(where: { $0 == nil }) { return existingDocs }
                let merged = mergeDocumentIndexDocs(existing: existingDocs, byDate: newByDate.compactMapValues { $0 })
                self.cacheStore.saveDocumentIndex(year, documents: merged, builtThrough: requiredThrough)
                return merged
            }
        } catch {
            return cacheStore.loadDocumentIndex(year, requiredThrough: requiredThrough, allowStale: true) ?? []
        }
    }

    // MARK: - 日付範囲

    func getDocumentsForDateRange(
        start: Date,
        end: Date,
        useIndex: Bool = true
    ) async -> [String: [[String: Any]]?] {
        guard start <= end else { return [:] }
        let days = Calendar.current.dateComponents([.day], from: start, to: end).day! + 1
        if useIndex && days >= Api.documentIndexMinRangeDays {
            return await getDocumentsFromIndex(start: start, end: end)
        }
        return await getDocumentsDaily(start: start, end: end)
    }

    // MARK: - XBRL ダウンロード

    func downloadDocument(_ docID: String, saveDir: URL? = nil) async -> URL? {
        let dir = saveDir ?? cacheStore.xbrlRootDir
        let dest = cacheStore.xbrlDir(docID, saveDir: dir)

        if downloadLocks[docID] == nil { downloadLocks[docID] = AsyncLock() }
        let lock = downloadLocks[docID]!
        await lock.lock()
        defer { lock.unlock() }

        if cacheStore.hasXbrlDir(docID, saveDir: dir) {
            cacheStore.touchXbrlDir(docID, saveDir: dir)
            return dest
        }
        guard let key = apiKey, !key.isEmpty else { return nil }

        await xbrlDownloadSemaphore.wait()
        defer { xbrlDownloadSemaphore.signal() }

        do {
            let content = try await requestBinary("/documents/\(docID)", params: ["type": "1"])
            return try cacheStore.storeXbrlZip(docID, content: content, saveDir: dir)
        } catch {
            return nil
        }
    }

    // MARK: - HTTP

    private func request(_ endpoint: String, params: [String: String] = [:], maxRetries: Int = 3) async throws -> [String: Any] {
        guard let key = apiKey, !key.isEmpty else { throw EdinetError.noApiKey }
        var allParams = params
        allParams["Subscription-Key"] = key
        let url = try buildURL(endpoint, params: allParams)

        var lastError: Error?
        for attempt in 0..<maxRetries {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse else { throw EdinetError.invalidResponse }

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let code = json["statusCode"] as? Int, code != 200 {
                    let msg = json["message"] as? String ?? "Unknown"
                    if code == 401 { throw EdinetError.invalidApiKey(msg) }
                    throw EdinetError.apiError(code, msg)
                }
                if !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            } catch let e as EdinetError {
                if case .invalidApiKey = e { throw e }
                lastError = e
                if !isRetryable(e) { throw e }
            } catch {
                lastError = error
                if !isRetryable(error) { throw error }
            }
        }
        throw lastError ?? EdinetError.maxRetriesExceeded
    }

    private func requestBinary(_ endpoint: String, params: [String: String] = [:], maxRetries: Int = 3) async throws -> Data {
        guard let key = apiKey, !key.isEmpty else { throw EdinetError.noApiKey }
        var allParams = params
        allParams["Subscription-Key"] = key
        let url = try buildURL(endpoint, params: allParams)

        var lastError: Error?
        for attempt in 0..<maxRetries {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode)
                else { throw URLError(.badServerResponse) }
                return data
            } catch {
                lastError = error
                if !isRetryable(error) { throw error }
            }
        }
        throw lastError ?? EdinetError.maxRetriesExceeded
    }

    private func buildURL(_ endpoint: String, params: [String: String]) throws -> URL {
        guard var comps = URLComponents(string: Api.edinetBaseURL + endpoint) else {
            throw EdinetError.invalidURL
        }
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw EdinetError.invalidURL }
        return url
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let urlErr = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet].contains(urlErr.code)
        }
        return false
    }

    // MARK: - Private helpers

    private func buildDocumentIndexForYear(_ year: Int, requiredThrough: Date) async -> [[String: Any]]? {
        let start = Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1))!
        var dates: [Date] = []
        var current = start
        while current <= requiredThrough {
            dates.append(current)
            current = Calendar.current.date(byAdding: .day, value: 1, to: current)!
        }

        var documents: [[String: Any]] = []
        var hadFailure = false
        let batchSize = Api.documentIndexBatchSize

        for i in stride(from: 0, to: dates.count, by: batchSize) {
            let batch = Array(dates[i..<min(i + batchSize, dates.count)])
            await withTaskGroup(of: (String, [[String: Any]]?).self) { group in
                for date in batch {
                    let ds = isoDate(date)
                    group.addTask { (ds, await self.getDocumentsForDate(ds)) }
                }
                for await (ds, result) in group {
                    if let docs = result {
                        for var doc in docs {
                            doc["_edinet_list_date"] = ds
                            documents.append(doc)
                        }
                    } else {
                        hadFailure = true
                    }
                }
            }
        }
        return hadFailure ? nil : documents
    }

    private func getDocumentsFromIndex(start: Date, end: Date) async -> [String: [[String: Any]]?] {
        var result = emptyDateRange(start: start, end: end)
        for year in yearRange(start: start, end: end) {
            for var doc in await ensureDocumentIndexForYear(year) {
                guard let docDate = documentListDate(doc),
                      docDate >= start && docDate <= end
                else { continue }
                let ds = isoDate(docDate)
                doc.removeValue(forKey: "_edinet_list_date")
                result[ds]?.append(doc)
            }
        }
        return result
    }

    private func getDocumentsDaily(start: Date, end: Date) async -> [String: [[String: Any]]?] {
        var result: [String: [[String: Any]]?] = [:]
        var current = start
        while current <= end {
            let ds = isoDate(current)
            result[ds] = await getDocumentsForDate(ds)
            current = Calendar.current.date(byAdding: .day, value: 1, to: current)!
        }
        return result
    }

    private func documentIndexLock(for year: Int) -> AsyncLock {
        if documentIndexLocks[year] == nil { documentIndexLocks[year] = AsyncLock() }
        return documentIndexLocks[year]!
    }
}

// MARK: - Helpers

private nonisolated(unsafe) let _isoDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
}()

private func isoDate(_ date: Date) -> String {
    _isoDateFormatter.string(from: date)
}

private func documentListDate(_ doc: [String: Any]) -> Date? {
    if let s = doc["_edinet_list_date"] as? String, let d = parseDateString(s) { return d }
    if let s = doc["submitDateTime"] as? String, let d = parseDateString(normalizeDateFormat(s)) { return d }
    return nil
}

private func emptyDateRange(start: Date, end: Date) -> [String: [[String: Any]]?] {
    var result: [String: [[String: Any]]?] = [:]
    var current = start
    while current <= end {
        result[isoDate(current)] = [] as [[String: Any]]
        current = Calendar.current.date(byAdding: .day, value: 1, to: current)!
    }
    return result
}

private func mergeDocumentIndexDocs(
    existing: [[String: Any]],
    byDate: [String: [[String: Any]]]
) -> [[String: Any]] {
    var seen = Set<String>()
    var merged: [[String: Any]] = []

    func append(_ doc: [String: Any], listDate: String? = nil) {
        var d = doc
        if let ld = listDate { d["_edinet_list_date"] = ld }
        let docID = d["docID"] as? String ?? ""
        let date = d["_edinet_list_date"] as? String ?? d["submitDateTime"] as? String ?? ""
        let key = "\(docID)|\(date)"
        guard !seen.contains(key) else { return }
        seen.insert(key)
        merged.append(d)
    }
    for doc in existing { append(doc) }
    for listDate in byDate.keys.sorted() {
        for doc in byDate[listDate] ?? [] { append(doc, listDate: listDate) }
    }
    return merged
}

private func yearRange(start: Date, end: Date) -> [Int] {
    let s = Calendar.current.component(.year, from: start)
    let e = Calendar.current.component(.year, from: end)
    return Array(s...e)
}

// MARK: - Concurrency helpers

final class AsyncSemaphore: @unchecked Sendable {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    init(value: Int) { self.value = value }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            if value > 0 { value -= 1; continuation.resume() }
            else { waiters.append(continuation) }
        }
    }

    func signal() {
        lock.lock(); defer { lock.unlock() }
        if waiters.isEmpty { value += 1 }
        else { waiters.removeFirst().resume() }
    }
}

final class AsyncLock: @unchecked Sendable {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let mutex = NSLock()

    func lock() async {
        await withCheckedContinuation { continuation in
            mutex.lock(); defer { mutex.unlock() }
            if !isLocked { isLocked = true; continuation.resume() }
            else { waiters.append(continuation) }
        }
    }

    func unlock() {
        mutex.lock(); defer { mutex.unlock() }
        if waiters.isEmpty { isLocked = false }
        else { waiters.removeFirst().resume() }
    }
}

// MARK: - Errors

enum EdinetError: Error {
    case noApiKey
    case invalidApiKey(String)
    case apiError(Int, String)
    case invalidResponse
    case invalidURL
    case maxRetriesExceeded
}
