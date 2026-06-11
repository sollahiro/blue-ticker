// Python tests/test_edinet_cache_store.py の移植
//
// 移植対象外:
// - test_file_lock_prints_wait_notice（time.sleep / monotonic のモックが前提で実時間依存になるため）

import XCTest
@testable import BlueTicker

final class EdinetCacheStoreTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = try ServiceTestSupport.makeTempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeStore(
        searchEmptyTTLDays: Int = 1,
        searchHitTTLDays: Int = 30,
        searchPastTTLDays: Int = 3650,
        maxXbrlBytes: Int64? = nil
    ) -> EdinetCacheStore {
        EdinetCacheStore(
            cacheDir: tmpDir,
            searchEmptyTTLDays: searchEmptyTTLDays,
            searchHitTTLDays: searchHitTTLDays,
            searchPastTTLDays: searchPastTTLDays,
            maxXbrlBytes: maxXbrlBytes
        )
    }

    private func searchCachePath(_ store: EdinetCacheStore, _ filename: String) -> URL {
        store.documentsByDateDir.appendingPathComponent(filename)
    }

    private func todayStr() -> String {
        ServiceTestSupport.iso(Date())
    }

    // MARK: - 日別検索キャッシュ

    func testLoadSearchCacheReturnsFreshEmptyResult() {
        let store = makeStore()
        let filename = store.searchCacheKey(todayStr())
        store.saveSearchCache(filename, data: [])

        XCTAssertEqual(store.loadSearchCache(filename)?.count, 0)
    }

    func testSaveSearchCacheUsesCompactJSON() throws {
        let store = makeStore()
        let filename = store.searchCacheKey("2024-06-01")
        let documents: [[String: Any]] = [["docID": "S100TEST", "docTypeCode": "120"]]

        store.saveSearchCache(filename, data: documents)

        let content = try String(contentsOf: searchCachePath(store, filename), encoding: .utf8)
        XCTAssertFalse(content.contains("\n"))
        XCTAssertFalse(content.contains(": "))
        let loaded = store.loadSearchCache(filename)
        XCTAssertEqual(loaded?.first?["docID"] as? String, "S100TEST")
        XCTAssertEqual(loaded?.first?["docTypeCode"] as? String, "120")
    }

    func testLoadSearchCacheExpiresEmptyResultQuickly() throws {
        let store = makeStore()
        let filename = store.searchCacheKey(todayStr())
        store.saveSearchCache(filename, data: [])
        try ServiceTestSupport.age(searchCachePath(store, filename), days: 1)

        XCTAssertNil(store.loadSearchCache(filename))
    }

    func testLoadSearchCacheKeepsHitResultLongerThanEmptyResult() throws {
        let store = makeStore()
        let filename = store.searchCacheKey(todayStr())
        store.saveSearchCache(filename, data: [["docID": "S100TEST", "docTypeCode": "120"]])
        try ServiceTestSupport.age(searchCachePath(store, filename), days: 1)

        XCTAssertEqual(store.loadSearchCache(filename)?.first?["docID"] as? String, "S100TEST")
    }

    func testLoadSearchCacheExpiresOldHitResult() throws {
        let store = makeStore()
        let filename = store.searchCacheKey(todayStr())
        store.saveSearchCache(filename, data: [["docID": "S100TEST"]])
        try ServiceTestSupport.age(searchCachePath(store, filename), days: 30)

        XCTAssertNil(store.loadSearchCache(filename))
    }

    func testLoadSearchCacheCanAllowExpiredResult() throws {
        let store = makeStore()
        let filename = store.searchCacheKey(todayStr())
        store.saveSearchCache(filename, data: [["docID": "S100TEST"]])
        try ServiceTestSupport.age(searchCachePath(store, filename), days: 30)

        let loaded = store.loadSearchCache(filename, allowExpired: true)
        XCTAssertEqual(loaded?.first?["docID"] as? String, "S100TEST")
    }

    func testLoadSearchCacheRejectsNonListPayload() throws {
        let store = makeStore()
        let filename = store.searchCacheKey("2024-06-01")
        let path = searchCachePath(store, filename)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"results":[]}"#.utf8).write(to: path)

        XCTAssertNil(store.loadSearchCache(filename))
    }

    func testLoadSearchCacheKeepsPastDateResultLonger() throws {
        let store = makeStore(searchPastTTLDays: 3650)
        let filename = store.searchCacheKey("2024-06-01")
        store.saveSearchCache(filename, data: [["docID": "S100TEST", "docTypeCode": "120"]])
        try ServiceTestSupport.age(searchCachePath(store, filename), days: 365)

        XCTAssertEqual(store.loadSearchCache(filename)?.first?["docID"] as? String, "S100TEST")
    }

    // MARK: - 年次書類インデックス

    func testDocumentIndexRoundtripRequiresVersionAndBuiltThrough() {
        let store = makeStore()
        let documents: [[String: Any]] = [["docID": "S100TEST", "docTypeCode": "120"]]
        store.saveDocumentIndex(2024, documents: documents, builtThrough: "2024-12-31")

        let loaded = store.loadDocumentIndex(2024, requiredThrough: "2024-06-30")
        XCTAssertEqual(loaded?.first?["docID"] as? String, "S100TEST")
        XCTAssertNil(store.loadDocumentIndex(2024, requiredThrough: "2025-01-01"))
    }

    func testSaveDocumentIndexUsesCompactJSON() throws {
        let store = makeStore()
        let documents: [[String: Any]] = [["docID": "S100TEST", "docTypeCode": "120"]]

        store.saveDocumentIndex(2024, documents: documents, builtThrough: "2024-12-31")

        let path = store.documentIndexesDir.appendingPathComponent(store.documentIndexCacheKey(2024))
        let content = try String(contentsOf: path, encoding: .utf8)
        XCTAssertFalse(content.contains("\n"))
        XCTAssertFalse(content.contains(": "))
        let loaded = store.loadDocumentIndex(2024, requiredThrough: "2024-06-30")
        XCTAssertEqual(loaded?.first?["docID"] as? String, "S100TEST")
    }

    func testDocumentIndexCanAllowStaleBuiltThrough() {
        let store = makeStore()
        let documents: [[String: Any]] = [["docID": "S100TEST", "docTypeCode": "120"]]
        store.saveDocumentIndex(2024, documents: documents, builtThrough: "2024-06-30")

        let loaded = store.loadDocumentIndex(2024, requiredThrough: "2024-12-31", allowStale: true)
        XCTAssertEqual(loaded?.first?["docID"] as? String, "S100TEST")
    }

    // MARK: - XBRL 展開と容量上限

    func testStoreXbrlZipEvictsOldestDirsWhenOverLimit() throws {
        let store = makeStore(maxXbrlBytes: 100)
        let zip = try ServiceTestSupport.makeXbrlZip(files: ["a.txt": "1234"])
        let baseTs = Date().addingTimeInterval(-100)

        _ = try store.storeXbrlZip("DOC1", content: zip)
        _ = try store.storeXbrlZip("DOC2", content: zip)
        _ = try store.storeXbrlZip("DOC3", content: zip)
        try ServiceTestSupport.setMtime(store.xbrlDir("DOC1"), baseTs)
        try ServiceTestSupport.setMtime(store.xbrlDir("DOC2"), baseTs.addingTimeInterval(1))
        try ServiceTestSupport.setMtime(store.xbrlDir("DOC3"), baseTs.addingTimeInterval(2))

        // Python テストは max_xbrl_bytes を途中で書き換えるが、
        // Swift 版はイミュータブルなので同じディレクトリを指す別インスタンスで代替する
        let smallStore = makeStore(maxXbrlBytes: 10)
        _ = try smallStore.storeXbrlZip("DOC4", content: zip)

        XCTAssertFalse(store.hasXbrlDir("DOC1"))
        XCTAssertFalse(store.hasXbrlDir("DOC2"))
        XCTAssertTrue(store.hasXbrlDir("DOC3"))
        XCTAssertTrue(store.hasXbrlDir("DOC4"))
    }

    func testStoreXbrlZipKeepsDirsWhenWithinLimit() throws {
        let store = makeStore(maxXbrlBytes: 20)
        let zip = try ServiceTestSupport.makeXbrlZip(files: ["a.txt": "1234"])

        _ = try store.storeXbrlZip("DOC1", content: zip)
        _ = try store.storeXbrlZip("DOC2", content: zip)
        _ = try store.storeXbrlZip("DOC3", content: zip)

        XCTAssertTrue(store.hasXbrlDir("DOC1"))
        XCTAssertTrue(store.hasXbrlDir("DOC2"))
        XCTAssertTrue(store.hasXbrlDir("DOC3"))
    }

    func testStoreXbrlZipDoesNotEvictWhenMaxXbrlBytesIsNil() throws {
        let store = makeStore(maxXbrlBytes: nil)
        let zip = try ServiceTestSupport.makeXbrlZip(files: ["a.txt": "1234"])

        _ = try store.storeXbrlZip("DOC1", content: zip)
        _ = try store.storeXbrlZip("DOC2", content: zip)
        _ = try store.storeXbrlZip("DOC3", content: zip)

        XCTAssertTrue(store.hasXbrlDir("DOC1"))
        XCTAssertTrue(store.hasXbrlDir("DOC2"))
        XCTAssertTrue(store.hasXbrlDir("DOC3"))
    }

    func testTouchXbrlDirUpdatesMtime() throws {
        let store = makeStore()
        let zip = try ServiceTestSupport.makeXbrlZip(files: ["a.txt": "1234"])
        _ = try store.storeXbrlZip("DOC1", content: zip)
        let dir = store.xbrlDir("DOC1")
        try ServiceTestSupport.setMtime(dir, Date().addingTimeInterval(-100))

        let before = try ServiceTestSupport.mtime(dir)
        store.touchXbrlDir("DOC1")
        let after = try ServiceTestSupport.mtime(dir)

        XCTAssertGreaterThan(after, before)
    }

    // MARK: - ファイルロック

    func testFileLockCreatesAndRemovesLockFile() async throws {
        let store = makeStore()
        let lockPath = store.locksDir.appendingPathComponent("documents_by_date_2024-06-24.lock")

        try await store.withFileLock("documents_by_date_2024-06-24") {
            XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath.path))
    }

    func testFileLockRemovesStaleLock() async throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.locksDir, withIntermediateDirectories: true)
        let lockPath = store.locksDir.appendingPathComponent("document_index_2024.lock")
        try Data("stale".utf8).write(to: lockPath)
        // ステール閾値（Api.cacheLockStaleSeconds = 10 分）を超えた古いロック
        try ServiceTestSupport.setMtime(lockPath, Date().addingTimeInterval(-3600))

        try await store.withFileLock("document_index_2024") {
            XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath.path))
    }
}
