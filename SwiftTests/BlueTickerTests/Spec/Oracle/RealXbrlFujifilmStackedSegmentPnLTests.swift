// 富士フイルム積み上げセグメント損益（注記23 a）の実XBRL回帰。
//
// 実測（PublicDoc 本文 ixbrl / instance）:
// - S100W3XJ・S100YIBH とも米国基準（USGAAP TextBlock / RevenuesUSGAAP*）。IFRS ではない。
// - 両年とも同一の積み上げ順: 売上4行+売上高計 → 研究開発費4行+計 → その他費用4行+計
//   → 営業利益4行+計 → 全社費用等 → 連結営業利益。
// - OperatingSegmentsAxis の member 集合と Segment 系 fact localName 集合は両年で一致。
// - 差は会計基準ではなく行寄せ。S100YIBH はケミカル試薬の EL→HC 区分変更で比較年度も組替。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct RealXbrlFujifilmStackedSegmentPnLTests {

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

    /// FY2025-03。格納済み profit は営業利益ブロック（HC 77,635 等）と一致する。
    @Test func s100W3XJProfitIsSegmentOperatingProfitNotRD() async throws {
        guard await Self.ensureAvailable("S100W3XJ") else { return }

        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100W3XJ"))
        #expect(segments.method == "html_table")
        #expect(!segments.tables.isEmpty)

        let sales = 3_195_828 * Financial.millionYen
        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: RejectLLM()
        )

        #expect(source == .stackedSegmentPnL)
        #expect(audit == nil)
        let snap = try #require(snapshot)
        let byLabel = Dictionary(
            uniqueKeysWithValues: snap.rows.filter { $0.rowKind == "segment" }.map {
                ($0.labelRaw, $0)
            })
        #expect(byLabel["ヘルスケア"]?.amount == 1_022_564 * Financial.millionYen)
        #expect(byLabel["ヘルスケア"]?.profit == 77_635 * Financial.millionYen)
        #expect(byLabel["エレクトロニクス"]?.amount == 432_797 * Financial.millionYen)
        #expect(byLabel["エレクトロニクス"]?.profit == 77_315 * Financial.millionYen)
        #expect(byLabel["ビジネスイノベーション"]?.amount == 1_198_494 * Financial.millionYen)
        #expect(byLabel["ビジネスイノベーション"]?.profit == 74_614 * Financial.millionYen)
        #expect(byLabel["イメージング"]?.amount == 541_973 * Financial.millionYen)
        #expect(byLabel["イメージング"]?.profit == 139_214 * Financial.millionYen)
        // 研究開発費ブロック（HC 60,698 等）ではないこと
        #expect(byLabel["ヘルスケア"]?.profit != 60_698 * Financial.millionYen)
        #expect(byLabel["エレクトロニクス"]?.profit != 25_760 * Financial.millionYen)
    }

    /// FY2026-03。誤寄せ時は研究開発費（HC 53,346 等）を segment profit に載せる。
    @Test func s100YIBHProfitIsSegmentOperatingProfitNotRD() async throws {
        guard await Self.ensureAvailable("S100YIBH") else { return }

        let dir = Self.xbrlDir("S100YIBH")
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

        // セグメント行の profit 合計は営業利益計（誤寄せ時の R&D 合計 150,327 ではない）
        let segmentProfitSum = byLabel.values.compactMap(\.profit).reduce(0, +)
        #expect(segmentProfitSum == 388_235 * Financial.millionYen)
        #expect(segmentProfitSum != 150_327 * Financial.millionYen)
    }
}
