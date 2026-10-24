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

    @Test func tableInsideALabelCellDoesNotCutTheOuterTable() {
        let nested = html([
            ("<table><tr><td><p>Ａ事業</p></td></tr></table>", "60", true), ("Ｂ事業", "40", true),
            ("純粋持株会社等", "7", false), ("合計", "107", false),
        ])
        let tables = EmployeesUntaggedRowFill.parseTables(
            html: nested, tag: "NumberOfEmployees", anchorRefs: ["Cur_SegA"])
        #expect(tables.count == 1)
        #expect(tables.first?.rows.first?.label == "Ａ事業")
        let base = snapshot(rows: [("AMember", 60, "segment"), ("BMember", 40, "segment")], denominator: 107)
        let filled = EmployeesUntaggedRowFill.apply(snapshot: base, tables: tables)
        #expect(filled.rows.last?.label == "純粋持株会社等")
        #expect(filled.rows.last?.amount == 7)
    }

    @Test func tableWrappedInALayoutTableIsReadAsTheInnerTable() {
        let inner = html([
            ("Ａ事業", "60", true), ("Ｂ事業", "40", true), ("純粋持株会社等", "7", false), ("合計", "107", false),
        ])
        let tables = EmployeesUntaggedRowFill.parseTables(
            html: "<table><tr><td>\(inner)</td></tr></table>", tag: "NumberOfEmployees", anchorRefs: ["Cur_SegA"])
        #expect(tables.count == 1)
        #expect(tables.first?.rows.map(\.label) == ["Ａ事業", "Ｂ事業", "純粋持株会社等", "合計"])
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

    private func totalCell(_ amount: String) -> String {
        "<td><ix:nonFraction contextRef=\"CurrentYearInstant\" decimals=\"0\" name=\"jpcrp_cor:NumberOfEmployees\" unitRef=\"pure\">\(amount)</ix:nonFraction></td>"
    }

    @Test func totalOnlyHorizontalSegmentTableBecomesRows() {
        let html = """
            <table><tr><td>セグメントの名称</td><td>銀行業務</td><td>その他事業</td><td>合計</td></tr>
            <tr><td>従業員数(人)</td><td>6,895</td><td>1,155</td>\(totalCell("8,050"))</tr>
            <tr><td></td><td>[2,538]</td><td>[336]</td><td>[2,874]</td></tr></table>
            """
        let tables = EmployeesUntaggedRowFill.totalOnlyTables(html: html, tag: "NumberOfEmployees", total: 8_050)
        #expect(tables.first?.header == "セグメントの名称")
        let rows = tables.first?.rows
        let expected: [EmployeesUntaggedRowFill.TableRow] = [
            .init(label: "銀行業務", amount: 6_895, tagged: false),
            .init(label: "その他事業", amount: 1_155, tagged: false),
        ]
        #expect(rows == expected)
    }

    @Test func totalOnlyVerticalSegmentTableBecomesRows() {
        let html = """
            <table><tr><td>セグメントの名称</td><td>従業員数(人)</td></tr>
            <tr><td>Ａ事業</td><td>60</td></tr><tr><td>全社（共通）</td><td>7</td></tr>
            <tr><td>合計</td>\(totalCell("67"))</tr></table>
            """
        let tables = EmployeesUntaggedRowFill.totalOnlyTables(html: html, tag: "NumberOfEmployees", total: 67)
        #expect(tables.first?.rows.map(\.label) == ["Ａ事業", "全社（共通）"])
    }

    /// 部門別の表も構造上は候補になる。セグメント別かは見出しの語ではなく Jev が判定する。
    @Test func totalOnlyDepartmentTableIsACandidateForJev() {
        let html = """
            <table><tr><td>部門の名称</td><td>従業員数(人)</td></tr>
            <tr><td>営業部門</td><td>60</td></tr><tr><td>管理部門</td><td>7</td></tr>
            <tr><td>合計</td>\(totalCell("67"))</tr></table>
            """
        let tables = EmployeesUntaggedRowFill.totalOnlyTables(html: html, tag: "NumberOfEmployees", total: 67)
        #expect(tables.first?.header == "部門の名称")
        #expect(tables.first?.rows.count == 2)
    }

    /// 5985 サンコール S100LIN3 型: 製品区分の列がセグメント列の前にある。行は製品区分なので読まない。
    @Test func totalOnlyTableWithProductColumnBeforeSegmentColumnIsIgnored() {
        let html = """
            <table><tr><td>製品区分の名称</td><td>セグメントの名称</td><td>従業員数(人)</td></tr>
            <tr><td>材料関連製品</td><td>日本</td><td>60</td></tr>
            <tr><td>自動車関連製品</td><td>北米</td><td>7</td></tr>
            <tr><td>合計</td><td></td>\(totalCell("67"))</tr></table>
            """
        #expect(EmployeesUntaggedRowFill.totalOnlyTables(html: html, tag: "NumberOfEmployees", total: 67).isEmpty)
    }

    @Test func totalOnlyHorizontalTableWithSpannedHeaderIsIgnored() {
        let html = """
            <table><tr><td>セグメントの名称</td><td colspan="2">銀行業務</td><td>合計</td></tr>
            <tr><td>従業員数(人)</td><td>6,895</td><td>1,155</td>\(totalCell("8,050"))</tr></table>
            """
        #expect(EmployeesUntaggedRowFill.totalOnlyTables(html: html, tag: "NumberOfEmployees", total: 8_050).isEmpty)
    }

    @Test func totalOnlyTableWhoseCellsDoNotSumToTotalIsIgnored() {
        let html = """
            <table><tr><td>セグメントの名称</td><td>Ａ事業</td><td>Ｂ事業</td><td>合計</td></tr>
            <tr><td>従業員数(人)</td><td>60</td><td>5</td>\(totalCell("67"))</tr></table>
            """
        #expect(EmployeesUntaggedRowFill.totalOnlyTables(html: html, tag: "NumberOfEmployees", total: 67).isEmpty)
    }

    @Test func rowsMustOverlapSegmentNamesWhenTheNoteHasThem() {
        let rows: [EmployeesUntaggedRowFill.TableRow] = [
            .init(label: "銀行業務", amount: 6_895, tagged: false),
            .init(label: "その他事業", amount: 1_155, tagged: false),
        ]
        #expect(EmployeesUntaggedRowFill.rowsOverlapSegmentLabels(rows, ["銀行業務"]))
        #expect(!EmployeesUntaggedRowFill.rowsOverlapSegmentLabels(rows, ["自動車", "金融"]))
    }

    /// 2 セグメント共通の人数が縦結合セル1つに載り、下の行がラベルだけの表。
    /// 結合した2行を1行（ラベルは「・」でつなぐ）として差額に足す。
    // source: code=4263 fy_end=2026-06-30 doc_id=S100Z4GF page=78 field=employees.DTxプロダクト事業・DTxプラットフォーム事業
    @Test func joinsLabelsOfRowsSharingAVerticallyMergedCountCell() {
        let html = """
            <table><tr><td>報告セグメントの名称</td><td>従業員数（名）</td></tr>
            <tr><td><p>DTxプロダクト事業</p></td><td rowspan="2"><p>35</p></td></tr>
            <tr><td><p>DTxプラットフォーム事業</p></td></tr>
            <tr><td><p>全社（共通）</p></td>\(cell("15", tagged: true, ref: "Cur_Corporate"))</tr>
            <tr><td><p>合計</p></td><td><p>50</p></td></tr></table>
            """
        let tables = EmployeesUntaggedRowFill.parseTables(
            html: html, tag: "NumberOfEmployees", anchorRefs: ["Cur_Corporate"])
        let base = snapshot(rows: [("CorporateSharedMember", 15, "reconciling")], denominator: 50)
        let filled = EmployeesUntaggedRowFill.apply(snapshot: base, tables: tables)
        let added = filled.rows.last
        #expect(added?.label == "DTxプロダクト事業・DTxプラットフォーム事業")
        #expect(added?.amount == 35)
        #expect(added?.rowKind == "segment")
        #expect(filled.rows.map(\.amount).reduce(0, +) == 50)
    }
}
