// Feed Trend のイベント正規化と公開 JSON 組み立て（ネットワーク非依存）。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct FeedTrendTests {
    @Test func tickerCodeAcceptsFourCharacterJPCodes() {
        #expect(feedTrendTickerCode("7203") == "7203")
        #expect(feedTrendTickerCode("477a") == "477A")
        #expect(feedTrendTickerCode(" 6758 ") == "6758")
        #expect(feedTrendTickerCode("72030") == nil)
        #expect(feedTrendTickerCode("12") == nil)
        #expect(feedTrendTickerCode("7203!") == nil)
    }

    @Test func parseCodeParamDistinguishesOmitAndInvalid() {
        #expect(parseFeedTrendCodeParam(nil) == .omitted)
        #expect(parseFeedTrendCodeParam("") == .omitted)
        #expect(parseFeedTrendCodeParam("7203") == .valid("7203"))
        #expect(parseFeedTrendCodeParam("72030") == .invalid)
    }

    @Test func makeEventAllowlistsToolAndSurface() {
        #expect(makeFeedTrendEvent(surface: "rest", tool: "get_feed_trend") == nil)
        #expect(makeFeedTrendEvent(surface: "rest", tool: "get_feed_updates") == nil)
        #expect(makeFeedTrendEvent(surface: "web", tool: "search_companies", q: "トヨタ") == nil)
        let search = makeFeedTrendEvent(surface: "rest", tool: "search_companies", q: "トヨタ")
        #expect(search?.surface == "rest")
        #expect(search?.tool == "search_companies")
        #expect(search?.code == nil)
        #expect(search?.q == "トヨタ")
    }

    @Test func searchCompaniesSetsCodeWhenQueryIsTicker() {
        let event = makeFeedTrendEvent(surface: "mcp", tool: "search_companies", q: "7203")
        #expect(event?.code == "7203")
        #expect(event?.q == "7203")
    }

    @Test func nonSearchToolsDropQuery() {
        let event = makeFeedTrendEvent(
            surface: "rest", tool: "get_financial_summary", code: "7203", q: "should-not-store")
        #expect(event?.code == "7203")
        #expect(event?.q == nil)
        #expect(event?.jsonObject()["q"] == nil)
    }

    @Test func queryIsClippedToMaxLength() {
        let long = String(repeating: "あ", count: Api.feedTrendQueryMaxLength + 10)
        let event = makeFeedTrendEvent(surface: "rest", tool: "search_companies", q: long)
        #expect(event?.q?.count == Api.feedTrendQueryMaxLength)
    }

    @Test func assembleRankingOmitsBreakdownsWithoutCodeFilter() {
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 8))!
        let json = assembleFeedTrend(
            ranking: FeedTrendRanking(items: [
                FeedTrendBucket(code: "7203", count: 12),
                FeedTrendBucket(code: "6758", count: 4),
            ]),
            names: ["7203": "トヨタ自動車株式会社"],
            days: 7,
            code: nil,
            now: now
        )
        #expect(json["schema_version"] as? Int == Api.feedTrendSchemaVersion)
        #expect(json["date"] as? String == "2026-08-22")
        #expect(json["days"] as? Int == 7)
        #expect(json["code"] == nil)
        #expect(json["by_tool"] == nil)
        let items = json["items"] as? [[String: Any]]
        #expect(items?.count == 2)
        #expect(items?.first?["code"] as? String == "7203")
        #expect(items?.first?["name"] as? String == "トヨタ自動車株式会社")
        #expect(items?.first?["count"] as? Int == 12)
        #expect(items?.last?["name"] as? String == "")
        #expect(items?.first?["icon_url"] == nil)
    }

    @Test func assembleRankingIncludesBreakdownsWhenCodeFiltered() {
        let json = assembleFeedTrend(
            ranking: FeedTrendRanking(
                items: [FeedTrendBucket(code: "7203", count: 3)],
                byTool: [FeedTrendLabelCount(label: "search_companies", count: 2)],
                bySurface: [FeedTrendLabelCount(label: "mcp", count: 3)],
                byQuery: [FeedTrendLabelCount(label: "トヨタ", count: 2)]
            ),
            names: ["7203": "トヨタ自動車株式会社"],
            days: 1,
            code: "7203"
        )
        #expect(json["code"] as? String == "7203")
        let byTool = json["by_tool"] as? [[String: Any]]
        #expect(byTool?.first?["tool"] as? String == "search_companies")
        #expect((json["by_surface"] as? [[String: Any]])?.first?["surface"] as? String == "mcp")
        #expect((json["by_query"] as? [[String: Any]])?.first?["q"] as? String == "トヨタ")
    }

    @Test func decodeWorkerRankingCoercesCounts() throws {
        let data = """
            {"days":7,"items":[{"code":"7203","count":12.4},{"code":"bad","count":1}],\
            "by_tool":[{"tool":"search_companies","count":"3"}]}
            """.data(using: .utf8)!
        let ranking = try decodeFeedTrendRanking(from: data)
        #expect(ranking.items == [FeedTrendBucket(code: "7203", count: 12)])
        #expect(ranking.byTool == [FeedTrendLabelCount(label: "search_companies", count: 3)])
    }
}
