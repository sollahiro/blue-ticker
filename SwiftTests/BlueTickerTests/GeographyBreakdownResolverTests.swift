// GeographyBreakdownResolver のユニットテスト。
// geography 軸の振り分け（not_found / xbrl_facts / html_table）を
// smoke golden + Fake Jev 列選択で検証する。ネットワークは使わない。

import Foundation
import Testing

@testable import BlueTickerCore

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

    @Test func notFoundReturnsNilWithoutColumnDecider() async throws {
        let geography = ExtractedBreakdown(method: "not_found", tables: [], facts: [])

        let (snapshot, source, audit) = await GeographyBreakdownResolver.resolve(
            geography: geography, consolidatedSales: 1_000_000,
            columnDecider: FakeRevenueRecognitionColumnDecider()
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
        #expect(audit == nil)
    }

    /// 味の素 geography は html_table。Jev 列選択で geography_llm。
    @Test func htmlTableResolvesViaGeographyJev() async throws {
        let geography = try Self.geographyResult(docID: "S100VXJA")
        #expect(geography.method == "html_table")
        let sales = try #require(try Self.loadSales(code: "2802"))

        let (snapshot, source, audit) = await GeographyBreakdownResolver.resolve(
            geography: geography, consolidatedSales: sales,
            columnDecider: FakeRevenueRecognitionColumnDecider(),
            fiscalYearEnd: "2025-03-31",
            docID: "S100VXJA"
        )

        #expect(source == .geographyLLM)
        #expect(snapshot?.axis == "geography")
        #expect(audit != nil)
        #expect(audit?.jev != nil)
        let snap = try #require(snapshot)
        #expect(!snap.rows.filter { $0.rowKind == "segment" }.isEmpty)
    }

    @Test func htmlTableWithoutDeciderReturnsNotFound() async throws {
        let geography = try Self.geographyResult(docID: "S100VXJA")
        let sales = try #require(try Self.loadSales(code: "2802"))

        let (snapshot, source, _) = await GeographyBreakdownResolver.resolve(
            geography: geography, consolidatedSales: sales, columnDecider: nil
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
    }
}
