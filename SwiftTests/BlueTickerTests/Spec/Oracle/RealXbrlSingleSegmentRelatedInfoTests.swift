// 実 EDINET XBRL（analysis_cache）での単一セグメント会社の golden。セグメント情報のブロックに
// 関連情報の製品・サービス表が同じ形で載っていても、segment 軸に製品区分を出さない。
// 製品区分は product_service 軸にだけ出る。金額は XBRL の表（当期列）を照合する。
//
// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、無ければ SKIP。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RealXbrlSingleSegmentRelatedInfoTests {
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

    // source: code=6526 fy_end=2023-03-31 doc_id=S100R9DF page=0 field=product_service.製品売上
    // source: code=3673 fy_end=2025-12-31 doc_id=S100XS43 page=0 field=product_service.クラウドサービス
    // source: code=7198 fy_end=2026-03-31 doc_id=S100YFMO page=0 field=product_service.オリジネーション関連収益
    @Test(arguments: [
        ("S100R9DF", "t0_c1", 1_000_000.0,
         [("製品売上", 156_751.0), ("ＮＲＥ売上", 34_867.0), ("その他", 1_149.0)]),
        ("S100XS43", "t0_c2", 1_000.0,
         [("クラウドサービス", 11_831_891.0), ("パッケージシステム", 5_698_676.0), ("その他", 3_284_734.0)]),
        ("S100YFMO", "t0_c3", 1_000_000.0,
         [("オリジネーション関連収益", 9_496.0), ("リカーリング収益", 8_900.0), ("アセット・その他収益", 6_689.0)]),
    ])
    func productTableStaysOffSegmentAxis(
        docID: String, column: String, unit: Double, products: [(String, Double)]
    ) async throws {
        guard let dir = await Self.ensureAvailable(docID) else { return }
        let reportable = BreakdownExtractor.extractReportableSegmentInfo(xbrlDir: dir)
        let denom = BreakdownFinancialsResolver.breakdownBusinessSalesDenominatorItem(
            xbrlDir: dir, tables: reportable.tables)
        let segment = await SegmentBreakdownResolver.resolve(
            reportable: reportable, consolidatedSales: denom.value,
            labelsByTag: XBRLUtils.loadLabelsByTag(in: dir), denominatorTag: denom.tag,
            columnDecider: FakeRevenueRecognitionColumnDecider(selected: column),
            fiscalYearEnd: BreakdownExtractor.currentFiscalYearEnd(fromXbrlDir: dir), docID: docID,
            xbrlDir: dir)
        let segmentRows = segment.snapshot?.rows.filter { $0.rowKind == "segment" } ?? []
        #expect(segmentRows.count <= 1, "\(docID): segment rows \(segmentRows.map { $0.label ?? $0.labelRaw })")
        for (label, _) in products where label != "その他" {
            #expect(!segmentRows.contains { ($0.label ?? $0.labelRaw) == label })
        }

        let product = await ProductServiceBreakdownResolver.resolve(
            product: BreakdownExtractor.extractProductServiceInfo(xbrlDir: dir),
            consolidatedSales: denom.value, denominatorTag: denom.tag,
            columnDecider: FakeRevenueRecognitionColumnDecider(selected: column),
            fiscalYearEnd: BreakdownExtractor.currentFiscalYearEnd(fromXbrlDir: dir), docID: docID)
        let snapshot = try #require(product.snapshot, "\(docID): product_service snapshot")
        for (label, amount) in products {
            let row = try #require(snapshot.rows.first { ($0.label ?? $0.labelRaw) == label })
            #expect(row.amount == amount * unit)
        }
    }

    // 事業収益が無い年の単一セグメント会社（4599 ステムリム、個別のみ・7月決算）。セグメント注記は
    // 「再生誘導医薬事業の単一セグメントであるため、記載を省略」で、PL の事業収益は「−」。
    // 売上が無くても segment 軸は404 にせず、金額 0 の1行で返す。FY2023（S100S2RX）は事業収益 2,350,000 千円。
    // source: code=4599 fy_end=2026-07-31 doc_id=S100ZA4E page=100 field=segment.再生誘導医薬事業
    // source: code=4599 fy_end=2025-07-31 doc_id=S100WW19 page=97 field=segment.再生誘導医薬事業
    // source: code=4599 fy_end=2023-07-31 doc_id=S100S2RX page=0 field=segment.再生誘導医薬事業
    @Test(arguments: [
        ("S100ZA4E", 0.0),
        ("S100WW19", 0.0),
        ("S100S2RX", 2_350_000_000.0),
    ])
    func singleSegmentWithoutRevenueKeepsOneRow(docID: String, amount: Double) async throws {
        guard let dir = await Self.ensureAvailable(docID) else { return }
        let reportable = BreakdownExtractor.extractReportableSegmentInfo(xbrlDir: dir)
        let financials = StatementFinancialsResolver.resolve(xbrlDir: dir)
        let members = SegmentBreakdownResolver.currentSegmentMembers(in: reportable.facts)
        let dedicated = BreakdownExtractor.dedicatedSingleSegmentDisclosureTexts(xbrlDir: dir)
        let pattern = await SegmentNotePatternClassifier.classify(
            axis: .segment,
            signals: SegmentNotePatternSignals(
                reportableMemberCount: members.count,
                hasDedicatedSingleSegmentTag: dedicated.currentYear != nil,
                hasReportableSegmentTable: !reportable.tables.isEmpty,
                hasRelatedInfoTable: false,
                prose: BreakdownExtractor.segmentNotePatternProse(xbrlDir: dir)),
            docID: docID, decider: nil)
        #expect(pattern.classification == .singleSegment)
        let (segment, _, _) = await SegmentBreakdownResolver.resolve(
            reportable: reportable,
            consolidatedSales: financials?.geographyCoverageSales ?? financials?.sales,
            labelsByTag: XBRLUtils.loadLabelsByTag(in: dir), docID: docID, xbrlDir: dir,
            pattern: pattern)
        let snapshot = try #require(segment, "\(docID): segment snapshot")
        #expect(snapshot.denominator == amount)
        let rows = snapshot.rows.filter { $0.rowKind == "segment" }
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect((row.label ?? row.labelRaw) == "再生誘導医薬事業")
        #expect(row.amount == amount)
        #expect(row.share == (amount == 0 ? nil : 1))
    }
}
