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

    /// 千円の表も円に換算する（3300 型）。
    @Test func acceptsThousandYenUnit() throws {
        let body = """
        <table><tr><td>資産</td><td>（千円）</td></tr>
        <tr><td>全社資産</td><td>12,000</td></tr>
        </table>
        """
        let dir = try writeFixtureHtml(body, unitCaption: nil)
        let rows = SegmentAssetsDifferenceTable.parseReconcilingAmountsYen(in: dir)
        #expect(rows.count == 1)
        #expect(rows[0].amountYen == 12_000_000)
    }

    /// 増加額セクションの調整と計上額。資産の全社も同時に読む。
    @Test func parsesFlowIncreaseAndEntityTotalFromStackedTable() throws {
        let body = """
        <table>
        <tr><td></td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
        <tr><td>資産</td><td></td><td></td></tr>
        <tr><td>報告セグメント計</td><td>10,000</td><td>11,000</td></tr>
        <tr><td>全社資産</td><td>2,000</td><td>3,171,816</td></tr>
        <tr><td>連結財務諸表計上額</td><td>12,000</td><td>45,860,691</td></tr>
        <tr><td>増加額</td><td></td><td></td></tr>
        <tr><td>報告セグメント計</td><td>100</td><td>3,550,312</td></tr>
        <tr><td>調整額</td><td>10</td><td>48,984</td></tr>
        <tr><td>連結財務諸表計上額</td><td>110</td><td>3,599,296</td></tr>
        </table>
        """
        let dir = try writeFixtureHtml(body, unitCaption: "（単位：千円）")
        let parsed = SegmentAssetsDifferenceTable.parse(in: dir)
        #expect(parsed.assetReconciling.contains { $0.label.contains("全社") && $0.amountYen == 3_171_816_000 })
        #expect(parsed.assetEntityTotal == 45_860_691_000)
        #expect(parsed.flowReconciling.contains { $0.label.contains("調整") && $0.amountYen == 48_984_000 })
        #expect(parsed.flowEntityTotal == 3_599_296_000)
    }

    /// 3300 その他の項目: 列が 調整額 / 計上額、行が増加額。
    @Test func parsesWideIncreaseRowAdjustmentAndEntityTotal() throws {
        let body = """
        <table>
        <tr><td>その他の項目</td><td colspan="2">報告セグメント計</td>
        <td colspan="2">その他</td><td colspan="2">調整額</td>
        <td colspan="2">連結財務諸表計上額</td></tr>
        <tr><td></td><td>前連結</td><td>当連結</td><td>前連結</td><td>当連結</td>
        <td>前連結</td><td>当連結</td><td>前連結</td><td>当連結</td></tr>
        <tr><td>減価償却費</td><td>1</td><td>2</td><td>3</td><td>4</td>
        <td>5</td><td>6</td><td>7</td><td>8</td></tr>
        <tr><td>有形固定資産及び無形固定資産の増加額</td>
        <td>1,456,518</td><td>3,547,370</td><td>5,061</td><td>2,940</td>
        <td>3,724</td><td>48,984</td><td>1,465,304</td><td>3,599,296</td></tr>
        </table>
        """
        let dir = try writeFixtureHtml(body, unitCaption: "（単位：千円）")
        let parsed = SegmentAssetsDifferenceTable.parse(in: dir)
        #expect(parsed.flowReconciling.contains { $0.label.contains("調整") && $0.amountYen == 48_984_000 })
        #expect(parsed.flowEntityTotal == 3_599_296_000)
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

    /// アコム型: segment と同額の差額表行は reconciling に載せず、分母=EntityTotal。
    @Test func enrichDropsDifferenceRowMatchingSegmentAmount() throws {
        let otherMember = "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember"
        let facts = [
            BreakdownFact(
                tag: "Assets", contextRef: "CurrentYearInstant_SegmentAMember",
                dimensions: ["OperatingSegmentsAxis": "SegmentAMember"],
                value: 100_000_000, label: nil, unitRef: "JPY", decimals: "0"),
            BreakdownFact(
                tag: "Assets", contextRef: "CurrentYearInstant_OtherMember",
                dimensions: ["OperatingSegmentsAxis": otherMember],
                value: 40_000_000, label: nil, unitRef: "JPY", decimals: "0"),
            BreakdownFact(
                tag: "Assets", contextRef: "CurrentYearInstant",
                dimensions: [:], value: 200_000_000, label: nil, unitRef: "JPY", decimals: "0"),
        ]
        let base = try #require(BreakdownNormalizer.normalizeSegmentAssets(facts: facts))
        let body = """
        <table><tr><td>資産</td><td>当連結会計年度（百万円）</td></tr>
        <tr><td>その他の区分の資産</td><td>40</td></tr>
        <tr><td>本社資産</td><td>60</td></tr>
        </table>
        """
        let dir = try writeFixtureHtml(body)
        let enriched = try #require(
            BreakdownNormalizer.enrichSegmentAssetsWithDifferenceTable(snapshot: base, xbrlDir: dir))
        #expect(enriched.denominator == 200_000_000)
        #expect(!enriched.rows.contains {
            $0.rowKind == "reconciling" && ($0.label ?? "").contains("その他")
        })
        #expect(enriched.rows.contains { $0.rowKind == "reconciling" && ($0.label ?? "").contains("本社") })
        let reconciled = enriched.rows.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount).reduce(0, +)
        #expect(abs(reconciled - 200_000_000) <= 1)
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
