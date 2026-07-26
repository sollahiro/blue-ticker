// GeographyBreakdownResolver のユニットテスト。
// DevCLI live geography 分岐と同じ振り分け（not_found / xbrl_facts / html_table）を
// smoke golden + モック LLM で検証する。

import Foundation
import Testing

@testable import BlueTickerCore

private actor MockChatCompleting: ChatCompleting {
    private let responseJSON: [String: Any]?
    private(set) var callCount = 0

    init(responseJSON: [String: Any]?) {
        self.responseJSON = responseJSON
    }

    func complete(system: String, user: String, jsonSchema: Data, schemaName: String) async throws -> Data {
        callCount += 1
        guard let responseJSON else { throw ChatCompletionError.emptyContent }
        return try JSONSerialization.data(withJSONObject: responseJSON)
    }

    func timesCalled() async -> Int { callCount }
}

@Suite struct GeographyBreakdownResolverTests {

    private static func loadGolden() throws -> [String: [String: Any]] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let path = root.appendingPathComponent("smoke/breakdown_extraction_expected.json")
        let data = try Data(contentsOf: path)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
    }

    private static func loadSales(code: String) throws -> Double? {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dir = root.appendingPathComponent("smoke/smoke_expected")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return nil
        }
        let matches = files.filter { $0.hasPrefix("\(code)_") }.sorted()
        for file in matches {
            let data = try Data(contentsOf: dir.appendingPathComponent(file))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let income = json?["income_statement"] as? [String: Any]
            if let sales = (income?["sales"] as? NSNumber)?.doubleValue { return sales }
        }
        return nil
    }

    private static func geographyResult(docID: String) throws -> ExtractedBreakdown {
        let golden = try loadGolden()
        let entry = try #require(golden[docID])
        let geoDict = try #require(entry["geography"] as? [String: Any])
        return ExtractedBreakdown(dictionary: geoDict)
    }

    @Test func notFoundReturnsNilWithoutCallingLLM() async throws {
        let geography = ExtractedBreakdown(method: "not_found", tables: [], facts: [])
        let client = MockChatCompleting(responseJSON: nil)

        let (snapshot, source, audit) = await GeographyBreakdownResolver.resolve(
            geography: geography, consolidatedSales: 1_000_000, client: client
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
        #expect(audit == nil)
        #expect(await client.timesCalled() == 0)
    }

    /// 味の素 geography は html_table。LLM 成功時は geography_llm。
    @Test func htmlTableResolvesViaGeographyLLM() async throws {
        let geography = try Self.geographyResult(docID: "S100VXJA")
        #expect(geography.method == "html_table")
        let sales = try #require(try Self.loadSales(code: "2802"))

        let halfMillionYen = (sales / 2) / Financial.millionYen
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "日本", "amount": halfMillionYen, "row_kind": "segment"],
                ["label": "海外", "amount": halfMillionYen, "row_kind": "segment"],
            ],
            "notes": "test",
        ]
        let client = MockChatCompleting(responseJSON: response)

        let (snapshot, source, audit) = await GeographyBreakdownResolver.resolve(
            geography: geography, consolidatedSales: sales, client: client
        )

        #expect(source == .geographyLLM)
        #expect(snapshot?.axis == "geography")
        #expect(audit != nil)
        #expect(await client.timesCalled() == 1)
    }

    @Test func htmlTableLLMFailureReturnsNotFoundSource() async throws {
        let geography = try Self.geographyResult(docID: "S100VXJA")
        let sales = try #require(try Self.loadSales(code: "2802"))
        let client = MockChatCompleting(responseJSON: nil)

        let (snapshot, source, _) = await GeographyBreakdownResolver.resolve(
            geography: geography, consolidatedSales: sales, client: client
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
        #expect(await client.timesCalled() == 1)
    }
}
