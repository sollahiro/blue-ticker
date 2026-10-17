import Testing
import Foundation
@testable import BlueTickerCore

/// 設備投資等の概要: 未タグ行の補完のゲート（倍率・和の一致・Jev の分類）。
@Suite struct CapexOverviewUntaggedRowFillTests {
    private static let tag = "CapitalExpendituresOverviewOfCapitalExpendituresEtc"

    private static func cell(_ ref: String, _ text: String) -> String {
        #"<td><ix:nonFraction name="jpcrp_cor:\#(tag)" contextRef="\#(ref)" scale="8">\#(text)</ix:nonFraction></td>"#
    }

    /// 億円表示。A / B はタグ付き、その他・全社は未タグ、合計はタグ付き。
    private static func html(otherDisplay: String = "30", totalCell: String? = nil) -> String {
        """
        <table>
        <tr><td>セグメントの名称</td><td>金額（億円）</td><td>主な内容</td></tr>
        <tr><td>A事業</td>\(cell("CurrentYearDuration_AMember", "100"))<td>工場</td></tr>
        <tr><td>B事業</td>\(cell("CurrentYearDuration_BMember", "70"))<td>設備</td></tr>
        <tr><td>その他・全社</td><td>\(otherDisplay)</td><td>本社</td></tr>
        <tr><td>合計</td>\(totalCell ?? cell("CurrentYearDuration", "200"))<td>─</td></tr>
        </table>
        """
    }

    private static let values: [String: Double] = [
        "CurrentYearDuration_AMember": 10_000_000_000,
        "CurrentYearDuration_BMember": 7_000_000_000,
        "CurrentYearDuration": 20_000_000_000,
    ]

    private static let base = BreakdownSnapshot(
        axis: breakdownAxisCapitalExpendituresOverview, denominator: 20_000_000_000,
        denominatorTag: tag,
        rows: [
            BreakdownRow(labelRaw: "AMember", label: "A事業", amount: 10_000_000_000, share: 0.5, profit: nil, rowKind: "segment"),
            BreakdownRow(labelRaw: "BMember", label: "B事業", amount: 7_000_000_000, share: 0.35, profit: nil, rowKind: "segment"),
            BreakdownRow(labelRaw: Xbrl.entityTotalMemberName, label: nil, amount: 20_000_000_000, share: 1, profit: nil, rowKind: "subtotal"),
        ],
        sourceKind: "xbrl_facts", needsReview: true,
        warnings: ["capital_expenditures_overview_segment_sum_far_from_total"])

    private static func table(_ html: String) -> CapexOverviewUntaggedRowFill.Table? {
        CapexOverviewUntaggedRowFill.parseTables(
            html: html, tag: tag, valuesByRef: values,
            anchorRefs: ["CurrentYearDuration_AMember", "CurrentYearDuration_BMember"]).first
    }

    @Test func untaggedRowMatchingResidualIsAddedWithJevRole() throws {
        let table = try #require(Self.table(Self.html()))
        #expect(table.yenPerDisplayUnit == 100_000_000)
        let rows = try #require(CapexOverviewUntaggedRowFill.candidates(snapshot: Self.base, table: table))
        #expect(rows.map(\.label) == ["その他・全社"])
        let filled = try #require(CapexOverviewUntaggedRowFill.apply(
            snapshot: Self.base, table: table, rows: rows,
            roles: ["その他・全社": CapexOverviewUntaggedRowFill.reconcilingKey]))
        let added = try #require(filled.rows.first { $0.labelRaw == "その他・全社" })
        #expect(added.amount == 3_000_000_000)
        #expect(added.rowKind == "reconciling")
        #expect(filled.needsReview == false)
        #expect(filled.warnings.isEmpty)

        #expect(CapexOverviewUntaggedRowFill.apply(
            snapshot: Self.base, table: table, rows: rows,
            roles: ["その他・全社": CapexOverviewUntaggedRowFill.totalKey]) == nil)
        #expect(CapexOverviewUntaggedRowFill.apply(
            snapshot: Self.base, table: table, rows: rows, roles: [:]) == nil)
    }

    /// 未タグ行の和が残差と合わないときは足さない（差額で埋めない）。
    @Test func residualMismatchAddsNothing() throws {
        let table = try #require(Self.table(Self.html(otherDisplay: "29")))
        #expect(CapexOverviewUntaggedRowFill.candidates(snapshot: Self.base, table: table) == nil)
    }

    /// タグ付きセルの倍率が揃わない表は読まない（固定倍率を仮定しない）。
    @Test func inconsistentScaleTableIsSkipped() {
        let html = Self.html(totalCell: Self.cell("CurrentYearDuration", "20,000"))
        #expect(Self.table(html) == nil)
    }

    @Test func noDeciderLeavesSnapshotUnchanged() async {
        let result = await CapexOverviewUntaggedRowFill.fill(
            snapshot: Self.base, facts: [], xbrlDir: URL(fileURLWithPath: "/nonexistent"),
            decider: nil, docID: "TEST")
        #expect(result.snapshot == Self.base)
        #expect(result.audit == nil)
    }
}
