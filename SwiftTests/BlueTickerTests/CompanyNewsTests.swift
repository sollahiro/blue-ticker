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
                CompanyNewsItem(title: "t", url: "https://example.com", source: "s")
            ],
            now: Date(timeIntervalSince1970: 1_778_000_000))
        #expect(body["schema_version"] as? Int == Api.companyNewsSchemaVersion)
        #expect(body["code"] as? String == "4901")
        #expect(body["query"] as? String == "富士フイルムホールディングス")
        let items = body["items"] as? [[String: Any]]
        #expect(items?.first?["source"] as? String == "s")
        #expect(items?.first?["age"] == nil)
    }
}
