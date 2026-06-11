// Python tests/test_edinet_client.py の移植
//
// Python はクライアントのサブクラス化（fetch のモック）で検証するが、
// Swift の EdinetAPIClient は actor で継承不可のため、キャッシュシード方式で移植する:
// - 事前に EdinetCacheStore へ検索キャッシュ・年次インデックスを書き込む
// - API キーを未設定（nil）にして HTTP リクエストを即時失敗させる
// これによりネットワークなしで同じコードパス（キャッシュ優先・フォールバック）を検証できる。
//
// 移植対象外:
// - test_client_accepts_cache_backend_boundary（Swift はバックエンド抽象を持たない）
// - test_resolve_ca_bundle_*（URLSession は CA バンドル解決を OS に委ねるため該当コードなし）

import XCTest
@testable import BlueTicker

final class EdinetClientTests: XCTestCase {
    private var tmpDir: URL!
    private var store: EdinetCacheStore!
    private var client: EdinetAPIClient!

    override func setUpWithError() throws {
        tmpDir = try ServiceTestSupport.makeTempDir()
        store = EdinetCacheStore(cacheDir: tmpDir)
        client = EdinetAPIClient(apiKey: nil, cacheStore: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testDocumentIndexBuildsYearCacheFromDailyCaches() async throws {
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

        let docs = await client.ensureDocumentIndexForYear(2024)
        let cached = store.loadDocumentIndex(2024, requiredThrough: "2024-12-31")

        XCTAssertEqual(docs.count, 1)
        XCTAssertEqual(docs.first?["docID"] as? String, "S100TEST")
        XCTAssertEqual(docs.first?["_edinet_list_date"] as? String, "2024-06-24")
        XCTAssertEqual(cached?.count, 1)
        XCTAssertEqual(cached?.first?["docID"] as? String, "S100TEST")
    }

    func testGetDocumentsForDateRangeUsesYearIndexForWideRanges() async throws {
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

        XCTAssertEqual(docsByDate["2024-06-24"]??.first?["docID"] as? String, "IN")
        let allDocIDs = docsByDate.values.flatMap { ($0 ?? []).compactMap { $0["docID"] as? String } }
        XCTAssertFalse(allDocIDs.contains("OUT"))
        // API キーなしのため、インデックスを使わず日次フェッチに落ちていたら nil になる
        XCTAssertFalse(docsByDate.values.contains { $0 == nil })
    }

    func testDocumentsForDatePrefersStaleSearchCache() async throws {
        // hit TTL 0 → 保存直後でも期限切れ。API キーなし → 取得失敗 → 期限切れキャッシュへフォールバック
        let staleStore = EdinetCacheStore(cacheDir: tmpDir, searchHitTTLDays: 0)
        let staleClient = EdinetAPIClient(apiKey: nil, cacheStore: staleStore)
        let today = ServiceTestSupport.iso(Date())
        let filename = staleStore.searchCacheKey(today)
        staleStore.saveSearchCache(filename, data: [["docID": "S100STALE", "docTypeCode": "120"]])
        XCTAssertNil(staleStore.loadSearchCache(filename))  // 通常読み込みでは期限切れ

        let docs = await staleClient.getDocumentsForDate(today)

        XCTAssertEqual(docs?.first?["docID"] as? String, "S100STALE")
    }

    func testDocumentIndexPrefersStaleIndex() async throws {
        let year = ServiceTestSupport.currentUTCYear()
        let documents: [[String: Any]] = [["docID": "S100STALE", "docTypeCode": "120"]]
        store.saveDocumentIndex(year, documents: documents, builtThrough: "\(year)-01-01")

        // built_through が古くても再構築せずにインデックスを返す
        // （API キーなしのため、再構築に走ると空配列になる）
        let docs = await client.ensureDocumentIndexForYear(year)

        XCTAssertEqual(docs.count, 1)
        XCTAssertEqual(docs.first?["docID"] as? String, "S100STALE")
    }

    func testDocumentIndexCatchupFetchesOnlyMissingDates() async throws {
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

        XCTAssertEqual(docs.compactMap { $0["docID"] as? String }, ["OLD", "NEW"])
        XCTAssertEqual(cachedInfo?["built_through"] as? String, support.iso(today))
    }
}
