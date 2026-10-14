import Foundation
import Testing
@testable import BlueTickerCore

/// `BreakdownNormalizer.segmentProfitTag`: 会社がセグメント利益と定義した測度の行を選ぶ。
/// 実書類での値は `Spec/Oracle/RealXbrlSegmentProfitTests.swift`。
@Suite struct SegmentProfitTagSelectionTests {
    private func fact(_ tag: String, _ member: String, _ millions: Double) -> BreakdownFact {
        BreakdownFact(
            tag: tag, contextRef: "CurrentYearDuration_\(member)",
            dimensions: ["OperatingSegmentsAxis": member], value: millions * 1_000_000,
            label: nil, unitRef: "JPY", decimals: "-6")
    }

    private func facts(_ tag: String, _ values: [String: Double]) -> [BreakdownFact] {
        values.sorted { $0.key < $1.key }.map { fact(tag, $0.key, $0.value) }
    }

    @Test func rowLabelledSegmentProfitBeatsTagPriorityList() {
        // 東京海上型: 税引前利益（リスト上位）とセグメント利益行（親会社所有者帰属利益）の両方がある。
        let all = facts("InsuranceRevenueIFRS", ["AReportableSegmentMember": 3000, "BReportableSegmentMember": 300])
            + facts("ProfitLossBeforeTaxIFRS", ["AReportableSegmentMember": 325, "BReportableSegmentMember": -282])
            + facts("ProfitLossAttributableToOwnersOfParentIFRS", ["AReportableSegmentMember": 237, "BReportableSegmentMember": -204])
        let tag = BreakdownNormalizer.segmentProfitTag(
            facts: all, tables: [],
            rowLabelsByTag: [
                "ProfitLossBeforeTaxIFRS": ["税引前利益 (△は損失)"],
                "ProfitLossAttributableToOwnersOfParentIFRS": ["セグメント利益 (△は損失)（注）3"],
            ],
            amountTag: "InsuranceRevenueIFRS", fallbackTags: Xbrl.segmentProfitTags)
        #expect(tag == "ProfitLossAttributableToOwnersOfParentIFRS")
    }

    @Test func ordinaryIncomeBasisSegmentProfitIsSelected() {
        // 経常利益基準（大和証券・電力・地銀）: OrdinaryIncome はリストに無く従来は profit=null。
        let all = facts("RevenuesFromExternalCustomers", ["AReportableSegmentMember": 278, "BReportableSegmentMember": 134])
            + facts("OrdinaryIncome", ["AReportableSegmentMember": 112, "BReportableSegmentMember": 65])
        let tag = BreakdownNormalizer.segmentProfitTag(
            facts: all, tables: [],
            rowLabelsByTag: ["OrdinaryIncome": ["セグメント利益又はセグメント損失（△）（経常利益又は経常損失（△））"]],
            amountTag: "RevenuesFromExternalCustomers", fallbackTags: Xbrl.segmentProfitTags)
        #expect(tag == "OrdinaryIncome")
    }

    @Test func reconciliationStartSelectsCompanyMeasureWhenRowsAreNamedByMeasure() {
        // りそな型: 行名は「実質業務純益」「与信費用控除後業務純益(計)」で、本文が後者をセグメント利益と定義。
        // 差異調整表の利益の部「報告セグメント計」が後者の報告セグメント計と一致する。
        let all = facts("GrossOperatingProfit", ["AMember": 410, "ReportableSegmentsMember": 813])
            + facts("ActualNetOperatingProfit", ["AMember": 173, "ReportableSegmentsMember": 344])
            + facts("NetOperatingProfitLessCreditCost", ["AMember": 171, "ReportableSegmentsMember": 330])
        let grid = [
            ["利益", "前連結会計年度", "当連結会計年度"],
            ["報告セグメント計", "240", "330"],
            ["特別損益", "1", "△6"],
        ]
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: BreakdownExtractor.gridToMarkdown(grid), period: "当期")
        let tag = BreakdownNormalizer.segmentProfitTag(
            facts: all, tables: [table],
            rowLabelsByTag: [
                "ActualNetOperatingProfit": ["実質業務純益"],
                "NetOperatingProfitLessCreditCost": ["与信費用控除後業務純益(計)"],
            ],
            amountTag: "GrossOperatingProfit", fallbackTags: Xbrl.segmentBankNetOperatingProfitTags)
        #expect(tag == "NetOperatingProfitLessCreditCost")
    }

    @Test func salesReconciliationDoesNotPickProfitTag() {
        let all = facts("NetSales", ["AMember": 100, "ReportableSegmentsMember": 500])
            + facts("OperatingIncome", ["AMember": 10, "ReportableSegmentsMember": 50])
        let grid = [["売上高", "前連結会計年度", "当連結会計年度"], ["報告セグメント計", "450", "500"]]
        let table = BreakdownTable(
            heading: "セグメント情報", markdown: BreakdownExtractor.gridToMarkdown(grid), period: "当期")
        let tag = BreakdownNormalizer.segmentProfitTag(
            facts: all, tables: [table], rowLabelsByTag: [:], amountTag: "NetSales",
            fallbackTags: Xbrl.segmentProfitTags)
        #expect(tag == "OperatingIncome")  // 従来のリスト
    }

    @Test func noCompanyDefinitionKeepsTagPriorityList() {
        let all = facts("RevenuesFromExternalCustomers", ["AMember": 100])
            + facts("OperatingIncome", ["AMember": 10])
            + facts("OrdinaryIncome", ["AMember": 12])
        let tag = BreakdownNormalizer.segmentProfitTag(
            facts: all, tables: [], rowLabelsByTag: ["OperatingIncome": ["営業利益"]],
            amountTag: "RevenuesFromExternalCustomers", fallbackTags: Xbrl.segmentProfitTags)
        #expect(tag == "OperatingIncome")
    }

    @Test func adjustmentRowIsNotTheMeasure() {
        #expect(BreakdownNormalizer.isSegmentProfitRowLabel("セグメント利益"))
        #expect(BreakdownNormalizer.isSegmentProfitRowLabel("セグメント利益又は損失（△）"))
        #expect(BreakdownNormalizer.isSegmentProfitRowLabel("セグメント利益（事業利益）又は損失（△）"))
        #expect(BreakdownNormalizer.isSegmentProfitRowLabel("セグメント損益"))
        #expect(!BreakdownNormalizer.isSegmentProfitRowLabel("セグメント利益の調整額"))
        #expect(!BreakdownNormalizer.isSegmentProfitRowLabel("営業利益"))
    }

    @Test func parenthesizedBusinessProfitLabelBeatsOperatingIncomeList() {
        // 三井不動産型: 行名は「セグメント利益（事業利益）」、タグは会社拡張 BusinessIncome。
        // リスト上位の営業利益より、会社がセグメント利益と書いた行を採る。
        let all = facts("OperatingRevenue1", [
            "LeasingReportableSegmentsMember": 936_601, "SalesReportableSegmentsMember": 729_271,
        ])
            + facts("OperatingIncome", [
                "LeasingReportableSegmentsMember": 181_565, "SalesReportableSegmentsMember": 143_501,
            ])
            + facts("BusinessIncome", [
                "LeasingReportableSegmentsMember": 177_011, "SalesReportableSegmentsMember": 193_182,
            ])
        let tag = BreakdownNormalizer.segmentProfitTag(
            facts: all, tables: [],
            rowLabelsByTag: [
                "OperatingIncome": ["営業利益又は損失（△）"],
                "BusinessIncome": ["セグメント利益（事業利益）又は損失（△）"],
            ],
            amountTag: "OperatingRevenue1", fallbackTags: Xbrl.segmentProfitTags)
        #expect(tag == "BusinessIncome")
    }

    @Test func ixbrlFactLocalNameReadsHyphenatedCompanyExtensionPrefix() {
        #expect(
            StatementNotesResolver.ixbrlFactLocalName(
                fromAttributes: #"name="jpcrp030000-asr_E03855-000:BusinessIncome""#)
                == "BusinessIncome")
        #expect(
            StatementNotesResolver.ixbrlFactLocalName(
                fromAttributes: #"name="jppfs_cor:OperatingIncome""#)
                == "OperatingIncome")
        #expect(
            StatementNotesResolver.ixbrlFactLocalName(
                fromAttributes: #"name='OperatingIncome'"#)
                == "OperatingIncome")
        #expect(
            StatementNotesResolver.ixbrlFactLocalName(fromAttributes: #"contextRef="CurrentYearDuration""#)
                == nil)
    }
}
