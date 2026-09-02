// 富士フイルム S100YIBH（FY2026-03 米国基準）の積み上げセグメント表で、
// get_breakdown axis=business の profit が研究開発費ではなくセグメント営業利益になること。
// S100W3XJ（FY2025-03）も同型の積み上げ表。差は会計基準ではなく行寄せ。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct RealXbrlFujifilmStackedSegmentPnLTests {

    private static let docID = "S100YIBH"
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        guard FileManager.default.fileExists(atPath: xbrlDir(docID).path) else {
            TestVerboseLog.print("SKIP   \(docID): XBRL キャッシュなし")
            return false
        }
        return true
    }

    private actor RejectLLM: ChatCompleting {
        func complete(system: String, user: String, jsonSchema: Data, schemaName: String) async throws -> Data {
            Issue.record("LLM must not be called for stacked segment P&L")
            throw ChatCompletionError.emptyContent
        }
    }

    @Test func s100YIBHProfitIsSegmentOperatingProfitNotRD() async throws {
        guard await Self.ensureAvailable(Self.docID) else { return }

        let dir = Self.xbrlDir(Self.docID)
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
        #expect(segments.method == "html_table")
        #expect(!segments.tables.isEmpty)

        let sales = 3_356_969 * Financial.millionYen
        let client = RejectLLM()
        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .stackedSegmentPnL)
        #expect(audit == nil)
        let snap = try #require(snapshot)
        #expect(snap.sourceKind == "stacked_segment_pnl")

        let byLabel = Dictionary(
            uniqueKeysWithValues: snap.rows.filter { $0.rowKind == "segment" }.map {
                ($0.labelRaw, $0)
            })
        // PDF セグメント営業利益（百万円）
        #expect(byLabel["ヘルスケア"]?.amount == 1_098_925 * Financial.millionYen)
        #expect(byLabel["ヘルスケア"]?.profit == 63_637 * Financial.millionYen)
        #expect(byLabel["エレクトロニクス"]?.amount == 456_157 * Financial.millionYen)
        #expect(byLabel["エレクトロニクス"]?.profit == 100_883 * Financial.millionYen)
        #expect(byLabel["ビジネスイノベーション"]?.amount == 1_174_800 * Financial.millionYen)
        #expect(byLabel["ビジネスイノベーション"]?.profit == 63_712 * Financial.millionYen)
        #expect(byLabel["イメージング"]?.amount == 627_087 * Financial.millionYen)
        #expect(byLabel["イメージング"]?.profit == 160_003 * Financial.millionYen)

        // 研究開発費ではないこと
        #expect(byLabel["ヘルスケア"]?.profit != 53_346 * Financial.millionYen)
        #expect(byLabel["エレクトロニクス"]?.profit != 28_209 * Financial.millionYen)
        #expect(byLabel["ビジネスイノベーション"]?.profit != 55_406 * Financial.millionYen)
        #expect(byLabel["イメージング"]?.profit != 13_366 * Financial.millionYen)
    }
}
