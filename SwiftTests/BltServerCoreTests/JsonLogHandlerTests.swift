// JsonLogHandler が 1 行 JSON を出し、metadata をネストすることを検証する。

import Foundation
import Logging
import Testing

@testable import BltServerCore

@Suite struct JsonLogHandlerTests {
    @Test func formatsOneLineJsonWithMetadata() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("blt-json-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: tmp) }

        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: tmp.path) else {
            Issue.record("failed to open temp log file")
            return
        }
        defer { try? handle.close() }

        let handler = JsonLogHandler(label: "test.logger", handle: handle)
        handler.logLevel = .trace
        handler.log(
            event: LogEvent(
                level: .notice,
                message: "ingest summary",
                metadata: [
                    "event": "ingest_summary",
                    "target": "financials",
                    "failed": .stringConvertible(0),
                ],
                source: "test",
                file: #file,
                function: #function,
                line: #line
            ))
        try handle.synchronize()

        let raw = try String(contentsOf: tmp, encoding: .utf8)
        let line = try #require(raw.split(separator: "\n").first.map(String.init))
        let data = try #require(line.data(using: .utf8))
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["level"] as? String == "notice")
        #expect(json["logger"] as? String == "test.logger")
        #expect(json["message"] as? String == "ingest summary")
        #expect(json["timestamp"] is String)
        let metadata = try #require(json["metadata"] as? [String: Any])
        #expect(metadata["event"] as? String == "ingest_summary")
        #expect(metadata["target"] as? String == "financials")
        #expect(metadata["failed"] as? String == "0")
    }

    @Test func logIngestSummaryUsesWarningWhenFailed() {
        let handler = CapturingHandler()
        let logger = Logger(label: "test") { _ in handler }
        logIngestSummary(logger, target: "financials", attempted: 3, stored: 2, failed: 1, skipped: 0)
        #expect(handler.messages.count == 1)
        #expect(handler.messages[0].level == .warning)
        #expect(handler.messages[0].metadata["event"] == .string("ingest_summary"))
        #expect(handler.messages[0].metadata["failed"]?.description == "1")

        handler.messages.removeAll()
        logIngestSummary(logger, target: "financials", attempted: 3, stored: 3, failed: 0, skipped: 0)
        #expect(handler.messages[0].level == .notice)
    }
}

private final class CapturingHandler: LogHandler, @unchecked Sendable {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    var messages: [(level: Logger.Level, metadata: Logger.Metadata)] = []

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        messages.append((event.level, event.metadata ?? [:]))
    }
}
