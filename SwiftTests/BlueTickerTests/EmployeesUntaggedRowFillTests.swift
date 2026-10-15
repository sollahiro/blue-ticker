// 従業員数内訳: fact の付かない表行を差額と整数一致するときだけ reconciling 行にする（純関数＋HTML 解析）。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct EmployeesUntaggedRowFillTests {
    private func snapshot(rows: [(String, Double, String)], denominator: Double) -> BreakdownSnapshot {
        BreakdownSnapshot(
            axis: "employees", denominator: denominator, denominatorTag: "NumberOfEmployees",
            rows: rows.map {
                BreakdownRow(
                    labelRaw: $0.0, label: nil, amount: $0.1, share: $0.1 / denominator,
                    profit: nil, rowKind: $0.2)
            },
            sourceKind: "xbrl_facts", needsReview: false, warnings: [])
    }

    private func cell(_ amount: String, tagged: Bool, ref: String = "Cur_SegA") -> String {
        let body = tagged
            ? "<ix:nonFraction contextRef=\"\(ref)\" decimals=\"0\" name=\"jpcrp_cor:NumberOfEmployees\" unitRef=\"pure\">\(amount)</ix:nonFraction>"
            : amount
        return "<td><p>\(body)</p></td>"
    }

    private func html(_ rows: [(String, String, Bool)]) -> String {
        let trs = rows.map { "<tr><td><p>\($0.0)</p></td>\(cell($0.1, tagged: $0.2))<td>&#160;</td></tr>" }
        return "<table><tr><td>セグメントの名称</td><td>従業員数（人）</td></tr>\(trs.joined())</table>"
    }

    @Test func addsUntaggedRowThatExactlyFillsTheGap() {
        let tables = EmployeesUntaggedRowFill.parseTables(
            html: html([
                ("Ａ事業", "60", true), ("Ｂ事業", "40", true),
                ("純粋持株会社等", "7", false), ("合計", "107", false),
            ]),
            tag: "NumberOfEmployees", anchorRefs: ["Cur_SegA"])
        let base = snapshot(rows: [("AMember", 60, "segment"), ("BMember", 40, "segment")], denominator: 107)
        let filled = EmployeesUntaggedRowFill.apply(snapshot: base, tables: tables)
        #expect(filled.rows.count == 3)
        let added = filled.rows.last
        #expect(added?.label == "純粋持株会社等")
        #expect(added?.amount == 7)
        #expect(added?.rowKind == "reconciling")
        #expect(filled.rows.map(\.amount).reduce(0, +) == 107)
    }

    @Test func doesNothingWhenUntaggedRowsDoNotMatchTheGap() {
        let tables = EmployeesUntaggedRowFill.parseTables(
            html: html([("Ａ事業", "60", true), ("本社", "5", false), ("合計", "107", false)]),
            tag: "NumberOfEmployees", anchorRefs: ["Cur_SegA"])
        let base = snapshot(rows: [("AMember", 60, "segment")], denominator: 107)
        #expect(EmployeesUntaggedRowFill.apply(snapshot: base, tables: tables) == base)
    }

    @Test func ignoresTablesWithoutSegmentTaggedFacts() {
        let tables = EmployeesUntaggedRowFill.parseTables(
            html: html([("Ａ事業", "60", true), ("本社", "7", false)]),
            tag: "NumberOfEmployees", anchorRefs: ["SomeOtherContext"])
        #expect(tables.isEmpty)
    }

    @Test func doesNothingWhenRowsAlreadyCoverTheDenominator() {
        let tables = EmployeesUntaggedRowFill.parseTables(
            html: html([("Ａ事業", "60", true), ("全社（共通）", "7", false)]),
            tag: "NumberOfEmployees", anchorRefs: ["Cur_SegA"])
        let base = snapshot(rows: [("AMember", 60, "segment"), ("CorporateSharedMember", 7, "reconciling")], denominator: 67)
        #expect(EmployeesUntaggedRowFill.apply(snapshot: base, tables: tables) == base)
    }

    @Test func doesNotDuplicateARowAlreadyPresentUnderItsLabel() {
        let tables = EmployeesUntaggedRowFill.parseTables(
            html: html([("Ａ事業", "60", true), ("Ｂ事業", "7", false)]),
            tag: "NumberOfEmployees", anchorRefs: ["Cur_SegA"])
        var base = snapshot(rows: [("AMember", 60, "segment")], denominator: 67)
        base.rows[0].label = "Ｂ事業"
        #expect(EmployeesUntaggedRowFill.apply(snapshot: base, tables: tables) == base)
    }

    @Test func classifiesBusinessRowsAsSegmentAndClearsFarFromTotalWarning() {
        let tables = EmployeesUntaggedRowFill.parseTables(
            html: html([("Ａ事業", "10", true), ("Ｂ事業", "90", false), ("合計", "100", false)]),
            tag: "NumberOfEmployees", anchorRefs: ["Cur_SegA"])
        var base = snapshot(rows: [("AMember", 10, "segment")], denominator: 100)
        base.warnings = ["employees_segment_sum_far_from_total"]
        base.needsReview = true
        let filled = EmployeesUntaggedRowFill.apply(snapshot: base, tables: tables)
        #expect(filled.rows.last?.rowKind == "segment")
        #expect(filled.rows.last?.amount == 90)
        #expect(filled.warnings.isEmpty)
        #expect(filled.needsReview == false)
    }
}
