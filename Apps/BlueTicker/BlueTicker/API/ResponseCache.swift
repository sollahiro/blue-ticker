import Foundation

struct ResponseCacheRecord: Codable {
    var savedAt: Date
    var data: Data
}

/// 解析 REST（概要・分解・Overview）の端末キャッシュ。
/// 有報は年次なので短時間の再取得を避け、ウォッチリスト銘柄はより長く持つ。
actor ResponseCache {
    static let shared = ResponseCache()

    /// 通常の解析応答。6 時間。
    static let analysisTTL: TimeInterval = 6 * 60 * 60
    /// ウォッチリスト銘柄。7 日。
    static let watchlistTTL: TimeInterval = 7 * 24 * 60 * 60

    private var memory: [String: ResponseCacheRecord] = [:]
    private let directory: URL
    private let fileDecoder: JSONDecoder
    private let fileEncoder: JSONEncoder

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = caches
                .appendingPathComponent("blt-analysis", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        fileDecoder = decoder
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        fileEncoder = encoder
    }

    static func key(for url: URL) -> String {
        let host = url.host ?? "local"
        let path = url.path.replacingOccurrences(of: "/", with: "_")
        let query = url.query.map { "_\($0)" } ?? ""
        return sanitize("\(host)\(path)\(query)")
    }

    func load(key: String, maxAge: TimeInterval?) -> Data? {
        guard let record = record(for: key) else { return nil }
        if let maxAge, Date().timeIntervalSince(record.savedAt) > maxAge {
            return nil
        }
        return record.data
    }

    func store(key: String, data: Data, savedAt: Date = Date()) {
        let record = ResponseCacheRecord(savedAt: savedAt, data: data)
        memory[key] = record
        persist(key: key, record: record)
    }

    private func record(for key: String) -> ResponseCacheRecord? {
        if let memory = memory[key] {
            return memory
        }
        let url = fileURL(for: key)
        guard let raw = try? Data(contentsOf: url),
            let record = try? fileDecoder.decode(ResponseCacheRecord.self, from: raw)
        else {
            return nil
        }
        memory[key] = record
        return record
    }

    private func persist(key: String, record: ResponseCacheRecord) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let raw = try fileEncoder.encode(record)
            try raw.write(to: fileURL(for: key), options: .atomic)
        } catch {
            return
        }
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    private static func sanitize(_ raw: String) -> String {
        String(
            raw.map { character in
                character.isLetter || character.isNumber || character == "-" || character == "_"
                    || character == "." ? character : "_"
            }
        )
    }
}
