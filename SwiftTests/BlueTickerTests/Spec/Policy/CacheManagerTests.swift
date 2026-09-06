import Testing
import Foundation
@testable import BlueTickerCore

@Suite final class CacheManagerTests {
    private let tmpDir: URL

    init() throws {
        tmpDir = try ServiceTestSupport.makeTempDir()
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// individual_analysis_* は "analysis" サブディレクトリに振り分けられる。
    private func analysisCachePath(_ code: String) -> URL {
        tmpDir.appendingPathComponent("analysis")
            .appendingPathComponent("individual_analysis_\(code).json")
    }

    @Test func testSetJSONOverwritesExistingValue() async {
        let cm = CacheManager(cacheDir: tmpDir)
        await cm.setJSON("individual_analysis_AAA", value: ["v": 1])
        await cm.setJSON("individual_analysis_AAA", value: ["v": 2])

        #expect(await cm.getJSON("individual_analysis_AAA")?["v"] as? Int == 2)
    }

    @Test func testGetJSONReturnsValueWithinTTL() async {
        let cm = CacheManager(cacheDir: tmpDir, ttlDays: 7)
        await cm.setJSON("individual_analysis_BBB", value: ["v": 42])

        #expect(await cm.getJSON("individual_analysis_BBB")?["v"] as? Int == 42)
    }

    @Test func testGetJSONReturnsNilWhenExpired() async throws {
        let cm = CacheManager(cacheDir: tmpDir, ttlDays: 7)
        await cm.setJSON("individual_analysis_CCC", value: ["v": 1])
        try ServiceTestSupport.age(analysisCachePath("CCC"), days: 7)

        #expect(await cm.getJSON("individual_analysis_CCC") == nil)
    }

    @Test func testGetJSONReturnsNilForMissingKey() async {
        let cm = CacheManager(cacheDir: tmpDir)
        #expect(await cm.getJSON("individual_analysis_NONE") == nil)
    }

    @Test func testGetJSONReturnsNilWhenDisabled() async {
        let cm = CacheManager(cacheDir: tmpDir, enabled: false)
        await cm.setJSON("individual_analysis_DDD", value: ["v": 1])

        #expect(await cm.getJSON("individual_analysis_DDD") == nil)
    }

    @Test func testConcurrentDistinctKeysAllPersist() async {
        // 異なるキー（銘柄）を並行で書き込んでも、すべて保存される（lost update が起きない）
        let cm = CacheManager(cacheDir: tmpDir)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { await cm.setJSON("individual_analysis_C\(i)", value: ["v": i]) }
            }
        }

        var present = 0
        for i in 0..<20 where (await cm.getJSON("individual_analysis_C\(i)")?["v"] as? Int) == i {
            present += 1
        }
        #expect(present == 20)
    }

    @Test func testSafeNameKeepsPathTraversalInsideCacheDir() async {
        let cm = CacheManager(cacheDir: tmpDir)
        await cm.setJSON("individual_analysis_../etc", value: ["v": 1])
        #expect(await cm.getJSON("individual_analysis_../etc")?["v"] as? Int == 1)

        let analysis = tmpDir.appendingPathComponent("analysis")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: analysis.path)) ?? []
        #expect(names.allSatisfy { !$0.contains("..") && !$0.contains("/") })
        #expect(names.contains { $0.hasPrefix("individual_analysis_") && $0.hasSuffix(".json") })

        let escaped = tmpDir.deletingLastPathComponent().appendingPathComponent("etc.json")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }
}
