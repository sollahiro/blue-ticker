//
// 移植対象外:
// - test_stats_counts_cache_categories / test_audit_lists_cache_categories
//   （stats / audit は Swift CachePruner 未実装。実装時に移植する）

import Testing
import Foundation
@testable import BlueTickerCore

@Suite final class CachePrunerTests {
    private let tmpDir: URL
    private let edinetDir: URL

    init() throws {
        tmpDir = try ServiceTestSupport.makeTempDir()
        // 現行レイアウト: cacheDir/external/edinet
        edinetDir = edinetCacheDir(tmpDir)
        try FileManager.default.createDirectory(at: edinetDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeFile(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    @Test func testPruneEdinetByAge() throws {
        let fm = FileManager.default
        let searchDir = edinetDir.appendingPathComponent("documents_by_date", isDirectory: true)
        let oldSearch = searchDir.appendingPathComponent("search_2024-01-01.json")
        let newSearch = searchDir.appendingPathComponent("search_2024-02-01.json")
        try writeFile(oldSearch, "[]")
        try writeFile(newSearch, "[]")
        try ServiceTestSupport.age(oldSearch, days: 40)
        try ServiceTestSupport.age(newSearch, days: 5)

        let xbrlRoot = edinetDir.appendingPathComponent("xbrl", isDirectory: true)
        let oldXbrl = xbrlRoot.appendingPathComponent("S100OLD_xbrl", isDirectory: true)
        let newXbrl = xbrlRoot.appendingPathComponent("S100NEW_xbrl", isDirectory: true)
        try fm.createDirectory(at: oldXbrl, withIntermediateDirectories: true)
        try fm.createDirectory(at: newXbrl, withIntermediateDirectories: true)
        try writeFile(oldXbrl.appendingPathComponent("doc.xbrl"), "old")
        try writeFile(newXbrl.appendingPathComponent("doc.xbrl"), "new")
        try ServiceTestSupport.age(oldXbrl, days: 40)
        try ServiceTestSupport.age(newXbrl, days: 5)

        let summary = CachePruner(cacheDir: tmpDir).prune(
            dryRun: false,
            edinetSearchDays: 30,
            edinetXbrlDays: 30
        )

        #expect(summary.removedFiles == 1)
        #expect(summary.removedDirs == 1)
        #expect(!(fm.fileExists(atPath: oldSearch.path)))
        #expect(fm.fileExists(atPath: newSearch.path))
        #expect(!(fm.fileExists(atPath: oldXbrl.path)))
        #expect(fm.fileExists(atPath: newXbrl.path))
    }

    @Test func testPruneEdinetDocIndexesKeepsRecentYearsByDefault() throws {
        let fm = FileManager.default
        let currentYear = Calendar.current.component(.year, from: Date())
        let indexDir = edinetDir.appendingPathComponent("document_indexes", isDirectory: true)
        let oldIndex = indexDir.appendingPathComponent("doc_index_\(currentYear - 6).json")
        let keptIndex = indexDir.appendingPathComponent("doc_index_\(currentYear - 5).json")
        try writeFile(oldIndex, "{}")
        try writeFile(keptIndex, "{}")

        let summary = CachePruner(cacheDir: tmpDir).prune(dryRun: false)

        #expect(summary.removedFiles == 1)
        #expect(!(fm.fileExists(atPath: oldIndex.path)))
        #expect(fm.fileExists(atPath: keptIndex.path))
    }

    @Test func testPruneEdinetDocIndexesCanKeepCustomYears() throws {
        let fm = FileManager.default
        let currentYear = Calendar.current.component(.year, from: Date())
        let indexDir = edinetDir.appendingPathComponent("document_indexes", isDirectory: true)
        let oldIndex = indexDir.appendingPathComponent("doc_index_\(currentYear - 3).json")
        let keptIndex = indexDir.appendingPathComponent("doc_index_\(currentYear - 2).json")
        try writeFile(oldIndex, "{}")
        try writeFile(keptIndex, "{}")

        let summary = CachePruner(cacheDir: tmpDir).prune(
            dryRun: false,
            edinetDocIndexYears: 3
        )

        #expect(summary.removedFiles == 1)
        #expect(!(fm.fileExists(atPath: oldIndex.path)))
        #expect(fm.fileExists(atPath: keptIndex.path))
    }
}
