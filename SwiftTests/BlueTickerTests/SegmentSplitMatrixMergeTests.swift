import Testing

@testable import BlueTickerCore

/// 事業ごとに表が分かれ、後ろの表だけが全社の合計列を持つセグメント注記（8230 / 6272 / 7442）。
struct SegmentSplitMatrixMergeTests {
    private func table(_ rows: [[String]], period: String) -> BreakdownTable {
        BreakdownTable(
            heading: "セグメント情報", markdown: BreakdownExtractor.gridToMarkdown(rows), period: period)
    }

    private let dataRows: [[String]] = [
        ["売上高", "", "", ""],
        ["外部顧客への売上高", "100", "200", "300"],
        ["セグメント間の内部売上高又は振替高", "1", "2", "3"],
        ["計", "101", "202", "303"],
        ["セグメント利益", "10", "20", "30"],
    ]

    /// 左は見出し 3 段・右は 2 段。左の事業内小計「計」は合計列ではない。
    @Test func headersOfDifferentHeightAreAlignedAtTheBottom() throws {
        let left: [[String]] = [
            ["", "報告セグメント", "報告セグメント", "報告セグメント"],
            ["", "仏壇", "仏壇", "仏壇"],
            ["", "東日本", "西日本", "計"],
        ] + dataRows.map { $0 }
        let right: [[String]] = [
            ["", "その他", "調整額", "連結財務諸表計上額"],
        ] + dataRows.map { $0 }
        let joined = try #require(
            SegmentInfoLLMNormalizer.joinedSplitMatrix(
                left.map { $0 + [] }, right.map { $0 + [] }))
        // 見出し 3 段 + データ 5 行。連結列が最後に付く。
        #expect(joined.count == 8)
        #expect(joined[2] == ["", "東日本", "西日本", "計", "その他", "調整額", "連結財務諸表計上額"])
        #expect(joined.allSatisfy { $0.count == 7 })
    }

    /// 前期の表が左右に分かれ、右の期間ラベルが当期と誤って付いても、続く当期の 2 表も
    /// 同じ形なら、前期同士・当期同士で連結する。
    @Test func mislabeledPriorPairIsMergedWhenCurrentPairLooksTheSame() {
        let leftRows: [[String]] = [["", "卸売", "卸売"], ["", "北海道", "計"]] + dataRows.map { Array($0.prefix(3)) }
        let rightRows: [[String]] = [["", "製造", "連結"], ["", "計", "連結"]] + dataRows.map { Array($0.prefix(3)) }
        let tables = [
            table(leftRows, period: "前期"), table(rightRows, period: "当期"),
            table(leftRows, period: "当期"), table(rightRows, period: "当期"),
        ]
        let merged = SegmentInfoLLMNormalizer.mergingSplitSegmentMatrices(tables)
        #expect(merged.map(\.period) == ["前期", "当期", "当期", "当期"])
        #expect(merged[1].markdown.isEmpty)
        #expect(merged[3].markdown.isEmpty)
        #expect(!merged[0].markdown.isEmpty)
        #expect(!merged[2].markdown.isEmpty)
    }

    /// 前期→当期の 2 表だけ（続きが無い）のときは、期間が違う表を連結しない。
    @Test func priorAndCurrentTablesAreNotMergedWithoutAFollowingPair() {
        let leftRows: [[String]] = [["", "卸売", "卸売"], ["", "北海道", "計"]] + dataRows.map { Array($0.prefix(3)) }
        let rightRows: [[String]] = [["", "製造", "連結"], ["", "計", "連結"]] + dataRows.map { Array($0.prefix(3)) }
        let tables = [table(leftRows, period: "前期"), table(rightRows, period: "当期")]
        let merged = SegmentInfoLLMNormalizer.mergingSplitSegmentMatrices(tables)
        #expect(merged.allSatisfy { !$0.markdown.isEmpty })
    }

    /// 7745 S100YHHI: 事業ごとに 3 つの表に分かれ、最後の表だけが調整・連結の列を持つ。
    /// 期間の付き方（前期・当期の混在）にかかわらず、左から連結して 3 事業が揃う。
    @Test func threeWaySplitIsJoinedLeftToRight() {
        let body: [[String]] = [
            ["売上高", "", "", ""],
            ["外部顧客への売上高", "100", "200", "300"],
            ["セグメント間の内部売上高又は振替高", "1", "2", "3"],
            ["計", "101", "202", "303"],
            ["セグメント利益", "10", "20", "30"],
        ]
        func block(_ name: String, total: [String]? = nil) -> [[String]] {
            let head: [[String]] = [
                ["", name, name, name] + (total != nil ? ["調整額（注１）", "連結財務諸表計上額（注２）"] : []),
                ["", "日本", "米州", "計"] + (total != nil ? ["調整額（注１）", "連結財務諸表計上額（注２）"] : []),
            ]
            let rows = body.map { row in row + (total != nil ? (row[1] == "" ? ["", ""] : total!) : []) }
            return head + rows
        }
        let tables = [
            table(block("半導体関連事業"), period: "前期"),
            table(block("計測・計量機器事業"), period: "当期"),
            table(block("医療・健康機器事業", total: ["－", "500"]), period: "当期"),
        ]
        let merged = SegmentInfoLLMNormalizer.mergingSplitSegmentMatrices(tables)
        let grid = BreakdownExtractor.markdownToGrid(merged[0].markdown)
        #expect(merged[1].markdown.isEmpty && merged[2].markdown.isEmpty)
        #expect(grid[0].contains("半導体関連事業"))
        #expect(grid[0].contains("計測・計量機器事業"))
        #expect(grid[0].contains("医療・健康機器事業"))
        #expect(grid[1].last == "連結財務諸表計上額（注２）")
    }
}
