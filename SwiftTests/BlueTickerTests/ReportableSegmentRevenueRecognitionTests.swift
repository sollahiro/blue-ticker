// 報告セグメント facts と収益認識表が同じ内訳のときの採否。差額埋めはしない。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct ReportableSegmentRevenueRecognitionTests {
    private let yen = Financial.millionYen

    @Test func preferFactsWhenNamesAndAmountsMatch() throws {
        let facts = geographyFacts()
        let rr = BreakdownSnapshot(
            axis: breakdownAxisProductService,
            denominator: 3_234 * yen,
            denominatorTag: "llm_table_subtotal",
            rows: [
                row("日本・東アジア", 1_234 * yen, profit: nil),
                row("欧州", 2_000 * yen, profit: nil),
            ],
            sourceKind: "revenue_recognition", needsReview: false, warnings: []
        )
        let preferred = try #require(
            ReportableSegmentRevenueRecognition.preferFactsIfSameBreakdown(facts: facts, rr: rr))
        #expect(preferred.axis == breakdownAxisProductService)
        #expect(preferred.sourceKind == "xbrl_facts")
        #expect(preferred.rows.contains { $0.label == "日本・東アジア" && $0.profit == 62_584 * yen })
        #expect(preferred.rows.contains { $0.rowKind == "reconciling" && $0.profit == -23_592 * yen })
    }

    @Test func keepRevenueRecognitionWhenProductRowsDiffer() {
        let facts = geographyFacts()
        let rr = BreakdownSnapshot(
            axis: breakdownAxisProductService,
            denominator: 3_234 * yen,
            denominatorTag: "llm_table_subtotal",
            rows: [
                row("酒類", 1_234 * yen, profit: nil),
                row("飲料", 2_000 * yen, profit: nil),
            ],
            sourceKind: "revenue_recognition", needsReview: false, warnings: []
        )
        #expect(
            ReportableSegmentRevenueRecognition.preferFactsIfSameBreakdown(facts: facts, rr: rr)
                == nil)
    }

    @Test func rejectWhenAmountsDoNotMatchDisclosedCells() {
        let facts = geographyFacts()
        let rr = BreakdownSnapshot(
            axis: breakdownAxisProductService,
            denominator: 3_000 * yen,
            denominatorTag: "llm_table_subtotal",
            rows: [
                row("日本・東アジア", 1_000 * yen, profit: nil),
                row("欧州", 2_000 * yen, profit: nil),
            ],
            sourceKind: "revenue_recognition", needsReview: false, warnings: []
        )
        #expect(
            ReportableSegmentRevenueRecognition.preferFactsIfSameBreakdown(facts: facts, rr: rr)
                == nil)
    }

    @Test func tablesMatchFactsOnDisclosedTotalColumn() {
        let table = BreakdownTable(
            heading: BreakdownExtractor.revenueRecognitionHeading,
            markdown: """
            | 区分 | 酒類 | 合計 |
            | 日本・東アジア | 800 | 1,234 |
            | 欧州 | 1,200 | 2,000 |
            | 合計 | 2,000 | 3,234 |
            """,
            period: "当期",
            unitCaption: "百万円"
        )
        #expect(
            ReportableSegmentRevenueRecognition.tablesMatchFacts([table], facts: geographyFacts()))
    }

    @Test func tablesDoNotMatchWhenRowLabelsAreProducts() {
        let table = BreakdownTable(
            heading: BreakdownExtractor.revenueRecognitionHeading,
            markdown: """
            | 区分 | 当期 |
            | 酒類 | 1,234 |
            | 飲料 | 2,000 |
            | 合計 | 3,234 |
            """,
            period: "当期",
            unitCaption: "百万円"
        )
        #expect(
            !ReportableSegmentRevenueRecognition.tablesMatchFacts([table], facts: geographyFacts()))
    }

    private func geographyFacts() -> BreakdownSnapshot {
        BreakdownSnapshot(
            axis: "geography",
            denominator: 3_234 * yen,
            denominatorTag: "SalesToExternalCustomersIFRS",
            rows: [
                row("日本・東アジア", 1_234 * yen, profit: 62_584 * yen, raw: "JapanEastAsiaReportableSegmentMember"),
                row("欧州", 2_000 * yen, profit: 79_386 * yen, raw: "EuropeReportableSegmentMember"),
                row("計", 3_234 * yen, profit: 209_463 * yen, raw: "ReportableSegmentsMember", kind: "subtotal"),
                row("調整額", -100 * yen, profit: -23_592 * yen, raw: "ReconcilingItemsMember", kind: "reconciling"),
                row("連結", 3_134 * yen, profit: 185_870 * yen, raw: Xbrl.entityTotalMemberName, kind: "EntityTotal"),
            ],
            sourceKind: "xbrl_facts", needsReview: false, warnings: []
        )
    }

    private func row(
        _ label: String, _ amount: Double, profit: Double?, raw: String? = nil,
        kind: String = "segment"
    ) -> BreakdownRow {
        BreakdownRow(
            labelRaw: raw ?? label, label: label, amount: amount, share: nil, profit: profit,
            rowKind: kind)
    }
}
