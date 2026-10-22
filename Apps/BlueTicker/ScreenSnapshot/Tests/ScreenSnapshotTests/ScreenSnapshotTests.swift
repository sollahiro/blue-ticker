import Foundation
import Testing

@testable import ScreenSnapshot

/// サーバー `screenSnapshotJSON` の出力と同じ形（`.sortedKeys`、code 昇順、null は null）。
private let sample = """
    {"code":["0001","0002","0003","0004"],"count":4,
     "market":["プライム","プライム","スタンダード","プライム"],
     "metrics":{"net_de":[0.2,0.1,1.5,null],"roic":[20,25,10,30],"sales":[50000,5000,null,90000]},
     "name":["会社0001","会社0002","会社0003","会社0004"],
     "payout_ratio_3y":[[30,null,40],[null,null,null],[1,2,3],[null,null,null]],
     "period_end":["2025-03-31","2025-03-31","2025-03-31","2025-03-31"],
     "schema_version":1,"screen_version":"screen-v4",
     "sector":["電気機器","電気機器","電気機器","輸送用機器"]}
    """

@Suite struct ScreenSnapshotParseTests {
    @Test func readsColumnsIntoRows() throws {
        let rows = try #require(ScreenSnapshot.parse(Data(sample.utf8)))
        #expect(rows.map(\.code) == ["0001", "0002", "0003", "0004"])
        #expect(rows[0].name == "会社0001")
        #expect(rows[2].market == "スタンダード")
        #expect(rows[3].sector == "輸送用機器")
        #expect(rows[0]["roic"] == 20)
        #expect(rows[2]["sales"] == nil)
        #expect(rows[3]["net_de"] == nil)
        #expect(rows[0].payoutRatio3y == [30, nil, 40])
    }

    @Test func rejectsOtherSchemaVersionAndRaggedColumns() {
        let otherVersion = sample.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":2")
        #expect(ScreenSnapshot.parse(Data(otherVersion.utf8)) == nil)
        let ragged = sample.replacingOccurrences(of: "\"roic\":[20,25,10,30]", with: "\"roic\":[20,25,10]")
        #expect(ScreenSnapshot.parse(Data(ragged.utf8)) == nil)
        let wrongCount = sample.replacingOccurrences(of: "\"count\":4", with: "\"count\":5")
        #expect(ScreenSnapshot.parse(Data(wrongCount.utf8)) == nil)
        #expect(ScreenSnapshot.parse(Data(sample.prefix(120).utf8)) == nil)
    }
}

@Suite struct ScreenSnapshotSearchTests {
    private let rows = ScreenSnapshot.parse(Data(sample.utf8)) ?? []

    /// `ScreenIngestTests.screenEndpointFiltersSortsAndLimits` と同じ条件・同じ答え。
    @Test func matchesRestFilterSortAndLimit() {
        let filtered = ScreenSnapshot.search(
            rows, sectors: ["電気機器"],
            filters: [
                .init(key: "sales", min: 10000, max: nil),
                .init(key: "net_de", min: nil, max: 1),
            ],
            sort: "roic")
        #expect(filtered.rows.map(\.code) == ["0001"])
        #expect(filtered.matched == 1)

        let top = ScreenSnapshot.search(rows, sectors: [], filters: [], sort: "roic", limit: 2)
        #expect(top.rows.map(\.code) == ["0004", "0002"])
        #expect(top.matched == 4)

        let ascending = ScreenSnapshot.search(
            rows, sectors: [], filters: [], sort: "sales", descending: false, limit: 2)
        #expect(ascending.rows.map(\.code) == ["0002", "0001"])
        #expect(ascending.matched == 3)
    }

    @Test func dropsNullFilterTargetsAndKeepsInclusiveBounds() {
        let result = ScreenSnapshot.search(
            rows, sectors: [], filters: [.init(key: "net_de", min: 0.1, max: 1.5)], sort: "roic")
        #expect(result.rows.map(\.code) == ["0002", "0001", "0003"])
    }

    @Test func sectorsAreOrAndTiesBreakByCode() {
        let tied = rows.map { row -> ScreenSnapshot.Row in
            var copy = row
            copy.metrics["roic"] = 10
            return copy
        }
        let result = ScreenSnapshot.search(
            tied, sectors: ["輸送用機器", "電気機器"], filters: [], sort: "roic", limit: 3)
        #expect(result.rows.map(\.code) == ["0001", "0002", "0003"])
        #expect(result.matched == 4)
    }
}

@Suite struct ScreenSnapshotRevalidationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func revalidatesWhenMissingStaleOrFromTheFuture() {
        #expect(ScreenSnapshot.needsRevalidation(nil, now: now))
        let fresh = ScreenSnapshot.Record(body: Data(), etag: "\"a\"", fetchedAt: now.addingTimeInterval(-60))
        #expect(!ScreenSnapshot.needsRevalidation(fresh, now: now))
        var stale = fresh
        stale.fetchedAt = now.addingTimeInterval(-ScreenSnapshot.revalidateInterval)
        #expect(ScreenSnapshot.needsRevalidation(stale, now: now))
        var future = fresh
        future.fetchedAt = now.addingTimeInterval(60)
        #expect(ScreenSnapshot.needsRevalidation(future, now: now))
    }

    @Test func sendsIfNoneMatchOnlyWithStoredEtag() {
        #expect(ScreenSnapshot.requestHeaders(for: nil).isEmpty)
        let record = ScreenSnapshot.Record(body: Data(), etag: "\"a\"", fetchedAt: now)
        #expect(ScreenSnapshot.requestHeaders(for: record) == ["If-None-Match": "\"a\""])
    }

    @Test func notModifiedKeepsBodyAndAdvancesFetchedAt() {
        let previous = ScreenSnapshot.Record(
            body: Data(sample.utf8), etag: "\"a\"", fetchedAt: now.addingTimeInterval(-7200))
        let outcome = ScreenSnapshot.outcome(
            status: 304, etag: "\"a\"", body: Data(), previous: previous, now: now)
        var expected = previous
        expected.fetchedAt = now
        #expect(outcome == .notModified(expected))
        #expect(
            ScreenSnapshot.outcome(status: 304, etag: nil, body: Data(), previous: nil, now: now)
                == .failed)
    }

    @Test func okReplacesOnlyWhenParsable() {
        let outcome = ScreenSnapshot.outcome(
            status: 200, etag: "\"b\"", body: Data(sample.utf8), previous: nil, now: now)
        guard case .replaced(let record, let rows) = outcome else {
            Issue.record("expected replaced, got \(outcome)")
            return
        }
        #expect(record.etag == "\"b\"")
        #expect(record.fetchedAt == now)
        #expect(rows.count == 4)
        #expect(
            ScreenSnapshot.outcome(status: 200, etag: nil, body: Data("{}".utf8), previous: nil, now: now)
                == .failed)
        #expect(
            ScreenSnapshot.outcome(status: 503, etag: nil, body: Data(), previous: nil, now: now)
                == .failed)
    }
}
