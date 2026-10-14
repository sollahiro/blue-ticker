// キャッシュ済み XBRL でタグ経路 vs Jev overlay の sga / sga_label 差分を出す。
// 本番 write はしない。OPENROUTER_DECISION_API_KEY が無いときは overlay をスキップ。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct SgaJevCorpusScanTests {
    private static let cacheRoots: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl"),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp_cache/edinet"),
    ]

    @Test func reportSgaChangesAgainstTaggedPath() async throws {
        guard ProcessInfo.processInfo.environment["BLT_SGA_CORPUS"] == "1" else {
            print("SKIP corpus (set BLT_SGA_CORPUS=1)")
            return
        }
        let fm = FileManager.default
        var dirs: [String: URL] = [:]
        for root in Self.cacheRoots {
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names where name.hasSuffix("_xbrl") {
                let docID = String(name.dropLast("_xbrl".count))
                let dir = root.appendingPathComponent(name)
                if dirs[docID] == nil { dirs[docID] = dir }
            }
        }
        let sorted = dirs.keys.sorted()
        print("CORPUS docs=\(sorted.count)")
        guard let endpoint = resolveOpenRouterDecisionsEndpoint() else {
            print("CORPUS Jev skipped (no OPENROUTER_DECISION_API_KEY)")
            print("CORPUS changed=0")
            return
        }
        let client = OpenRouterDecisionsClient(endpoint: endpoint)
        let decider = OpenRouterSgaLineDecider(client: client)
        var changed: [String] = []
        var filled = 0
        var nilStay = 0
        var tagged = 0
        for docID in sorted {
            guard let dir = dirs[docID] else { continue }
            guard let taggedValues = StatementFinancialsResolver.resolve(xbrlDir: dir) else {
                continue
            }
            if taggedValues.sga != nil {
                tagged += 1
                continue
            }
            let overlay = await StatementFinancialsResolver.resolve(
                xbrlDir: dir, sgaLineDecider: decider)
            let newSga = overlay?.sga
            let newLabel = overlay?.sgaLabel
            if newSga == taggedValues.sga, newLabel == taggedValues.sgaLabel {
                nilStay += 1
                continue
            }
            filled += 1
            let million = Financial.millionYen
            let sgaNote = newSga.map { String(Int(($0 / million).rounded())) } ?? "null"
            let labelNote = newLabel ?? "null"
            let line = "\(docID) sga \(sgaNote) label \(labelNote)"
            changed.append(line)
            print("CORPUS_CHANGE \(line)")
        }
        print("CORPUS tagged=\(tagged) nil_stay=\(nilStay) filled=\(filled) changed=\(changed.count)")
        for line in changed { print("CORPUS_DOC \(line)") }
    }
}
