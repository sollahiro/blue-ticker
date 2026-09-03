// JSON 1 行ログ（stdout/stderr）。Fly / launchd のログを機械可読にし、
// ingest 失敗・DB リトライ等を grep / 転送先で拾いやすくする。
// 外部パッケージは追加せず swift-log の LogHandler を自前実装する。
//
// C の stderr/stdout は使わない。Glibc のグローバル var は Swift 6 の並行性
// チェックに通らないため、FileHandle.standardError / standardOutput に寄せる
//（Utils/StandardError.swift・`.agents/rules/data-handling.md` と同じ方針）。

import Foundation
import Logging

/// 1 イベントを 1 行の JSON として書き出す `LogHandler`。
/// DateFormatter と書き出しを共有するため class + lock（StreamLogHandler と同型の妥協）。
final class JsonLogHandler: LogHandler, @unchecked Sendable {
    private let label: String
    private let handle: FileHandle
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
        JsonLogHandler(label: label, handle: .standardError)
    }

    static func standardOutput(label: String) -> JsonLogHandler {
        JsonLogHandler(label: label, handle: .standardOutput)
    }

    init(label: String, handle: FileHandle) {
        self.label = label
        self.handle = handle
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
            "message": redactSecrets(event.message.description),
        ]
        if !merged.isEmpty {
            object["metadata"] = Self.jsonObject(from: merged)
        }

        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object)
        else { return }
        var line = data
        line.append(0x0A)  // '\n'
        handle.write(line)
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
            return redactSecrets(s)
        case .stringConvertible(let s):
            return redactSecrets(s.description)
        case .array(let values):
            return values.map { jsonValue(from: $0) }
        case .dictionary(let dict):
            return jsonObject(from: dict)
        }
    }
}
