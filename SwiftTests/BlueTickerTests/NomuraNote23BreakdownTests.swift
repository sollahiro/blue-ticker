import Foundation
import Testing

@testable import BlueTickerCore

/// 野村 8604 S100YC5C（US-GAAP）注記23「セグメントおよび地域別情報」の実データ回帰。
/// 既定の見出しキーワードでは事業別の表が取れず（product_service 404）、地域別は散文の
/// 「地域別」一致で無関係な表が先頭に並んでいた。
@Suite struct NomuraNote23BreakdownTests {
    private static let docID = "S100YC5C"
    /// 損益計算書「収益合計」（総額、金融費用控除前）。本番 /financials sales と同じ。
    private static let incomeStatementSales = 4_758_486 * Financial.millionYen

    private func ensureCached() async -> URL? {
        let xbrlDir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(Self.docID)_xbrl")
        await SmokeCacheSupport.ensureCached([Self.docID])
        guard FileManager.default.fileExists(atPath: xbrlDir.path) else {
            print("SKIP   \(Self.docID): XBRL キャッシュなし")
            return nil
        }
        return xbrlDir
    }

    private func m(_ n: Int) -> Double { Double(n) * Financial.millionYen }

    @Test func productServiceGoldenFromNote23StackedSegmentTable() async throws {
        guard let xbrlDir = await ensureCached() else { return }
        let extracted = BreakdownExtractor.extractSegmentInfo(xbrlDir: xbrlDir)
        #expect(extracted.method == "html_table")
        #expect(extracted.tables.contains { $0.markdown.contains("ウェルス・マネジメント部門") })

        let snapshot = try #require(StackedSegmentPnLNormalizer.normalize(
            extracted, consolidatedSales: Self.incomeStatementSales))
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        #expect(segments.map(\.labelRaw) == [
            "ウェルス・マネジメント部門", "インベストメント・マネジメント部門", "ホールセール部門",
            "バンキング部門", "その他（消去分を含む）",
        ])
        #expect(segments.map(\.amount) == [
            m(487_906), m(258_516), m(1_162_229), m(53_918), m(196_873),
        ])
        #expect(segments.map(\.profit) == [
            m(204_024), m(88_297), m(200_567), m(14_016), m(24_646),
        ])
        #expect(snapshot.denominator == m(2_159_442))
        #expect(snapshot.rows.first { $0.rowKind == "subtotal" }?.amount == m(2_159_442))
        #expect(!snapshot.needsReview)
        #expect(isPubliclyServableBreakdown(
            source: breakdownSourceStackedSegmentPnL, needsReview: snapshot.needsReview,
            warnings: snapshot.warnings))
    }

    @Test func geographyPrefersBracketedNote23Heading() async throws {
        guard let xbrlDir = await ensureCached() else { return }
        let extracted = BreakdownExtractor.extractGeographyInfo(xbrlDir: xbrlDir)
        #expect(extracted.method == "html_table")
        let first = try #require(extracted.tables.first)
        #expect(first.markdown.contains("2,167,713"))
        #expect(first.markdown.contains("アジア・オセアニア"))
        // 散文の「地域別」一致で拾っていた無関係な表（耐用年数・国内/海外税引前利益）は入らない。
        #expect(!extracted.tables.contains { $0.markdown.contains("３年から50年") })
        #expect(!extracted.tables.contains { $0.markdown.contains("国 内") || $0.markdown.contains("国　内") })
        #expect(!extracted.tables.contains { $0.markdown.contains("ウェルス・マネジメント部門") })
    }

    @Test func geographyGoldenFromNote23Table() async throws {
        guard let xbrlDir = await ensureCached() else { return }
        var extracted = BreakdownExtractor.extractGeographyInfo(xbrlDir: xbrlDir)
        if !extracted.tables.isEmpty, extracted.tables[0].period == nil {
            extracted.tables[0].period = "当期"
        }
        let (snapshotOrNil, _) = await GeographyBreakdownLLMNormalizer.normalize(
            extracted,
            consolidatedSales: Self.incomeStatementSales,
            decider: FakeRevenueRecognitionColumnDecider(containing: "2026年"),
            fiscalYearEnd: "2026-03-31",
            docID: Self.docID,
            salesLabel: "収益合計")
        let snapshot = try #require(snapshotOrNil)
        let byLabel = Dictionary(
            snapshot.rows.filter { $0.rowKind == "segment" }.map { ($0.labelRaw, $0.amount) },
            uniquingKeysWith: { a, _ in a })
        #expect(byLabel == [
            "米州": m(669_998), "欧州": m(261_522), "アジア・オセアニア": m(148_415),
            "日本": m(1_087_778),
        ])
        #expect(snapshot.denominator == m(2_167_713))
        #expect(!snapshot.rows.contains { $0.amount == m(539_821) })
        #expect(!snapshot.needsReview)
        #expect(isPubliclyServableBreakdown(
            source: breakdownSourceGeographyLLM, needsReview: snapshot.needsReview,
            warnings: snapshot.warnings))
    }
}
