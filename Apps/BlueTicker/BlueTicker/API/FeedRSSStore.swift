import Foundation

/// Top feed の公開 RSS（`FeedRSS.url`）の端末保存と条件付き GET。
/// 生の XML と `ETag` / `Last-Modified` / 取得時刻を Caches に 1 ファイルで持つ（置き場所は `ResponseCache` にそろえる）。
/// 前回の取得から `FeedRSS.revalidateInterval`（RSS の `max-age`）以内は再検証しない。
/// 304 は取得時刻だけ進め、200 は保存を差し替える。失敗しても保存は消さない。
/// REST（`/v1/feed/updates`）へはフォールバックしない。
actor FeedRSSStore {
    static let shared = FeedRSSStore()

    private let fileURL: URL
    private let session: URLSession
    private let fileDecoder: JSONDecoder
    private let fileEncoder: JSONEncoder
    private var record: FeedRSS.Record?
    private var restored = false

    init(directory: URL? = nil) {
        let base: URL
        if let directory {
            base = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            base = caches
                .appendingPathComponent("blt-feed", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        }
        fileURL = base.appendingPathComponent("edinet-filings.json")
        // 検証子はこちらで持つので URLCache には二重に保存しない。
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        fileDecoder = decoder
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        fileEncoder = encoder
    }

    /// 保存済みの RSS を解析し、Top feed に出す行（有報だけ）を返す。保存が無い・読めなければ `nil`。
    /// 読めない保存は検証子ごと忘れ、次の再検証を全件取得にする。
    func cachedItems() -> [FeedRSS.Item]? {
        guard let record = restoredRecord() else { return nil }
        guard let items = FeedRSS.parse(record.xml) else {
            self.record = nil
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return FeedRSS.topFeed(items)
    }

    func needsRevalidation(now: Date = Date()) -> Bool {
        FeedRSS.needsRevalidation(restoredRecord(), now: now)
    }

    /// 条件付き GET を送る。200 で解析できたときだけ新しい一覧（有報だけ）を返す（304・失敗・cancel は `nil`）。
    func revalidate(now: Date = Date()) async -> [FeedRSS.Item]? {
        let previous = restoredRecord()
        var request = URLRequest(url: FeedRSS.url)
        for (field, value) in FeedRSS.requestHeaders(for: previous) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let data: Data
        let http: HTTPURLResponse
        do {
            let (body, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return nil }
            data = body
            http = response
        } catch {
            return nil
        }
        let outcome = FeedRSS.outcome(
            status: http.statusCode,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            body: data,
            previous: previous,
            now: now
        )
        switch outcome {
        case .notModified(let updated):
            save(updated)
            return nil
        case .replaced(let updated, let items):
            save(updated)
            return FeedRSS.topFeed(items)
        case .failed:
            return nil
        }
    }

    private func restoredRecord() -> FeedRSS.Record? {
        if !restored {
            restored = true
            if let raw = try? Data(contentsOf: fileURL) {
                record = try? fileDecoder.decode(FeedRSS.Record.self, from: raw)
            }
        }
        return record
    }

    private func save(_ updated: FeedRSS.Record) {
        record = updated
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileEncoder.encode(updated).write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }
}
