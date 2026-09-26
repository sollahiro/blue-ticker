import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import BlueTickerCore

enum PocJevIO {
    static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static var pocDir: URL { repoRoot().appendingPathComponent("scripts/poc-jev") }
    static var dataDir: URL { pocDir.appendingPathComponent("snapshots") }
    static var outDir: URL { pocDir.appendingPathComponent("out") }

    static func loadJSONArray(_ name: String) throws -> [[String: Any]] {
        let url = dataDir.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "PocJev", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected JSON array in \(name)",
            ])
        }
        return arr
    }

    static func writeJSONL(_ rows: [[String: Any]], to name: String) throws -> URL {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let url = outDir.appendingPathComponent(name)
        var lines: [String] = []
        lines.reserveCapacity(rows.count)
        for row in rows {
            let data = try JSONSerialization.data(
                withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
            guard let line = String(data: data, encoding: .utf8) else { continue }
            lines.append(line)
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func writeText(_ text: String, to name: String) throws -> URL {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let url = outDir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func writeJSON(_ obj: Any, to name: String) throws -> URL {
        let data = try JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return try writeText(String(data: data, encoding: .utf8) ?? "{}", to: name)
    }

    static let artifactNames = [
        "part_a_audit.json", "part_a_audit.md", "export_report.json",
        "table_select_segment_info.jsonl", "table_select_geography.jsonl",
        "cell_select_segment_info.jsonl", "cell_select_geography.jsonl",
        "usable_segment_info.jsonl", "usable_geography.jsonl",
        "usable_revenue_recognition.jsonl",
        "table_select_notes.jsonl", "cell_select_notes.jsonl",
        "period_audit_downloaded.jsonl",
    ]

    static func copyToArtifacts() {
        let artifacts = URL(fileURLWithPath: "/opt/cursor/artifacts")
        guard FileManager.default.fileExists(atPath: artifacts.path) else { return }
        for name in artifactNames {
            let src = outDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let dest = artifacts.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: src, to: dest)
        }
    }
}

/// R2 GET only. `putObject` is a hard no-op so EDINET fallback never uploads.
struct GetOnlyXbrlStore: XbrlObjectStoring {
    let inner: R2XbrlObjectStore
    func getObject(key: String) async -> Data? { await inner.getObject(key: key) }
    func putObject(_ data: Data, key: String, contentType: String) async -> Bool { false }
}

enum PocJevJSON {
    static func string(_ obj: Any?, _ key: String) -> String? {
        (obj as? [String: Any])?[key] as? String
    }

    static func int(_ obj: Any?, _ key: String) -> Int? {
        let v = (obj as? [String: Any])?[key]
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func double(_ obj: Any?, _ key: String) -> Double? {
        let v = (obj as? [String: Any])?[key]
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}
