import Foundation

/// 業種ベンチマークの静的 JSON（`workers/benchmark-static` が毎日 R2 に生成）の端末保存と条件付き GET。
/// 中身は `GET /v1/benchmark/{group}` と同じ JSON。HAPIS・トークン・オリジン・Neon を通らない。
/// 生の JSON と `ETag` / `Last-Modified` / 取得時刻を Caches に業種ごと 1 ファイルで持つ（`FeedRSSStore` と同じ方式）。
/// 前回の取得から `revalidateInterval`（配信側の `max-age`）以内は再検証しない。
/// 304 は取得時刻だけ進め、200 は保存を差し替える。失敗しても保存は消さない。
/// 静的 JSON が取れない（未生成・通信失敗）ときのフォールバックは呼び出し側（REST）が担う。
actor BenchmarkStaticStore {
    static let shared = BenchmarkStaticStore()

    static let baseURL = URL(string: "https://feed.sollahiro.com/blue-ticker/benchmark/")!
    /// 配信側の `Cache-Control: max-age=3600` に合わせる。
    static let revalidateInterval: TimeInterval = 60 * 60
    /// 読める応答の `schema_version`。違う版は使わず（保存も捨て）REST に任せる。
    static let supportedSchemaVersion = 1

    struct Record: Codable, Equatable, Sendable {
        var body: Data
        var etag: String?
        var lastModified: String?
        var fetchedAt: Date
    }

    enum Outcome: Equatable, Sendable {
        case notModified(Record)
        case replaced(Record)
        case failed
    }

    static func url(group: String) -> URL {
        baseURL.appendingPathComponent("\(group).json")
    }

    /// 保存が無い、または前回の取得から `revalidateInterval` 以上経っていれば再検証する。
    /// 端末の時計が戻って取得時刻が未来になったときも再検証する。
    static func needsRevalidation(_ record: Record?, now: Date) -> Bool {
        guard let record else { return true }
        let age = now.timeIntervalSince(record.fetchedAt)
        return age < 0 || age >= revalidateInterval
    }

    static func requestHeaders(for record: Record?) -> [String: String] {
        var headers = ["Accept": "application/json"]
        if let etag = record?.etag, !etag.isEmpty { headers["If-None-Match"] = etag }
        if let lastModified = record?.lastModified, !lastModified.isEmpty {
            headers["If-Modified-Since"] = lastModified
        }
        return headers
    }

    /// 読めて、読める版で、会社が 1 社以上ある応答だけ返す。
    static func decode(_ body: Data) -> BenchmarkResponse? {
        guard let response = try? JSONDecoder().decode(BenchmarkResponse.self, from: body),
            response.schemaVersion == supportedSchemaVersion, !response.companies.isEmpty
        else { return nil }
        return response
    }

    static func outcome(
        status: Int, etag: String?, lastModified: String?, body: Data, previous: Record?, now: Date
    ) -> Outcome {
        switch status {
        case 304:
            guard var record = previous else { return .failed }
            record.fetchedAt = now
            if let etag, !etag.isEmpty { record.etag = etag }
            if let lastModified, !lastModified.isEmpty { record.lastModified = lastModified }
            return .notModified(record)
        case 200..<300:
            guard decode(body) != nil else { return .failed }
            return .replaced(Record(body: body, etag: etag, lastModified: lastModified, fetchedAt: now))
        default:
            return .failed
        }
    }

    private let directory: URL
    private let session: URLSession
    private let fileDecoder: JSONDecoder
    private let fileEncoder: JSONEncoder
    private var records: [String: Record] = [:]
    private var restored: Set<String> = []

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = caches
                .appendingPathComponent("blt-benchmark", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        fileDecoder = decoder
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        fileEncoder = encoder
    }

    /// 保存済みの応答。保存が無い・読めなければ `nil`（読めない保存は検証子ごと忘れる）。
    func cached(group: String) -> BenchmarkResponse? {
        guard let record = restoredRecord(group: group) else { return nil }
        guard let response = Self.decode(record.body) else {
            records[group] = nil
            try? FileManager.default.removeItem(at: fileURL(group: group))
            return nil
        }
        return response
    }

    func needsRevalidation(group: String, now: Date = Date()) -> Bool {
        Self.needsRevalidation(restoredRecord(group: group), now: now)
    }

    /// 条件付き GET を送る。200 で読めたときだけ新しい応答を返す（304・失敗・cancel は `nil`）。
    func revalidate(group: String, now: Date = Date()) async -> BenchmarkResponse? {
        let previous = restoredRecord(group: group)
        var request = URLRequest(url: Self.url(group: group))
        for (field, value) in Self.requestHeaders(for: previous) {
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
        switch Self.outcome(
            status: http.statusCode,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            body: data, previous: previous, now: now)
        {
        case .notModified(let updated):
            save(updated, group: group)
            return nil
        case .replaced(let updated):
            save(updated, group: group)
            return Self.decode(updated.body)
        case .failed:
            return nil
        }
    }

    private func fileURL(group: String) -> URL {
        directory.appendingPathComponent("\(group).json")
    }

    private func restoredRecord(group: String) -> Record? {
        if !restored.contains(group) {
            restored.insert(group)
            if let raw = try? Data(contentsOf: fileURL(group: group)) {
                records[group] = try? fileDecoder.decode(Record.self, from: raw)
            }
        }
        return records[group]
    }

    private func save(_ updated: Record, group: String) {
        records[group] = updated
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileEncoder.encode(updated).write(to: fileURL(group: group), options: .atomic)
        } catch {
            return
        }
    }
}
