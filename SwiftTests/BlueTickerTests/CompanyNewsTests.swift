import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct CompanyNewsTests {
    @Test func searchQueryStripsKabushikiKaisha() {
        #expect(companyNewsSearchQuery(name: "トヨタ自動車株式会社", code: "7203") == "トヨタ自動車")
        #expect(companyNewsSearchQuery(name: "   ", code: "7203") == "7203")
    }

    @Test func parseLimitClamps() {
        #expect(parseCompanyNewsLimit(nil) == Api.companyNewsLimitDefault)
        #expect(parseCompanyNewsLimit(0) == 1)
        #expect(parseCompanyNewsLimit(100) == Api.companyNewsLimitMax)
        #expect(parseCompanyNewsLimit(7) == 7)
    }

    @Test func decodeBraveNewsSearchMapsResults() throws {
        let json = """
            {
              "type": "news",
              "query": { "original": "富士フイルム" },
              "results": [
                {
                  "title": "見出し",
                  "url": "https://example.com/n",
                  "description": "本文",
                  "age": "1 日前",
                  "page_age": "2026-09-03T12:00:00",
                  "profile": { "name": "Example" },
                  "thumbnail": { "src": "https://example.com/thumb.jpg" }
                },
                {
                  "title": "",
                  "url": "https://example.com/skip"
                }
              ]
            }
            """
        let page = try decodeBraveNewsSearch(from: Data(json.utf8))
        #expect(page.query == "富士フイルム")
        #expect(page.items.count == 1)
        #expect(page.items[0].title == "見出し")
        #expect(page.items[0].source == "Example")
        #expect(page.items[0].publishedAt == "2026-09-03T12:00:00")
        #expect(page.items[0].thumbnailURL == "https://example.com/thumb.jpg")
    }

    @Test func assembleCompanyNewsEnvelope() {
        let body = assembleCompanyNews(
            code: "4901",
            name: "富士フイルムホールディングス株式会社",
            query: "富士フイルムホールディングス",
            items: [
                CompanyNewsItem(title: "t", url: "https://www.nikkei.com/article/x", source: "s")
            ],
            now: Date(timeIntervalSince1970: 1_778_000_000))
        #expect(body["schema_version"] as? Int == Api.companyNewsSchemaVersion)
        #expect(body["code"] as? String == "4901")
        #expect(body["query"] as? String == "富士フイルムホールディングス")
        let items = body["items"] as? [[String: Any]]
        #expect(items?.first?["source"] as? String == "s")
        #expect(items?.first?["age"] == nil)
    }

    @Test func braveQueryAppendsSiteAllowlist() {
        let q = companyNewsBraveQuery(name: "富士フイルムホールディングス株式会社", code: "4901")
        #expect(q.hasPrefix("富士フイルムホールディングス ("))
        #expect(q.contains("site:nikkei.com"))
        #expect(q.contains("site:toyokeizai.net"))
        #expect(q.contains("site:reuters.com"))
        #expect(q.contains("site:bloomberg.co.jp"))
        #expect(q.contains("site:release.tdnet.info"))
        #expect(q.contains("site:prtimes.jp"))
        #expect(q.contains("site:plantdb.jp"))
        #expect(q.contains("site:logi-today.com"))
        #expect(q.contains("site:semi-journal.jp/news"))
    }

    @Test func allowedURLFilterKeepsCuratedHostsOnly() {
        let items = [
            CompanyNewsItem(title: "日経", url: "https://www.nikkei.com/article/1"),
            CompanyNewsItem(title: "東洋経済", url: "https://toyokeizai.net/articles/-/1"),
            CompanyNewsItem(title: "Yahoo", url: "https://news.yahoo.co.jp/articles/1"),
            CompanyNewsItem(title: "PR TIMES", url: "https://prtimes.jp/main/html/rd/p/000000001.000000001.html"),
            CompanyNewsItem(title: "SEMI news", url: "https://semi-journal.jp/news/latest.html"),
            CompanyNewsItem(title: "SEMI basics", url: "https://semi-journal.jp/basics/water/edi.html"),
            CompanyNewsItem(title: "PlantDB", url: "https://plantdb.jp/article/abc"),
            CompanyNewsItem(title: "LOGI", url: "https://www.logi-today.com/123"),
        ]
        let kept = filterCompanyNewsByAllowedSources(items).map(\.title)
        #expect(kept == ["日経", "東洋経済", "PR TIMES", "SEMI news", "PlantDB", "LOGI"])
    }
}
