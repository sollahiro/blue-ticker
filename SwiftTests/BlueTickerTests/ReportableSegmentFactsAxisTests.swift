// 報告セグメント facts は member 名が地域名でも事業名との混在でも segment 軸の正本になる。
// 事業／地域の軸判定（axis_ambiguous）は product_service 側の話で、segment 軸を表経路へ落とさない。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct ReportableSegmentFactsAxisTests {
    private func resolve(_ docID: String) async -> (BreakdownSnapshot?, SegmentBreakdownSource)? {
        await SmokeCacheSupport.ensureCached([docID])
        let xbrlDir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: xbrlDir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし")
            return nil
        }
        let reportable = BreakdownExtractor.extractReportableSegmentInfo(xbrlDir: xbrlDir)
        let financials = StatementFinancialsResolver.resolve(xbrlDir: xbrlDir)
        let (snapshot, source, _) = await SegmentBreakdownResolver.resolve(
            reportable: reportable,
            consolidatedSales: financials?.geographyCoverageSales ?? financials?.sales,
            labelsByTag: XBRLUtils.loadLabelsByTag(in: xbrlDir), docID: docID, xbrlDir: xbrlDir)
        return (snapshot, source)
    }

    private func m(_ n: Double) -> Double { n * 1_000_000 }

    @Test func geographicReportableSegmentsResolveFromFacts() async throws {
        guard let (snapshot, source) = await resolve("S100YC23") else { return }
        #expect(source == .xbrlFacts)
        let rows = try #require(snapshot).rows.filter { $0.rowKind == "segment" }
        #expect(rows.count == 6)
        #expect(Set(rows.compactMap(\.amount)) == Set([
            m(447_868), m(425_037), m(33_266), m(86_198), m(102_908), m(51_492),
        ]))
        #expect(snapshot?.needsReview == false)
    }

    @Test func mixedBusinessAndRegionalReportableSegmentsResolveFromFacts() async throws {
        guard let (snapshot, source) = await resolve("S100YEWB") else { return }
        #expect(source == .xbrlFacts)
        let amounts = Set(try #require(snapshot).rows.filter { $0.rowKind == "segment" }.compactMap(\.amount))
        for amount in [241_940.0, 48_302, 104_167, 95_942, 163_713, 74_945] {
            #expect(amounts.contains(m(amount)))
        }
        #expect(snapshot?.needsReview == false)
    }
}
