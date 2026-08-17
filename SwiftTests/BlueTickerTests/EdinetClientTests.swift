// EdinetAPIClient は actor のため継承モック不可。キャッシュシード＋API キー未設定で
// ネットワークなしにキャッシュ優先パスを検証する。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite final class EdinetClientTests {
    private let tmpDir: URL
    private let store: EdinetCacheStore
    private let client: EdinetAPIClient

    init() throws {
        tmpDir = try ServiceTestSupport.makeTempDir()
        store = EdinetCacheStore(cacheDir: tmpDir)
        client = EdinetAPIClient(apiKey: nil, cacheStore: store)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test func testDocumentIndexBuildsYearCacheFromDailyCaches() async throws {
        // 過去年（2024）の全日付に検索キャッシュをシード。1日だけ書類あり
        let support = ServiceTestSupport.self
        let start = support.utcCalendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let end = support.utcCalendar.date(from: DateComponents(year: 2024, month: 12, day: 31))!
        let doc: [String: Any] = [
            "docID": "S100TEST",
            "secCode": "72030",
            "docTypeCode": "120",
            "periodEnd": "2024-03-31",
            "submitDateTime": "2024-06-24 10:00",
        ]
        var current = start
        while current <= end {
            let ds = support.iso(current)
            store.saveSearchCache(store.searchCacheKey(ds), data: ds == "2024-06-24" ? [doc] : [])
            current = support.addDays(current, 1)
        }

        let docs = await client.catchupDocumentIndexForYear(2024)
        let cached = store.loadDocumentIndex(2024, requiredThrough: "2024-12-31")

        #expect(docs.count == 1)
        #expect(docs.first?["docID"] as? String == "S100TEST")
        #expect(docs.first?["_edinet_list_date"] as? String == "2024-06-24")
        #expect(cached?.count == 1)
        #expect(cached?.first?["docID"] as? String == "S100TEST")
    }

    @Test func testGetDocumentsForDateRangeUsesYearIndexForWideRanges() async throws {
        let support = ServiceTestSupport.self
        store.saveDocumentIndex(
            2024,
            documents: [
                ["docID": "IN", "submitDateTime": "2024-06-24 10:00", "_edinet_list_date": "2024-06-24"],
                ["docID": "OUT", "submitDateTime": "2024-08-01 10:00", "_edinet_list_date": "2024-08-01"],
            ],
            builtThrough: "2024-12-31"
        )

        let docsByDate = await client.getDocumentsForDateRange(
            start: support.utcCalendar.date(from: DateComponents(year: 2024, month: 6, day: 1))!,
            end: support.utcCalendar.date(from: DateComponents(year: 2024, month: 6, day: 30))!
        )

        #expect(docsByDate["2024-06-24"]??.first?["docID"] as? String == "IN")
        let allDocIDs = docsByDate.values.flatMap { ($0 ?? []).compactMap { $0["docID"] as? String } }
        #expect(!(allDocIDs.contains("OUT")))
        // API キーなしのため、インデックスを使わず日次フェッチに落ちていたら nil になる
        #expect(!(docsByDate.values.contains { $0 == nil }))
    }

    @Test func testDocumentsForDatePrefersStaleSearchCache() async throws {
        // Python は「リクエスト不発行」を検証するが、Swift では観測できないため
        // 「取得失敗時に期限切れキャッシュへフォールバックする」ことを検証する
        // hit TTL 0 → 保存直後でも期限切れ。API キーなし → 取得失敗 → 期限切れキャッシュへフォールバック
        // today() は当日分 TTL（searchTodayTTLHours）で判定されるため、こちらも 0 にして即時失効させる。
        let staleStore = EdinetCacheStore(cacheDir: tmpDir, searchHitTTLDays: 0, searchTodayTTLHours: 0)
        let staleClient = EdinetAPIClient(apiKey: nil, cacheStore: staleStore)
        let today = ServiceTestSupport.iso(Date())
        let filename = staleStore.searchCacheKey(today)
        staleStore.saveSearchCache(filename, data: [["docID": "S100STALE", "docTypeCode": "120"]])
        #expect(staleStore.loadSearchCache(filename) == nil)  // 通常読み込みでは期限切れ

        let docs = await staleClient.getDocumentsForDate(today)

        #expect(docs?.first?["docID"] as? String == "S100STALE")
    }

    @Test func testDocumentIndexPrefersStaleIndex() async throws {
        let year = ServiceTestSupport.currentUTCYear()
        let documents: [[String: Any]] = [["docID": "S100STALE", "docTypeCode": "120"]]
        store.saveDocumentIndex(year, documents: documents, builtThrough: "\(year)-01-01")

        // built_through が古いため差分取得を試みるが、API キーなしのため取得失敗 →
        // 既存キャッシュへフォールバックする（オフライン時にデータを失わない）
        let docs = await client.catchupDocumentIndexForYear(year)

        #expect(docs.count == 1)
        #expect(docs.first?["docID"] as? String == "S100STALE")
    }

    @Test func testDocumentIndexCatchupFetchesOnlyMissingDates() async throws {
        let support = ServiceTestSupport.self
        let today = support.utcToday()
        let yesterday = support.addDays(today, -1)
        let year = support.utcCalendar.component(.year, from: today)
        store.saveDocumentIndex(
            year,
            documents: [["docID": "OLD", "_edinet_list_date": support.iso(yesterday)]],
            builtThrough: support.iso(yesterday)
        )
        // 不足分（今日）の検索キャッシュをシード → ネットワーク不要で追補できる
        store.saveSearchCache(
            store.searchCacheKey(support.iso(today)),
            data: [["docID": "NEW", "submitDateTime": "\(support.iso(today)) 10:00"]]
        )

        let docs = await client.catchupDocumentIndexForYear(year)
        let cachedInfo = store.loadDocumentIndexInfo(year, allowStale: true)

        #expect(docs.compactMap { $0["docID"] as? String } == ["OLD", "NEW"])
        // 当日は「未確定」として built_through には反映されない（前日のまま）。
        // EDINET は当日の書類一覧を随時更新するため、当日を確定扱いにすると
        // 後から提出された書類を二度と取り込めなくなる（監査で発見された不具合の修正）。
        #expect(cachedInfo?["built_through"] as? String == support.iso(yesterday))
    }

    @Test func testCatchupPicksUpDocumentAddedLaterTheSameDay() async throws {
        // 回帰テスト: 当日分を built_through に確定させてしまうと、同日中に後から
        // 提出された書類（有報等）が二度と取り込めなくなる不具合があった
        // （実例: 6/27 構築の年次インデックスに 6/29 15:36 提出の有報が反映されず、
        // 財務取り込み の財務計算が恒久的に失敗し続けた）。当日は確定扱いにしないため、
        // 同日内に catchup を複数回呼んでも、後から追加された書類を拾えなければならない。
        let support = ServiceTestSupport.self
        let today = support.utcToday()
        let yesterday = support.addDays(today, -1)
        let year = support.utcCalendar.component(.year, from: today)
        store.saveDocumentIndex(
            year,
            documents: [["docID": "OLD", "_edinet_list_date": support.iso(yesterday)]],
            builtThrough: support.iso(yesterday)
        )
        let todayKey = store.searchCacheKey(support.iso(today))
        store.saveSearchCache(todayKey, data: [["docID": "MORNING", "submitDateTime": "\(support.iso(today)) 10:00"]])

        let firstPass = await client.catchupDocumentIndexForYear(year)
        #expect(firstPass.compactMap { $0["docID"] as? String } == ["OLD", "MORNING"])

        // 同日午後に新たな書類が提出された状況をシミュレート
        store.saveSearchCache(
            todayKey,
            data: [
                ["docID": "MORNING", "submitDateTime": "\(support.iso(today)) 10:00"],
                ["docID": "AFTERNOON", "submitDateTime": "\(support.iso(today)) 15:36"],
            ]
        )

        let secondPass = await client.catchupDocumentIndexForYear(year)

        #expect(secondPass.compactMap { $0["docID"] as? String } == ["OLD", "MORNING", "AFTERNOON"])
    }

    // MARK: - XBRL ダウンロード

    @Test func testDownloadDocumentReturnsCachedDirWithoutApiKey() async throws {
        // 事前に XBRL を展開しておけば、API キーなしでもキャッシュヒットでディレクトリを返す
        // （ヒット時はネットワークへ行かない。失敗していたら nil になる）
        let zip = try ServiceTestSupport.makeXbrlZip(files: ["a.txt": "1234"])
        _ = try store.storeXbrlZip("S100CACHE", content: zip)

        let dir = await client.downloadDocument("S100CACHE")

        #expect(dir != nil)
        #expect(store.hasXbrlDir("S100CACHE"))
    }

    @Test func testDownloadDocumentReturnsNilWithoutApiKeyOrCache() async throws {
        // キャッシュなし・API キーなし → 取得失敗で nil。
        // キー検証で早期リターンするため、ファイルロックは取得されず残らない。
        let dir = await client.downloadDocument("S100MISS")

        #expect(dir == nil)
        let lockPath = store.locksDir.appendingPathComponent("xbrl_S100MISS.lock")
        #expect(!(FileManager.default.fileExists(atPath: lockPath.path)))
    }

    @Test func testDownloadDocumentUsesR2WhenLocalMissingWithoutApiKey() async throws {
        let zip = try ServiceTestSupport.makeXbrlZip(files: ["a.txt": "from-r2"])
        let objectStore = MemoryXbrlObjectStore(
            objects: ["jp/edinet/xbrl/S100R2HIT.zip": zip]
        )
        let r2Client = EdinetAPIClient(apiKey: nil, cacheStore: store, xbrlObjectStore: objectStore)

        let dir = await r2Client.downloadDocument("S100R2HIT")

        #expect(dir != nil)
        #expect(store.hasXbrlDir("S100R2HIT"))
        let extracted = try String(
            contentsOf: store.xbrlDir("S100R2HIT").appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(extracted == "from-r2")
        #expect(await objectStore.getKeys == ["jp/edinet/xbrl/S100R2HIT.zip"])
        #expect(await objectStore.putKeys.isEmpty)
    }

    @Test func testDownloadDocumentSkipsR2WhenLocalCacheHits() async throws {
        let zip = try ServiceTestSupport.makeXbrlZip(files: ["a.txt": "local"])
        _ = try store.storeXbrlZip("S100LOCAL", content: zip)
        let objectStore = MemoryXbrlObjectStore()
        let r2Client = EdinetAPIClient(apiKey: nil, cacheStore: store, xbrlObjectStore: objectStore)

        let dir = await r2Client.downloadDocument("S100LOCAL")

        #expect(dir != nil)
        #expect(await objectStore.getKeys.isEmpty)
        #expect(await objectStore.putKeys.isEmpty)
    }

    @Test func testDownloadDocumentPutsToR2AfterRemoteFetch() async throws {
        let zip = try ServiceTestSupport.makeXbrlZip(files: ["a.txt": "from-edinet"])
        let objectStore = MemoryXbrlObjectStore()
        let r2Client = EdinetAPIClient(
            apiKey: "dummy",
            cacheStore: store,
            xbrlObjectStore: objectStore,
            xbrlZipDownloader: { _ in zip }
        )

        let dir = await r2Client.downloadDocument("S100PUT")

        #expect(dir != nil)
        #expect(store.hasXbrlDir("S100PUT"))
        #expect(await objectStore.getKeys == ["jp/edinet/xbrl/S100PUT.zip"])
        #expect(await objectStore.putKeys == ["jp/edinet/xbrl/S100PUT.zip"])
        #expect(await objectStore.objects["jp/edinet/xbrl/S100PUT.zip"] == zip)
    }

    @Test func testDownloadDocumentFallsBackToRemoteWhenR2ZipIsCorrupt() async throws {
        let good = try ServiceTestSupport.makeXbrlZip(files: ["a.txt": "recovered"])
        let objectStore = MemoryXbrlObjectStore(
            objects: ["jp/edinet/xbrl/S100BAD.zip": Data("not-a-zip".utf8)]
        )
        let r2Client = EdinetAPIClient(
            apiKey: "dummy",
            cacheStore: store,
            xbrlObjectStore: objectStore,
            xbrlZipDownloader: { _ in good }
        )

        let dir = await r2Client.downloadDocument("S100BAD")

        #expect(dir != nil)
        let extracted = try String(
            contentsOf: store.xbrlDir("S100BAD").appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(extracted == "recovered")
        #expect(await objectStore.putKeys == ["jp/edinet/xbrl/S100BAD.zip"])
        #expect(await objectStore.objects["jp/edinet/xbrl/S100BAD.zip"] == good)
    }

    @Test func testDownloadDocumentReturnsNilWhenR2MissesWithoutRemote() async throws {
        let objectStore = MemoryXbrlObjectStore()
        let r2Client = EdinetAPIClient(apiKey: nil, cacheStore: store, xbrlObjectStore: objectStore)

        let dir = await r2Client.downloadDocument("S100R2MISS")

        #expect(dir == nil)
        #expect(!(store.hasXbrlDir("S100R2MISS")))
        #expect(await objectStore.getKeys == ["jp/edinet/xbrl/S100R2MISS.zip"])
        #expect(await objectStore.putKeys.isEmpty)
    }
}

actor MemoryXbrlObjectStore: XbrlObjectStoring {
    var objects: [String: Data]
    var getKeys: [String] = []
    var putKeys: [String] = []

    init(objects: [String: Data] = [:]) {
        self.objects = objects
    }

    func getObject(key: String) async -> Data? {
        getKeys.append(key)
        return objects[key]
    }

    func putObject(_ data: Data, key: String, contentType: String) async -> Bool {
        putKeys.append(key)
        objects[key] = data
        return true
    }
}
