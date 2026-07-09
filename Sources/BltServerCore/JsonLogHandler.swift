// JSON 1 行ログ（stdout/stderr）。Fly / launchd のログを機械可読にし、
// ingest 失敗・DB リトライ等を grep / 転送先で拾いやすくする。
// 外部パッケージは追加せず swift-log の LogHandler を自前実装する。

import Foundation
import Logging

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    @preconcurrency import Glibc
#endif

/// 1 イベントを 1 行の JSON として書き出す `LogHandler`。
/// FILE* と DateFormatter を共有するため class + lock（StreamLogHandler と同型の妥協）。
final class JsonLogHandler: LogHandler, @unchecked Sendable {
    private let label: String
    private let stream: UnsafeMutablePointer<FILE>
    private let lock = NSLock()
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?

    static func standardError(label: String) -> JsonLogHandler {
        JsonLogHandler(label: label, stream: stderr)
    }

    static func standardOutput(label: String) -> JsonLogHandler {
        JsonLogHandler(label: label, stream: stdout)
    }

    init(label: String, stream: UnsafeMutablePointer<FILE>) {
        self.label = label
        self.stream = stream
    }

    subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get { metadata[metadataKey] }
        set { metadata[metadataKey] = newValue }
    }

    func log(event: LogEvent) {
        var merged = metadata
        if let provided = metadataProvider?.get() {
            merged.merge(provided, uniquingKeysWith: { _, new in new })
        }
        if let explicit = event.metadata {
            merged.merge(explicit, uniquingKeysWith: { _, new in new })
        }

        lock.lock()
        defer { lock.unlock() }

        var object: [String: Any] = [
            "timestamp": isoFormatter.string(from: Date()),
            "level": event.level.rawValue,
            "logger": label,
            "message": event.message.description,
        ]
        if !merged.isEmpty {
            object["metadata"] = Self.jsonObject(from: merged)
        }

        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        fputs(line, stream)
        fflush(stream)
    }

    private static func jsonObject(from metadata: Logger.Metadata) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in metadata {
            result[key] = jsonValue(from: value)
        }
        return result
    }

    private static func jsonValue(from value: Logger.Metadata.Value) -> Any {
        switch value {
        case .string(let s):
            return s
        case .stringConvertible(let s):
            return s.description
        case .array(let values):
            return values.map { jsonValue(from: $0) }
        case .dictionary(let dict):
            return jsonObject(from: dict)
        }
    }
}
