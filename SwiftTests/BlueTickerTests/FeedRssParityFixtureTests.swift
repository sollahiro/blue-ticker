// Feed RSS Worker（workers/feed-rss）とのパリティテスト。
// 共有 fixture（workers/feed-rss/test-fixtures/feed-parity.json）を正本に、
// Swift 側の docTypeLabel / feedAllowedDocTypes / ordinanceCompanyDisclosure /
// listedTickerCode / feedFilingItem が fixture の期待値と一致することを検証する。
// JS 側は workers/feed-rss/src/parity.test.js が同じ fixture で検証する。

import Foundation
import Testing

@testable import BlueTickerCore

// fixture の Codable 写像。feedItems.item は feedFilingItem の戻り値（全値 String）。
private struct FeedParityFixture: Decodable {
    struct TickerCase: Decodable {
        let secCode: String?
        let code: String?
    }
    struct ItemCase: Decodable {
        struct Record: Decodable {
            let docID: String
            let edinetCode: String
            let secCode: String?
            let filerName: String
            let docTypeCode: String?
            let ordinanceCode: String?
            let periodEnd: String?
            let submitDateTime: String
            let docDescription: String?
        }
        let record: Record
        let item: [String: String]?
    }
    let docTypeLabels: [String: String]
    let feedDocTypes: [String]
    let ordinanceCompanyDisclosure: String
    let listedTickerCode: [TickerCase]
    let feedItems: [ItemCase]
}

// このテストファイルは SwiftTests/BlueTickerTests/ にある。3 つ上がリポジトリルート。
private func loadFeedParityFixture() throws -> FeedParityFixture {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("workers/feed-rss/test-fixtures/feed-parity.json")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(FeedParityFixture.self, from: data)
}

@Suite struct FeedRssParityFixtureTests {
    @Test func docTypeLabelsMatchFixture() throws {
        let fixture = try loadFeedParityFixture()
        #expect(!fixture.docTypeLabels.isEmpty)
        for (code, label) in fixture.docTypeLabels {
            #expect(docTypeLabel(code) == label)
        }
    }

    @Test func feedDocTypesMatchFixture() throws {
        let fixture = try loadFeedParityFixture()
        #expect(Set(Api.feedAllowedDocTypes) == Set(fixture.feedDocTypes))
        #expect(Api.ordinanceCompanyDisclosure == fixture.ordinanceCompanyDisclosure)
    }

    @Test func listedTickerCodeMatchesFixture() throws {
        let fixture = try loadFeedParityFixture()
        for tickerCase in fixture.listedTickerCode {
            #expect(listedTickerCode(fromSecCode: tickerCase.secCode) == tickerCase.code)
        }
    }

    @Test func feedFilingItemMatchesFixture() throws {
        let fixture = try loadFeedParityFixture()
        for itemCase in fixture.feedItems {
            let record = itemCase.record
            let document = EdinetDocumentRecord(
                docID: record.docID,
                edinetCode: record.edinetCode,
                secCode: record.secCode,
                filerName: record.filerName,
                docTypeCode: record.docTypeCode,
                ordinanceCode: record.ordinanceCode,
                formCode: nil,
                periodStart: nil,
                periodEnd: record.periodEnd,
                submitDateTime: record.submitDateTime,
                docDescription: record.docDescription)
            // 戻り値は [String: Any] だが公開契約上すべて String。比較用にキャストする。
            let item = feedFilingItem(from: document).map { dict in
                dict.mapValues { $0 as? String ?? "" }
            }
            #expect(item == itemCase.item)
        }
    }
}
