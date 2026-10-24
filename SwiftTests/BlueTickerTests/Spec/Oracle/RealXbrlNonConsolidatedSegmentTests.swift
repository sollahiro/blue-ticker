// 実 EDINET XBRL（analysis_cache）での個別のみ提出会社と、のれん償却額の全社重複の golden。
// 値は XBRL の当期 fact（千円単位 decimals=-3）を円で照合する。
//
// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、無ければ SKIP。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RealXbrlNonConsolidatedSegmentTests {
    private static let xbrlRoot = SmokeCacheSupport.cacheDir

    private static func ensureAvailable(_ docID: String) async -> URL? {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        let dir = xbrlRoot.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            TestVerboseLog.print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return nil
        }
        return dir
    }

    private static func segmentFactsAndLabels(
        _ dir: URL
    ) -> (facts: [BreakdownFact], labels: [String: String]) {
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        return (facts, XBRLUtils.breakdownMemberLabels(in: dir))
    }

    /// 2477 手間いらず: 連結なし。個別 NetSales を分母に、アプリ事業が売上の大半でも segment のまま。
    // source: code=2477 fy_end=2026-06-30 doc_id=S100Z3MW page=0 field=segment.アプリケーションサービス事業
    // source: code=2477 fy_end=2026-06-30 doc_id=S100Z3MW page=0 field=segment.インターネットメディア事業
    @Test func temaIrazuNonConsolidatedSegmentsStayReportable() async throws {
        guard let dir = await Self.ensureAvailable("S100Z3MW") else { return }
        let reportable = BreakdownExtractor.extractReportableSegmentInfo(xbrlDir: dir)
        let denom = BreakdownFinancialsResolver.breakdownBusinessSalesDenominatorItem(
            xbrlDir: dir, tables: reportable.tables)
        let result = await SegmentBreakdownResolver.resolve(
            reportable: reportable, consolidatedSales: denom.value,
            labelsByTag: XBRLUtils.loadLabelsByTag(in: dir), denominatorTag: denom.tag,
            fiscalYearEnd: BreakdownExtractor.currentFiscalYearEnd(fromXbrlDir: dir), docID: "S100Z3MW")
        let snapshot = try #require(result.snapshot)
        #expect(snapshot.axis == breakdownAxisSegment)
        #expect(snapshot.denominator == 2_414_083_000)
        let app = try #require(
            snapshot.rows.first { $0.labelRaw == "ApplicationServiceReportableSegmentMember" })
        #expect(app.rowKind == "segment")
        #expect(app.amount == 2_408_545_000)
        #expect(app.profit == 1_915_264_000)
        let media = try #require(
            snapshot.rows.first { $0.labelRaw == "InternetMediaReportableSegmentMember" })
        #expect(media.rowKind == "segment")
        #expect(media.amount == 5_537_000)
        #expect(media.profit == -2_432_000)
        #expect(!snapshot.warnings.contains("sales_denominator_aligned_to_segment_total"))
        #expect(snapshot.needsReview == false)
    }

    /// 2477 手間いらず: セグメント資産の分母は個別 Assets（EntityTotal）。全社資産は reconciling。
    // source: code=2477 fy_end=2026-06-30 doc_id=S100Z3MW page=0 field=segment_assets.total
    @Test func temaIrazuSegmentAssetsUseNonConsolidatedEntityTotal() async throws {
        guard let dir = await Self.ensureAvailable("S100Z3MW") else { return }
        let (facts, labels) = Self.segmentFactsAndLabels(dir)
        let snapshot = try #require(
            BreakdownNormalizer.normalizeSegmentAssets(facts: facts, labelsByTag: labels))
        #expect(snapshot.denominator == 7_145_287_000)
        let app = try #require(
            snapshot.rows.first { $0.labelRaw == "ApplicationServiceReportableSegmentMember" })
        #expect(app.rowKind == "segment")
        #expect(app.amount == 475_431_000)
        #expect(!snapshot.warnings.contains("segment_assets_segment_sum_far_from_total"))
    }

    /// 7320 Solvvy: のれん償却額は全社の 3,702 千円のみ。ReconcilingItems と
    /// UnallocatedAmountsAndElimination の同額を二重計上しない。
    // source: code=7320 fy_end=2026-06-30 doc_id=S100Z3SN page=0 field=goodwill_amortization.調整額
    @Test func solvvyGoodwillAmortizationCountsCorporateAmountOnce() async throws {
        guard let dir = await Self.ensureAvailable("S100Z3SN") else { return }
        let (facts, labels) = Self.segmentFactsAndLabels(dir)
        let snapshot = try #require(
            BreakdownNormalizer.normalizeGoodwillAmortization(facts: facts, labelsByTag: labels))
        #expect(snapshot.denominator == 3_702_000)
        let reconciling = snapshot.rows.filter { $0.rowKind == "reconciling" }
        #expect(reconciling.count == 1)
        #expect(reconciling.map(\.amount).reduce(0, +) == 3_702_000)
        #expect(snapshot.needsReview == false)
    }
}
