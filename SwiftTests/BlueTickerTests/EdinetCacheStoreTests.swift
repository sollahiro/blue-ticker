//
// 移植対象外:
// - test_file_lock_prints_wait_notice（time.sleep / monotonic のモックが前提で実時間依存になるため）

import Testing
import Foundation
@testable import BlueTickerCore

@Suite final class EdinetCacheStoreTests {
    private let tmpDir: URL

    init() throws {
        tmpDir = try ServiceTestSupport.makeTempDir()
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeStore(
        searchEmptyTTLDays: Int = 1,
        searchHitTTLDays: Int = 30,
        searchPastTTLDays: Int = 3650,
        searchTodayTTLHours: Int = 4,
        maxXbrlBytes: Int64? = nil
    ) -> EdinetCacheStore {
        EdinetCacheStore(
            cacheDir: tmpDir,
            searchEmptyTTLDays: searchEmptyTTLDays,
            searchHitTTLDays: searchHitTTLDays,
            searchPastTTLDays: searchPastTTLDays,
            searchTodayTTLHours: searchTodayTTLHours,
            maxXbrlBytes: maxXbrlBytes
        )
    }

    private func searchCachePath(_ store: EdinetCacheStore, _ filename: String) -> URL {
        store.documentsByDateDir.appendingPathComponent(filename)
    }

    private func todayStr() -> String {
        ServiceTestSupport.iso(Date())
    }

    private func yesterdayStr() -> String {
        ServiceTestSupport.iso(Date().addingTimeInterval(-86400))
    }

    // MARK: - 日別検索キャッシュ

    @Test func testLoadSearchCacheReturnsFreshEmptyResult() {
        let store = makeStore()
        let filename = store.searchCacheKey(todayStr())
        store.saveSearchCache(filename, data: [])

        #expect(store.loadSearchCache(filename)?.count == 0)
    }

    @Test func testSaveSearchCacheUsesCompactJSON() throws {
        let store = makeStore()
        let filename = store.searchCacheKey("2024-06-01")
        let documents: [[String: Any]] = [["docID": "S100TEST", "docTypeCode": "120"]]

        store.saveSearchCache(filename, data: documents)

        let content = try String(contentsOf: searchCachePath(store, filename), encoding: .utf8)
        #expect(!(content.contains("\n")))
        #expect(!(content.contains(": ")))
        let loaded = store.loadSearchCache(filename)
        #expect(loaded?.first?["docID"] as? String == "S100TEST")
        #expect(loaded?.first?["docTypeCode"] as? String == "120")
    }

    @Test func testLoadSearchCacheExpiresEmptyResultQuickly() throws {
        let store = makeStore()
        let filename = store.searchCacheKey(todayStr())
        store.saveSearchCache(filename, data: [])
        try ServiceTestSupport.age(searchCachePath(store, filename), days: 1)

        #expect(store.loadSearchCache(filename) == nil)
    }

    @Test func testLoadSearchCacheKeepsHitResultLongerThanEmptyResult() throws {
        let store = makeStore()
        // 当日分は searchTodayTTLHours で別扱いになるため、この日単位 TTL の
        // 比較（hit が empty より長持ちする）は前日分の日付で検証する。
        let filename = store.searchCacheKey(yesterdayStr())
        store.saveSearchCache(filename, data: [["docID": "S100TEST", "docTypeCode": "120"]])
        try ServiceTestSupport.age(searchCachePath(store, filename), days: 1)

        #expect(store.loadSearchCache(filename)?.first?["docID"] as? String == "S100TEST")
    }

    @Test func testLoadSearchCacheExpiresTodayHitResultWithinSameDay() throws {
        // 実例: EDINET は当日の書類一覧を営業時間中随時更新するため、朝の sync 実行で
        // 得た非空結果が日単位 TTL（30日）のまま固定されると、同日午後に提出された
        // 書類が同日中の再実行（launchd 6時間間隔）で永久に取りこぼされる
        // （2026-06-29 提出の有報欠落）。当日分は時間単位 TTL で早く失効させる。
        let store = makeStore(searchTodayTTLHours: 4)
        let filename = store.searchCacheKey(todayStr())
        store.saveSearchCache(filename, data: [["docID": "S100TEST", "docTypeCode": "120"]])
        try ServiceTestSupport.setMtime(
            searchCachePath(store, filename), Date().addingTimeInterval(-5 * 3600))

        #expect(store.loadSearchCache(filename) == nil)
    }

    @Test func testLoadSearchCacheExpiresOldHitResult() throws {
        let store = makeStore()
        let filename = store.searchCacheKey(todayStr())
        store.saveSearchCache(filename, data: [["docID": "S100TEST"]])
        try ServiceTestSupport.age(searchCachePath(store, filename), days: 30)

        #expect(store.loadSearchCache(filename) == nil)
    }

    @Test func testLoadSearchCacheCanAllowExpiredResult() throws {
        let store = makeStore()
        let filename = store.searchCacheKey(todayStr())
        store.saveSearchCache(filename, data: [["docID": "S100TEST"]])
        try ServiceTestSupport.age(searchCachePath(store, filename), days: 30)

        let loaded = store.loadSearchCache(filename, allowExpired: true)
        #expect(loaded?.first?["docID"] as? String == "S100TEST")
    }

    @Test func testLoadSearchCacheRejectsNonListPayload() throws {
        let store = makeStore()
        let filename = store.searchCacheKey("2024-06-01")
        let path = searchCachePath(store, filename)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"results":[]}"#.utf8).write(to: path)

        #expect(store.loadSearchCache(filename) == nil)
    }

    @Test func testLoadSearchCacheKeepsPastDateResultLonger() throws {
        let store = makeStore(searchPastTTLDays: 3650)
        let filename = store.searchCacheKey("2024-06-01")
        store.saveSearchCache(filename, data: [["docID": "S100TEST", "docTypeCode": "120"]])
        try ServiceTestSupport.age(searchCachePath(store, filename), days: 365)

        #expect(store.loadSearchCache(filename)?.first?["docID"] as? String == "S100TEST")
    }

    // MARK: - 年次書類インデックス

    @Test func testDocumentIndexRoundtripRequiresVersionAndBuiltThrough() {
        let store = makeStore()
        let documents: [[String: Any]] = [["docID": "S100TEST", "docTypeCode": "120"]]
        store.saveDocumentIndex(2024, documents: documents, builtThrough: "2024-12-31")

        let loaded = store.loadDocumentIndex(2024, requiredThrough: "2024-06-30")
        #expect(loaded?.first?["docID"] as? String == "S100TEST")
        #expect(store.loadDocumentIndex(2024, requiredThrough: "2025-01-01") == nil)
    }

    @Test func testSaveDocumentIndexUsesCompactJSON() throws {
        let store = makeStore()
        let documents: [[String: Any]] = [["docID": "S100TEST", "docTypeCode": "120"]]

        store.saveDocumentIndex(2024, documents: documents, builtThrough: "2024-12-31")

        let path = store.documentIndexesDir.appendingPathComponent(store.documentIndexCacheKey(2024))
        let content = try String(contentsOf: path, encoding: .utf8)
        #expect(!(content.contains("\n")))
        #expect(!(content.contains(": ")))
        let loaded = store.loadDocumentIndex(2024, requiredThrough: "2024-06-30")
        #expect(loaded?.first?["docID"] as? String == "S100TEST")
    }

    @Test func testDocumentIndexCanAllowStaleBuiltThrough() {
        let store = makeStore()
        let documents: [[String: Any]] = [["docID": "S100TEST", "docTypeCode": "120"]]
        store.saveDocumentIndex(2024, documents: documents, builtThrough: "2024-06-30")

        let loaded = store.loadDocumentIndex(2024, requiredThrough: "2024-12-31", allowStale: true)
        #expect(loaded?.first?["docID"] as? String == "S100TEST")
    }

    // MARK: - XBRL 展開と容量上限

    @Test func testStoreXbrlZipEvictsOldestDirsWhenOverLimit() throws {
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

        #expect(!(store.hasXbrlDir("DOC1")))
        #expect(!(store.hasXbrlDir("DOC2")))
        #expect(store.hasXbrlDir("DOC3"))
        #expect(store.hasXbrlDir("DOC4"))
    }

    @Test func testStoreXbrlZipKeepsDirsWhenWithinLimit() throws {
        let store = makeStore(maxXbrlBytes: 20)
        let zip = try ServiceTestSupport.makeXbrlZip(files: ["a.txt": "1234"])

        _ = try store.storeXbrlZip("DOC1", content: zip)
        _ = try store.storeXbrlZip("DOC2", content: zip)
        _ = try store.storeXbrlZip("DOC3", content: zip)

        #expect(store.hasXbrlDir("DOC1"))
        #expect(store.hasXbrlDir("DOC2"))
        #expect(store.hasXbrlDir("DOC3"))
    }

    @Test func testStoreXbrlZipDoesNotEvictWhenMaxXbrlBytesIsNil() throws {
        let store = makeStore(maxXbrlBytes: nil)
        let zip = try ServiceTestSupport.makeXbrlZip(files: ["a.txt": "1234"])

        _ = try store.storeXbrlZip("DOC1", content: zip)
        _ = try store.storeXbrlZip("DOC2", content: zip)
        _ = try store.storeXbrlZip("DOC3", content: zip)

        #expect(store.hasXbrlDir("DOC1"))
        #expect(store.hasXbrlDir("DOC2"))
        #expect(store.hasXbrlDir("DOC3"))
    }

    @Test func testHasXbrlDirRejectsEmptyDirectory() throws {
        let store = makeStore()
        let dir = store.xbrlDir("DOC_EMPTY")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 空ディレクトリ（展開失敗の残骸）はキャッシュヒットにしない
        #expect(!(store.hasXbrlDir("DOC_EMPTY")))
        #expect(!(store.cachedXbrlDocIDs().contains("DOC_EMPTY")))
    }

    @Test func testHasXbrlDirRejectsNonEmptyDirectoryWithoutExtractMarker() throws {
        let store = makeStore()
        let dir = store.xbrlDir("DOC_PARTIAL")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: dir.appendingPathComponent("a.txt"))

        // 展開途中の非空ディレクトリもキャッシュヒットにしない
        #expect(!(store.hasXbrlDir("DOC_PARTIAL")))
        #expect(!(store.cachedXbrlDocIDs().contains("DOC_PARTIAL")))
    }

    @Test func testCachedXbrlDocIDsListsNonEmptyDirsOnly() throws {
        let store = makeStore()
        let zip = try ServiceTestSupport.makeXbrlZip(files: ["a.txt": "1234"])
        _ = try store.storeXbrlZip("DOC1", content: zip)
        try FileManager.default.createDirectory(
            at: store.xbrlDir("DOC_EMPTY"), withIntermediateDirectories: true)

        #expect(store.cachedXbrlDocIDs() == Set(["DOC1"]))
    }

    @Test func testStoreXbrlZipLeavesNoDirectoryWhenContentIsNotZip() {
        let store = makeStore()
        let notZip = Data(#"{"StatusCode":401,"message":"invalid"}"#.utf8)

        #expect(throws: (any Error).self) {
            _ = try store.storeXbrlZip("DOC_BADZIP", content: notZip)
        }
        // 展開失敗時にディレクトリ自体を残さない（残すと以後のキャッシュが汚染される）。
        // hasXbrlDir は空ディレクトリも false にするため、dest の非存在を直接検証する。
        #expect(!(FileManager.default.fileExists(atPath: store.xbrlDir("DOC_BADZIP").path)))
    }

    @Test func testTouchXbrlDirUpdatesMtime() throws {
        let store = makeStore()
        let zip = try ServiceTestSupport.makeXbrlZip(files: ["a.txt": "1234"])
        _ = try store.storeXbrlZip("DOC1", content: zip)
        let dir = store.xbrlDir("DOC1")
        try ServiceTestSupport.setMtime(dir, Date().addingTimeInterval(-100))

        let before = try ServiceTestSupport.mtime(dir)
        store.touchXbrlDir("DOC1")
        let after = try ServiceTestSupport.mtime(dir)

        #expect(after > before)
    }

    // MARK: - ファイルロック

    @Test func testFileLockCreatesAndRemovesLockFile() async throws {
        let store = makeStore()
        let lockPath = store.locksDir.appendingPathComponent("documents_by_date_2024-06-24.lock")

        try await store.withFileLock("documents_by_date_2024-06-24") {
            #expect(FileManager.default.fileExists(atPath: lockPath.path))
        }

        #expect(!(FileManager.default.fileExists(atPath: lockPath.path)))
    }

    @Test func testFileLockRemovesStaleLock() async throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.locksDir, withIntermediateDirectories: true)
        let lockPath = store.locksDir.appendingPathComponent("document_index_2024.lock")
        try Data("stale".utf8).write(to: lockPath)
        // ステール閾値（Api.cacheLockStaleSeconds = 10 分）を超えた古いロック
        try ServiceTestSupport.setMtime(lockPath, Date().addingTimeInterval(-3600))

        try await store.withFileLock("document_index_2024") {
            #expect(FileManager.default.fileExists(atPath: lockPath.path))
        }

        #expect(!(FileManager.default.fileExists(atPath: lockPath.path)))
    }
}
