// Python tests/test_cache_pruner.py の移植
//
// 移植対象外:
// - test_stats_counts_cache_categories / test_audit_lists_cache_categories
//   （stats / audit は Swift CachePruner 未実装。実装時に移植する）

import XCTest
@testable import BlueTicker

final class CachePrunerTests: XCTestCase {
    private var tmpDir: URL!
    private var edinetDir: URL!

    override func setUpWithError() throws {
        tmpDir = try ServiceTestSupport.makeTempDir()
        // 旧形式レイアウト（cacheDir/edinet）。Python テストと同じ配置
        edinetDir = tmpDir.appendingPathComponent("edinet", isDirectory: true)
        try FileManager.default.createDirectory(at: edinetDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeFile(_ url: URL, _ content: String) throws {
        try Data(content.utf8).write(to: url)
    }

    func testPruneEdinetByAge() throws {
        let fm = FileManager.default
        let oldSearch = edinetDir.appendingPathComponent("search_2024-01-01.json")
        let newSearch = edinetDir.appendingPathComponent("search_2024-02-01.json")
        try writeFile(oldSearch, "[]")
        try writeFile(newSearch, "[]")
        try ServiceTestSupport.age(oldSearch, days: 40)
        try ServiceTestSupport.age(newSearch, days: 5)

        let oldXbrl = edinetDir.appendingPathComponent("S100OLD_xbrl", isDirectory: true)
        let newXbrl = edinetDir.appendingPathComponent("S100NEW_xbrl", isDirectory: true)
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

        XCTAssertEqual(summary.removedFiles, 1)
        XCTAssertEqual(summary.removedDirs, 1)
        XCTAssertFalse(fm.fileExists(atPath: oldSearch.path))
        XCTAssertTrue(fm.fileExists(atPath: newSearch.path))
        XCTAssertFalse(fm.fileExists(atPath: oldXbrl.path))
        XCTAssertTrue(fm.fileExists(atPath: newXbrl.path))
    }

    func testPruneEdinetDocIndexesKeepsRecentYearsByDefault() throws {
        let fm = FileManager.default
        let currentYear = Calendar.current.component(.year, from: Date())
        let oldIndex = edinetDir.appendingPathComponent("doc_index_\(currentYear - 6).json")
        let keptIndex = edinetDir.appendingPathComponent("doc_index_\(currentYear - 5).json")
        try writeFile(oldIndex, "{}")
        try writeFile(keptIndex, "{}")

        let summary = CachePruner(cacheDir: tmpDir).prune(dryRun: false)

        XCTAssertEqual(summary.removedFiles, 1)
        XCTAssertFalse(fm.fileExists(atPath: oldIndex.path))
        XCTAssertTrue(fm.fileExists(atPath: keptIndex.path))
    }

    func testPruneEdinetDocIndexesCanKeepCustomYears() throws {
        let fm = FileManager.default
        let currentYear = Calendar.current.component(.year, from: Date())
        let oldIndex = edinetDir.appendingPathComponent("doc_index_\(currentYear - 3).json")
        let keptIndex = edinetDir.appendingPathComponent("doc_index_\(currentYear - 2).json")
        try writeFile(oldIndex, "{}")
        try writeFile(keptIndex, "{}")

        let summary = CachePruner(cacheDir: tmpDir).prune(
            dryRun: false,
            edinetDocIndexYears: 3
        )

        XCTAssertEqual(summary.removedFiles, 1)
        XCTAssertFalse(fm.fileExists(atPath: oldIndex.path))
        XCTAssertTrue(fm.fileExists(atPath: keptIndex.path))
    }
}
