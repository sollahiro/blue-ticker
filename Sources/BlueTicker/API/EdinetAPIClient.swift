import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

    func getDocumentsForDate(_ dateStr: String) async -> sending [[String: Any]]? {
        let cacheKey = cacheStore.searchCacheKey(dateStr)
        if let cached = cacheStore.loadSearchCache(cacheKey) { return cached }

        // ファイルロックでプロセス間の重複取得を防ぎ、セマフォで並列API呼び出し数を制限する
        // actor プロパティを @Sendable クロージャ境界を渡す前にキャプチャする
        let cs = cacheStore
        let semaphore = dateFetchSemaphore
        do {
            return try await cacheStore.withFileLock("search_\(dateStr)") {
                if let cached = cs.loadSearchCache(cacheKey) { return cached }
                await semaphore.wait()
                defer { semaphore.signal() }
                if let cached = cs.loadSearchCache(cacheKey) { return cached }
                let data = try await self.request("/documents.json", params: ["date": dateStr, "type": "2"])
                let docs = data["results"] as? [[String: Any]] ?? []
                cs.saveSearchCache(cacheKey, data: docs)
                return docs
            }
        } catch {
            return cacheStore.loadSearchCache(cacheKey, allowExpired: true)
        }
    }

    // MARK: - 年次書類インデックス

    func refreshDocumentIndexForYear(_ year: Int) async -> sending [[String: Any]] {
        let yearEnd = utcCalendar.date(from: DateComponents(year: year, month: 12, day: 31))!
        let requiredDate = min(yearEnd, utcStartOfDay(Date()))
        let persistableThrough = formatDateString(safeBuiltThroughDate(requiredDate: requiredDate))

        let cs = cacheStore
        let lock = documentIndexLock(for: year)
        do {
            let docs: [[String: Any]] = try await cacheStore.withFileLock("doc_index_\(year)") {
                await lock.lock()
                defer { lock.unlock() }
                cs.clearDocumentIndex(year)
                guard let built = await self.buildDocumentIndexForYear(year, requiredThrough: requiredDate)
                else { return [] }
                cs.saveDocumentIndex(year, documents: built, builtThrough: persistableThrough)
                return built
            }
            pruneDocumentIndexLock(year: year, lock: lock)
            return docs
        } catch {
            return []
        }
    }

    /// 年次書類インデックスの `built_through` 以降の不足分だけ差分取得して追補する。
    ///
    /// 当日を含む取得は built_through を当日にせず前日までに留める（`safeBuiltThroughDate`）。
    /// EDINET は当日の書類一覧を営業時間中随時更新するため、当日を「完了」扱いにすると、
    /// この関数を呼び直しても当日分の再取得判定（`startDate > requiredDate`）が常に真になり、
    /// 後から提出された書類（有報等）を二度と取り込めなくなる（実例: 2026-06-29 提出の有報欠落）。
    /// 前日までに留めることで、当日は日次検索キャッシュ側の TTL（`Api.searchTodayTTLHours`）が
    /// 満了するたびに再取得され続け、日境界を跨いだ翌日の呼び出しで初めて前日分が確定する。
    func catchupDocumentIndexForYear(_ year: Int) async -> sending [[String: Any]] {
        let yearEnd = utcCalendar.date(from: DateComponents(year: year, month: 12, day: 31))!
        let requiredDate = min(yearEnd, utcStartOfDay(Date()))
        let requiredThrough = formatDateString(requiredDate)
        let persistableThrough = formatDateString(safeBuiltThroughDate(requiredDate: requiredDate))

        let cs = cacheStore
        let lock = documentIndexLock(for: year)
        do {
            let docs: [[String: Any]] = try await cacheStore.withFileLock("doc_index_\(year)") {
                await lock.lock()
                defer { lock.unlock() }

                guard let info = cs.loadDocumentIndexInfo(year, requiredThrough: requiredThrough, allowStale: true) else {
                    guard let built = await self.buildDocumentIndexForYear(year, requiredThrough: requiredDate) else { return [] }
                    cs.saveDocumentIndex(year, documents: built, builtThrough: persistableThrough)
                    return built
                }

                let existingDocs = info["documents"] as? [[String: Any]] ?? []
                guard let builtStr = info["built_through"] as? String,
                      let builtDate = parseDateString(builtStr),
                      builtDate < requiredDate
                else { return existingDocs }

                let startDate = utcCalendar.date(byAdding: .day, value: 1, to: builtDate)!
                if startDate > requiredDate {
                    // 取得すべき差分日が無い。built_through が変わる場合のみ書き込む。
                    if persistableThrough != builtStr {
                        cs.saveDocumentIndex(year, documents: existingDocs, builtThrough: persistableThrough)
                    }
                    return existingDocs
                }

                let newByDate = await self.getDocumentsForDateRange(start: startDate, end: requiredDate, useIndex: false)
                if newByDate.values.contains(where: { $0 == nil }) { return existingDocs }
                let merged = mergeDocumentIndexDocs(existing: existingDocs, byDate: newByDate.compactMapValues { $0 })
                // 内容・built_through のいずれかが変わった時だけ書き込む（同日内の呼び出しごとの
                // 無駄なフル書き込みを避ける。当日は毎回この分岐へ来るため効果が大きい）。
                if merged.count != existingDocs.count || persistableThrough != builtStr {
                    cs.saveDocumentIndex(year, documents: merged, builtThrough: persistableThrough)
                }
                return merged
            }
            pruneDocumentIndexLock(year: year, lock: lock)
            return docs
        } catch {
            return cacheStore.loadDocumentIndex(year, requiredThrough: requiredThrough, allowStale: true) ?? []
        }
    }

    // MARK: - 日付範囲

    nonisolated func getDocumentsForDateRange(
        start: Date,
        end: Date,
        useIndex: Bool = true
    ) async -> sending [String: [[String: Any]]?] {
        guard start <= end else { return [:] }
        let days = utcCalendar.dateComponents([.day], from: start, to: end).day! + 1
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
        defer {
            lock.unlock()
            pruneDownloadLock(docID: docID, lock: lock)
        }

        if cacheStore.hasXbrlDir(docID, saveDir: dir) {
            cacheStore.touchXbrlDir(docID, saveDir: dir)
            return dest
        }
        guard apiKey?.isEmpty == false else { return nil }

        // ファイルロックでプロセス間の同一 docID 同時取得・展開を防ぎ、セマフォで並列ダウンロード数を制限する
        // actor プロパティを @Sendable クロージャ境界を渡す前にキャプチャする
        let cs = cacheStore
        let semaphore = xbrlDownloadSemaphore
        do {
            return try await cacheStore.withFileLock("xbrl_\(docID)") {
                if cs.hasXbrlDir(docID, saveDir: dir) {
                    cs.touchXbrlDir(docID, saveDir: dir)
                    return dest
                }
                await semaphore.wait()
                defer { semaphore.signal() }
                let content = try await self.requestBinary("/documents/\(docID)", params: ["type": "1"])
                return try cs.storeXbrlZip(docID, content: content, saveDir: dir)
            }
        } catch {
            return nil
        }
    }

    /// ローカルに展開済みの XBRL がある docID。内訳取り込みの処理順用（再ダウンロードしない）。
    func cachedXbrlDocIDs() -> Set<String> {
        cacheStore.cachedXbrlDocIDs()
    }

    // MARK: - HTTP

    private func request(_ endpoint: String, params: [String: String] = [:], maxRetries: Int = 3) async throws -> sending [String: Any] {
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

    private func buildDocumentIndexForYear(_ year: Int, requiredThrough: Date) async -> sending [[String: Any]]? {
        let start = utcCalendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        var dates: [Date] = []
        var current = start
        while current <= requiredThrough {
            dates.append(current)
            current = utcCalendar.date(byAdding: .day, value: 1, to: current)!
        }

        var documents: [[String: Any]] = []
        var hadFailure = false
        let batchSize = Api.documentIndexBatchSize

        for i in stride(from: 0, to: dates.count, by: batchSize) {
            let batch = Array(dates[i..<min(i + batchSize, dates.count)])
            // 外部変数を @Sendable addTask クロージャ境界に渡さないよう結果をまとめて返す
            let batchResults = await withTaskGroup(of: DateDocsResult.self, returning: [DateDocsResult].self) { group in
                for date in batch {
                    let ds = formatDateString(date)
                    group.addTask { DateDocsResult(dateStr: ds, docs: await self.getDocumentsForDate(ds)) }
                }
                var results: [DateDocsResult] = []
                for await r in group { results.append(r) }
                return results
            }
            for r in batchResults {
                if let docs = r.docs {
                    for var doc in docs {
                        doc["_edinet_list_date"] = r.dateStr
                        documents.append(doc)
                    }
                } else {
                    hadFailure = true
                }
            }
        }
        return hadFailure ? nil : documents
    }

    private nonisolated func getDocumentsFromIndex(start: Date, end: Date) async -> sending [String: [[String: Any]]?] {
        var result = emptyDateRange(start: start, end: end)
        // actor 隔離メソッドの await 結果を直接 result へ取り込むと、古いコンパイラ
        // （Swift 6.0/6.1）が docs を self-isolated と判定し sending 返却を拒否する。
        // getDocumentsDaily / buildDocumentIndexForYear と同様に TaskGroup を介して
        // 領域を転送することで回避する。年は yearRange で重複なく分かれているため、
        // 同一日付バケットの docs は単一年からのみ来る（出力は逐次処理時と等価）。
        let yearDocs = await withTaskGroup(of: YearDocsResult.self, returning: [YearDocsResult].self) { group in
            for year in yearRange(start: start, end: end) {
                group.addTask { YearDocsResult(docs: await self.catchupDocumentIndexForYear(year)) }
            }
            var results: [YearDocsResult] = []
            for await r in group { results.append(r) }
            return results
        }
        for yd in yearDocs {
            for var doc in yd.docs {
                guard let docDate = documentListDate(doc),
                      docDate >= start && docDate <= end
                else { continue }
                let ds = formatDateString(docDate)
                doc.removeValue(forKey: "_edinet_list_date")
                if var arr = result[ds] ?? nil {
                    arr.append(doc)
                    result[ds] = arr
                }
            }
        }
        return result
    }

    private nonisolated func getDocumentsDaily(start: Date, end: Date) async -> sending [String: [[String: Any]]?] {
        var dates: [String] = []
        var current = start
        while current <= end {
            dates.append(formatDateString(current))
            current = utcCalendar.date(byAdding: .day, value: 1, to: current)!
        }

        var result: [String: [[String: Any]]?] = [:]
        let batchSize = Api.documentIndexBatchSize
        for i in stride(from: 0, to: dates.count, by: batchSize) {
            let batch = Array(dates[i..<min(i + batchSize, dates.count)])
            let batchResults = await withTaskGroup(of: DateDocsResult.self, returning: [DateDocsResult].self) { group in
                for ds in batch {
                    group.addTask { DateDocsResult(dateStr: ds, docs: await self.getDocumentsForDate(ds)) }
                }
                var results: [DateDocsResult] = []
                for await r in group { results.append(r) }
                return results
            }
            for r in batchResults { result[r.dateStr] = r.docs }
        }
        return result
    }

    private func documentIndexLock(for year: Int) -> AsyncLock {
        if documentIndexLocks[year] == nil { documentIndexLocks[year] = AsyncLock() }
        return documentIndexLocks[year]!
    }

    private func pruneDownloadLock(docID: String, lock: AsyncLock) {
        if lock.isIdle { downloadLocks.removeValue(forKey: docID) }
    }

    private func pruneDocumentIndexLock(year: Int, lock: AsyncLock) {
        if lock.isIdle { documentIndexLocks.removeValue(forKey: year) }
    }
}

// MARK: - Helpers

// EDINET の日付ラベル（YYYY-MM-DD）は UTC 固定の共有 `utcCalendar`（Utils/UTCCalendar.swift）を使う。

private func documentListDate(_ doc: [String: Any]) -> Date? {
    if let s = doc["_edinet_list_date"] as? String, let d = parseDateString(s) { return d }
    if let s = doc["submitDateTime"] as? String, let d = parseDateString(normalizeDateFormat(s)) { return d }
    return nil
}

private func emptyDateRange(start: Date, end: Date) -> [String: [[String: Any]]?] {
    var result: [String: [[String: Any]]?] = [:]
    var current = start
    while current <= end {
        result[formatDateString(current)] = [] as [[String: Any]]
        current = utcCalendar.date(byAdding: .day, value: 1, to: current)!
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
    let s = utcCalendar.component(.year, from: start)
    let e = utcCalendar.component(.year, from: end)
    return Array(s...e)
}

/// 年次書類インデックスの `built_through` として永続化してよい安全な上限日を返す。
/// `requiredDate` が当日以降（＝今年分をまだ取得中）なら前日までに留め、当日を
/// 「確定済み」として永久にマークしない（EDINET が当日の書類一覧を随時更新するため）。
/// 既に年末まで到達した過去年はそのまま `requiredDate` を返す（キャップ不要）。
private func safeBuiltThroughDate(requiredDate: Date, today: Date = Date()) -> Date {
    let todayStart = utcStartOfDay(today)
    guard requiredDate >= todayStart else { return requiredDate }
    return utcCalendar.date(byAdding: .day, value: -1, to: todayStart)!
}

// withTaskGroup の子タスク結果を運ぶ型。[[String: Any]] は Sendable 非準拠のため
// @unchecked Sendable でラップし、値が actor 内でのみ生成・消費されることを明示する。
private struct DateDocsResult: @unchecked Sendable {
    let dateStr: String
    let docs: [[String: Any]]?
}

// 年次インデックスの子タスク結果を運ぶ型。DateDocsResult と同じ理由で @unchecked Sendable。
private struct YearDocsResult: @unchecked Sendable {
    let docs: [[String: Any]]
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

    var isIdle: Bool {
        mutex.lock(); defer { mutex.unlock() }
        return !isLocked && waiters.isEmpty
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
