import Testing

@testable import BlueTickerCore

/// segment 軸は、報告セグメントごとの売上高・利益又は損失を持つ表だけを候補にする。
/// 4180 / 4565 / 4593: 主要な顧客・製品別の表をセグメントとして公開していた。
struct SegmentTablesRequireProfitTests {
    private func preferred(_ html: String) -> [RevenueRecognitionCandidates.ParsedTable] {
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
        let parsed = RevenueRecognitionCandidates.parse(tables: tables)
        return SegmentInfoLLMNormalizer.preferredTables(parsed, axis: breakdownAxisSegment)
    }

    @Test func majorCustomerTableIsNotASegmentTable() {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>Coupang, Inc.</td><td>10,605</td><td>13,168</td></tr>
              <tr><td>その他</td><td>23,452</td><td>30,569</td></tr>
            </table>
            """
        #expect(preferred(html).isEmpty)
    }

    @Test func impairmentOnlyTableIsNotASegmentTable() {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>食品製造販売事業</td><td>その他</td><td>合計</td></tr>
              <tr><td>減損損失</td><td>15</td><td>－</td><td>15</td></tr>
            </table>
            """
        #expect(preferred(html).isEmpty)
    }

    @Test func segmentMatrixWithProfitIsKept() {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>流通</td><td>運輸</td><td>合計</td></tr>
              <tr><td>外部顧客への営業収益</td><td>78,731</td><td>14,141</td><td>92,872</td></tr>
              <tr><td>営業利益</td><td>1,730</td><td>2,087</td><td>3,817</td></tr>
            </table>
            """
        #expect(preferred(html).count == 1)
    }

    @Test func profitMeasureLabelVariantsCountAsProfit() throws {
        func parsedTable(_ profitLabel: String) throws -> RevenueRecognitionCandidates.ParsedTable {
            let html = """
                <p>（単位：百万円）</p>
                <table>
                  <tr><td></td><td>流通</td><td>運輸</td><td>合計</td></tr>
                  <tr><td>外部顧客への売上高</td><td>1,988</td><td>186</td><td>2,174</td></tr>
                  <tr><td>\(profitLabel)</td><td>27</td><td>31</td><td>58</td></tr>
                </table>
                """
            let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
            return try #require(RevenueRecognitionCandidates.parse(tables: tables).first)
        }
        for label in ["営業利益", "セグメント利益又は損失（△）", "セグメント損益", "営業損益", "実質業務純益"] {
            #expect(SegmentInfoLLMNormalizer.hasSegmentProfitMeasure(try parsedTable(label)), "\(label)")
        }
        // 減損損失・持分法損益だけの表は利益指標を持たない。
        for label in ["減損損失", "持分法による投資損益", "研究開発費"] {
            #expect(!SegmentInfoLLMNormalizer.hasSegmentProfitMeasure(try parsedTable(label)), "\(label)")
        }
    }
}
