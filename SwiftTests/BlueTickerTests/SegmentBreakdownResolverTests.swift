// 報告セグメント軸の正規化。synthetic 90%省略と従業員結合不可。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct SegmentBreakdownResolverTests {
    private static let yen = Financial.millionYen

    @Test func syntheticDominant90pctOneRowUsesConsolidatedSalesAndFlag() async throws {
        let prose =
            "【synthetic】食品事業の売上高、セグメント利益及びセグメント資産の金額がいずれも全セグメントの90%を超えるため、記載を省略しております。"
        let pattern = SegmentNotePatternOutcome(
            classification: .omittedDominant90pct, evidenceSentence: prose, needsReview: false,
            source: SegmentNotePatternClassifier.jevSource, audit: nil)
        let reportable = ExtractedBreakdown(method: "not_found", tables: [], facts: [])
        let amount = 12_345 * Self.yen
        let (snapshot, _, _) = await SegmentBreakdownResolver.resolve(
            reportable: reportable, consolidatedSales: amount, pattern: pattern)
        let snap = try #require(snapshot)
        #expect(snap.axis == breakdownAxisSegment)
        #expect(snap.disclosureBasis == breakdownDisclosureBasisDominant90pct)
        #expect(snap.rows.count == 1)
        #expect(snap.rows[0].label == "食品事業")
        #expect(snap.rows[0].amount == amount)
        #expect(snap.rows[0].rowKind == "segment")
        #expect(snap.rows[0].disclosureBasis == breakdownDisclosureBasisDominant90pct)
        #expect(snap.denominator == amount)
    }

    @Test func employeesJoinMarkedUnavailableWhenDepartmentsDoNotMatch() async throws {
        let pattern = SegmentNotePatternOutcome(
            classification: .singleSegment,
            evidenceSentence: "当社グループは医薬品事業の単一の事業セグメントから構成されております。",
            needsReview: false, source: SegmentNotePatternClassifier.deterministicSource, audit: nil)
        let reportable = ExtractedBreakdown(method: "not_found", tables: [], facts: [])
        let (snapshot, _, _) = await SegmentBreakdownResolver.resolve(
            reportable: reportable, consolidatedSales: 4_505_720 * Self.yen, pattern: pattern,
            employeeLabels: ["研究開発", "製造", "販売"])
        let snap = try #require(snapshot)
        #expect(snap.employeesJoin == breakdownEmployeesJoinUnavailable)
        #expect(snap.warnings.contains(breakdownWarningEmployeesJoinUnavailable))
        #expect(snap.rows[0].label == "医薬品事業")
    }

    @Test func relatedInfoSameAsStoresReferenceWithoutCopiedValues() {
        let snap = SegmentBreakdownResolver.sameAsSnapshot(axis: breakdownAxisGeography)
        #expect(snap.axis == breakdownAxisGeography)
        #expect(snap.sourceKind == breakdownSourceSameAs)
        #expect(snap.sameAs == breakdownAxisSegment)
        #expect(snap.rows.isEmpty)
        let payload = BreakdownSnapshotPayload(
            axis: snap.axis, denominator: snap.denominator, denominatorTag: snap.denominatorTag,
            rows: [], sourceKind: snap.sourceKind, needsReview: false, warnings: [],
            sameAs: snap.sameAs)
        #expect(payload.jsonObject()[breakdownSameAsKey] as? String == breakdownAxisSegment)
    }

    @Test func fujifilmStackedSegmentPnLResolvesOnSegmentAxis() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let path = root.appendingPathComponent("smoke/breakdown_extraction_expected.json")
        let data = try Data(contentsOf: path)
        let golden = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        let dict = try #require(golden["S100W3XJ"]?["segments"] as? [String: Any])
        let reportable = ExtractedBreakdown(dictionary: dict)
        let salesDir = root.appendingPathComponent("smoke/smoke_expected")
        let files = try FileManager.default.contentsOfDirectory(atPath: salesDir.path)
        let match = try #require(files.filter { $0.hasPrefix("4901_") }.sorted().first)
        let salesJSON = try JSONSerialization.jsonObject(
            with: Data(contentsOf: salesDir.appendingPathComponent(match))) as? [String: Any]
        let sales = try #require(
            (salesJSON?["income_statement"] as? [String: Any]).flatMap {
                ($0["sales"] as? NSNumber)?.doubleValue
            })
        let (snapshot, source, audit) = await SegmentBreakdownResolver.resolve(
            reportable: reportable, consolidatedSales: sales)
        #expect(source == .stackedSegmentPnL)
        #expect(audit == nil)
        let snap = try #require(snapshot)
        #expect(snap.axis == breakdownAxisSegment)
        let byLabel = Dictionary(
            uniqueKeysWithValues: snap.rows.filter { $0.rowKind == "segment" }.map {
                ($0.labelRaw, $0)
            })
        #expect(byLabel["ヘルスケア"]?.profit == 77_635 * Self.yen)
        #expect(byLabel["ヘルスケア"]?.profit != 60_698 * Self.yen)
    }

    @Test func geographyTablesDoNotBecomeSegmentSameAsWhenBothDisclosed() async {
        let geography = ExtractedBreakdown(
            method: "html_table",
            tables: [
                BreakdownTable(
                    heading: "地域ごとの情報",
                    markdown: """
                    | 区分 | 当期 |
                    | 日本 | 100 |
                    | 海外 | 50 |
                    | 合計 | 150 |
                    """,
                    period: "当期", unitCaption: "百万円")
            ],
            facts: [])
        #expect(geography.method == "html_table")
        #expect(!geography.tables.isEmpty)
        let sameAs = SegmentBreakdownResolver.sameAsSnapshot(axis: breakdownAxisGeography)
        #expect(sameAs.rows.isEmpty)
        #expect(geography.tables.isEmpty == false)
    }
}
