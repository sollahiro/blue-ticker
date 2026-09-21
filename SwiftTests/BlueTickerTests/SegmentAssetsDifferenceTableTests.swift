import Foundation
import Testing
@testable import BlueTickerCore

/// 差額表 HTML パーサの L0（実 EDINET 抜粋・キャッシュ不要）。
@Suite struct SegmentAssetsDifferenceTableTests {

    private static let textBlockOpen =
        "<div><table><tbody>"
    private static let textBlockClose = "</tbody></table></div>"

    private func writeFixtureHtml(_ tableBody: String, unitCaption: String? = "（単位：百万円）") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("segment-assets-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let publicDoc = dir.appendingPathComponent("XBRL/PublicDoc", isDirectory: true)
        try FileManager.default.createDirectory(at: publicDoc, withIntermediateDirectories: true)
        let xbrl = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrl xmlns:jpcrp_cor="http://example.com">
        <jpcrp_cor:DescriptionOfNatureAndAmountsOfDifferencesBetweenReportableSegmentsTotalAndFinancialStatementsTextBlock contextRef="CurrentYearDuration">
        \(unitCaption.map { "<p>\($0)</p>" } ?? "")
        \(tableBody)
        </jpcrp_cor:DescriptionOfNatureAndAmountsOfDifferencesBetweenReportableSegmentsTotalAndFinancialStatementsTextBlock>
        </xbrl>
        """
        try xbrl.write(to: publicDoc.appendingPathComponent("fixture.xbrl"), atomically: true, encoding: .utf8)
        return dir
    }

    /// ミニストップ S100Y4UH 型（当連結列）。
    @Test func parsesCurrentColumnMillionYen() throws {
        let body = """
        <table><tr><td></td><td></td><td>(単位：百万円)</td></tr>
        <tr><td>資産</td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
        <tr><td>報告セグメント計</td><td>50,686</td><td>45,703</td></tr>
        <tr><td>全社資産（注）</td><td>24,000</td><td>23,310</td></tr>
        <tr><td>連結財務諸表の資産合計</td><td>74,686</td><td>69,013</td></tr>
        </table>
        """
        let dir = try writeFixtureHtml(body)
        let rows = SegmentAssetsDifferenceTable.parseReconcilingAmountsYen(in: dir)
        #expect(rows.count == 1)
        #expect(rows[0].label.contains("全社資産"))
        #expect(rows[0].amountYen == 23_310_000_000)
    }

    /// 千円のみの表は採用しない。
    @Test func refusesThousandYenUnit() throws {
        let body = """
        <table><tr><td>資産</td><td>（千円）</td></tr>
        <tr><td>全社資産</td><td>12,000</td></tr>
        </table>
        """
        let dir = try writeFixtureHtml(body, unitCaption: nil)
        #expect(SegmentAssetsDifferenceTable.parseReconcilingAmountsYen(in: dir).isEmpty)
    }

    /// 二つの資産表があるとき後段（当連結見出し）を採用。
    @Test func prefersLaterAssetsTableWithCurrentHeading() throws {
        let body = """
        <table><tr><td>資産</td><td>前連結会計年度（百万円）</td></tr>
        <tr><td>全社資産</td><td>10</td></tr></table>
        <table><tr><td>資産</td><td>当連結会計年度（百万円）</td></tr>
        <tr><td>全社資産</td><td>25</td></tr></table>
        """
        let dir = try writeFixtureHtml(body)
        let rows = SegmentAssetsDifferenceTable.parseReconcilingAmountsYen(in: dir)
        #expect(rows.count == 1)
        #expect(rows[0].amountYen == 25_000_000)
    }

    @Test func enrichSkipsWhenXbrlReconcilingAlreadyPresent() throws {
        let facts = [
            BreakdownFact(
                tag: "Assets", contextRef: "CurrentYearInstant_SegmentAMember",
                dimensions: ["OperatingSegmentsAxis": "SegmentAMember"],
                value: 80, label: nil, unitRef: "JPY", decimals: "0"),
            BreakdownFact(
                tag: "Assets", contextRef: "CurrentYearInstant_ReconcilingItemsMember",
                dimensions: ["OperatingSegmentsAxis": "ReconcilingItemsMember"],
                value: 20, label: nil, unitRef: "JPY", decimals: "0"),
            BreakdownFact(
                tag: "Assets", contextRef: "CurrentYearInstant",
                dimensions: [:], value: 100, label: nil, unitRef: "JPY", decimals: "0"),
        ]
        let base = try #require(BreakdownNormalizer.normalizeSegmentAssets(facts: facts))
        let body = """
        <table><tr><td>資産</td><td>当連結会計年度（百万円）</td></tr>
        <tr><td>全社資産</td><td>25</td></tr></table>
        """
        let dir = try writeFixtureHtml(body)
        let enriched = BreakdownNormalizer.enrichSegmentAssetsWithDifferenceTable(
            snapshot: base, xbrlDir: dir)
        #expect(enriched?.rows.count == base.rows.count)
    }
}
