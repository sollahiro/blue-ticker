import Foundation
import Testing

@testable import FeedRSS

/// `workers/feed-rss/src/rss.js` の出力（2026-10-20 生成分から抜粋）と同じ形。
private let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
      <channel>
        <title>有報LAB — 直近提出書類</title>
        <link>https://yuholab.com</link>
        <lastBuildDate>Tue, 20 Oct 2026 19:15:40 +0900</lastBuildDate>
        <item>
          <title>中部水産株式会社（8145） 訂正有価証券報告書</title>
          <link>https://disclosure2.edinet-fsa.go.jp/WZEK0040.aspx?S100Z8W1</link>
          <guid isPermaLink="false">S100Z8W1</guid>
          <pubDate>Tue, 20 Oct 2026 15:18:00 +0900</pubDate>
          <category domain="edinet:doc_type">130</category>
          <category domain="jp:sec_code">8145</category>
          <description>決算期:  / 証券コード: 8145</description>
          <media:thumbnail url="https://icons.sollahiro.com/company-icons/8145.png"/>
        </item>
        <item>
          <title>A&amp;B（サンプル）ホールディングス株式会社（477A） 有価証券報告書</title>
          <guid isPermaLink="false">S100AAAA</guid>
          <pubDate>Wed, 14 Oct 2026 00:05:00 +0900</pubDate>
          <category domain="edinet:doc_type">120</category>
          <category domain="jp:sec_code">477A</category>
        </item>
        <item>
          <title>コード無し株式会社（1111） 有価証券報告書</title>
          <guid isPermaLink="false">S100BBBB</guid>
        </item>
      </channel>
    </rss>
    """

@Suite struct FeedRSSParseTests {
    @Test func readsItemsInFeedOrder() throws {
        let items = try #require(FeedRSS.parse(Data(sample.utf8)))
        #expect(items.map(\.docId) == ["S100Z8W1", "S100AAAA"])

        let first = items[0]
        #expect(first.code == "8145")
        #expect(first.name == "中部水産株式会社")
        #expect(first.docType == "130")
        #expect(first.docTypeLabel == "訂正有価証券報告書")
        #expect(first.submittedAt == "2026-10-20 15:18")
        #expect(first.iconURL == "https://icons.sollahiro.com/company-icons/8145.png")
    }

    @Test func nameKeepsParenthesesBeforeTheCode() throws {
        let items = try #require(FeedRSS.parse(Data(sample.utf8)))
        let second = items[1]
        #expect(second.code == "477A")
        #expect(second.name == "A&B（サンプル）ホールディングス株式会社")
        #expect(second.docTypeLabel == "有価証券報告書")
        #expect(second.iconURL == nil)
        #expect(second.submittedAt == "2026-10-14 00:05")
    }

    @Test func titleWithoutCodeIsTheName() {
        let split = FeedRSS.splitTitle("テスト株式会社 有価証券報告書", code: "7203")
        #expect(split.name == "テスト株式会社 有価証券報告書")
        #expect(split.label == "")
    }

    @Test func pubDateInOtherOffsetIsShownInJST() {
        let dates = FeedRSS.PubDateFormatter()
        #expect(dates.jstMinute("Tue, 20 Oct 2026 06:18:00 +0000") == "2026-10-20 15:18")
        #expect(dates.jstMinute("not a date") == nil)
    }

    @Test func topFeedKeepsOnlyAnnualReportsInFeedOrder() throws {
        let items = try #require(FeedRSS.parse(Data(sample.utf8)))
        #expect(FeedRSS.topFeed(items).map(\.docId) == ["S100AAAA"])
    }

    @Test func topFeedStopsAtTenNewestAnnualReports() {
        let items = (0..<15).map { index in
            FeedRSS.Item(
                docId: "S\(index)", code: "1000", name: "x", docType: index.isMultiple(of: 3) ? "160" : "120",
                docTypeLabel: "", submittedAt: "", iconURL: nil)
        }
        let top = FeedRSS.topFeed(items)
        #expect(top.count == FeedRSS.topFeedLimit)
        #expect(top.allSatisfy { $0.docType == "120" })
        #expect(top.first?.docId == "S1")
    }

    @Test func emptyChannelIsEmptyList() throws {
        let xml = #"<?xml version="1.0"?><rss version="2.0"><channel><title>x</title></channel></rss>"#
        let items = try #require(FeedRSS.parse(Data(xml.utf8)))
        #expect(items.isEmpty)
    }

    @Test func brokenOrNonRSSIsNil() {
        #expect(FeedRSS.parse(Data("<rss><channel><item>".utf8)) == nil)
        #expect(FeedRSS.parse(Data(#"{"items":[]}"#.utf8)) == nil)
        #expect(FeedRSS.parse(Data("<feed></feed>".utf8)) == nil)
    }
}

@Suite struct FeedRSSRevalidationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(fetchedAgo seconds: TimeInterval) -> FeedRSS.Record {
        FeedRSS.Record(
            xml: Data(sample.utf8),
            etag: #""45a5bf""#,
            lastModified: "Tue, 20 Oct 2026 10:15:42 GMT",
            fetchedAt: now.addingTimeInterval(-seconds)
        )
    }

    @Test func revalidatesOnlyAfterMaxAge() {
        #expect(FeedRSS.needsRevalidation(nil, now: now))
        #expect(FeedRSS.needsRevalidation(record(fetchedAgo: 59 * 60), now: now) == false)
        #expect(FeedRSS.needsRevalidation(record(fetchedAgo: 60 * 60), now: now))
        // 端末の時計が戻ったら取り直す。
        #expect(FeedRSS.needsRevalidation(record(fetchedAgo: -10), now: now))
    }

    @Test func conditionalHeadersCarryValidators() {
        let headers = FeedRSS.requestHeaders(for: record(fetchedAgo: 0))
        #expect(headers["If-None-Match"] == #""45a5bf""#)
        #expect(headers["If-Modified-Since"] == "Tue, 20 Oct 2026 10:15:42 GMT")

        let first = FeedRSS.requestHeaders(for: nil)
        #expect(first["If-None-Match"] == nil)
        #expect(first["If-Modified-Since"] == nil)
        #expect(first["Accept"] != nil)
    }

    @Test func notModifiedKeepsXMLAndAdvancesFetchTime() {
        let previous = record(fetchedAgo: 2 * 60 * 60)
        let outcome = FeedRSS.outcome(
            status: 304, etag: nil, lastModified: nil, body: Data(), previous: previous, now: now)
        var expected = previous
        expected.fetchedAt = now
        #expect(outcome == .notModified(expected))
    }

    @Test func notModifiedWithoutSavedCopyFails() {
        let outcome = FeedRSS.outcome(
            status: 304, etag: nil, lastModified: nil, body: Data(), previous: nil, now: now)
        #expect(outcome == .failed)
    }

    @Test func okReplacesTheSavedCopy() throws {
        let body = Data(sample.utf8)
        let outcome = FeedRSS.outcome(
            status: 200, etag: #""new""#, lastModified: "Wed, 21 Oct 2026 10:15:42 GMT",
            body: body, previous: record(fetchedAgo: 2 * 60 * 60), now: now)
        guard case .replaced(let saved, let items) = outcome else {
            Issue.record("expected .replaced, got \(outcome)")
            return
        }
        #expect(saved == FeedRSS.Record(
            xml: body, etag: #""new""#, lastModified: "Wed, 21 Oct 2026 10:15:42 GMT", fetchedAt: now))
        #expect(items.count == 2)
    }

    @Test func serverErrorOrBrokenBodyFails() {
        let previous = record(fetchedAgo: 2 * 60 * 60)
        #expect(
            FeedRSS.outcome(
                status: 503, etag: nil, lastModified: nil, body: Data(sample.utf8), previous: previous,
                now: now) == .failed)
        #expect(
            FeedRSS.outcome(
                status: 200, etag: nil, lastModified: nil, body: Data("<html>".utf8), previous: previous,
                now: now) == .failed)
    }
}
