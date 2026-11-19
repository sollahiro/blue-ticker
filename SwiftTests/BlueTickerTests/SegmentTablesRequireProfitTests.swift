import Testing

@testable import BlueTickerCore

/// segment 軸は、報告セグメントごとの売上高・利益又は損失などの表だけを使う。
/// 4180 / 4565 / 4593: 主要な顧客・製品別の表をセグメントとして公開していた。
struct SegmentTablesRequireProfitTests {
    private func tables(_ html: String) -> [BreakdownTable] {
        BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
    }

    private func normalized(_ html: String) async -> BreakdownSnapshot? {
        let (snapshot, _) = await SegmentInfoLLMNormalizer.normalize(
            ExtractedBreakdown(method: "html_table", tables: tables(html), facts: []),
            consolidatedSales: 92_872 * Financial.millionYen,
            decider: FakeRevenueRecognitionColumnDecider(),
            fiscalYearEnd: "2026-03-31", docID: "S-test",
            publishedAxis: breakdownAxisSegment)
        return snapshot
    }

    @Test func majorCustomerTableIsNotASegmentTable() async {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>Coupang, Inc.</td><td>10,605</td><td>13,168</td></tr>
              <tr><td>その他</td><td>23,452</td><td>30,569</td></tr>
            </table>
            """
        #expect(tables(html).allSatisfy { !SegmentInfoLLMNormalizer.isReportableSegmentInfoTable($0) })
        #expect(await normalized(html) == nil)
    }

    @Test func impairmentOnlyTableIsNotASegmentTable() async {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>食品製造販売事業</td><td>その他</td><td>合計</td></tr>
              <tr><td>減損損失</td><td>15</td><td>－</td><td>15</td></tr>
            </table>
            """
        #expect(tables(html).allSatisfy { !SegmentInfoLLMNormalizer.isReportableSegmentInfoTable($0) })
        #expect(await normalized(html) == nil)
    }

    @Test func segmentMatrixIsKeptEvenWhenColumnsLookLikeProducts() async throws {
        // 7752: 列が事業名でも、売上高・利益の行がある表は報告セグメントの表。
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>デジタルサービス</td><td>デジタルプロダクツ</td><td>合計</td></tr>
              <tr><td>外部顧客向けの売上高</td><td>1,988</td><td>186</td><td>2,174</td></tr>
              <tr><td>セグメント損益</td><td>27</td><td>31</td><td>58</td></tr>
            </table>
            """
        #expect(tables(html).allSatisfy { SegmentInfoLLMNormalizer.isReportableSegmentInfoTable($0) })
        let snapshot = try #require(await normalized(html))
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        #expect(segments.map(\.profit) == [27 * Financial.millionYen, 31 * Financial.millionYen])
    }

    @Test func salesOnlySegmentTableIsKept() {
        // 利益の行が無くても、外部顧客・セグメント間の行がある表は報告セグメントの表（積み上げの売上表）。
        let html = """
            <table>
              <tr><td>映画：</td><td></td></tr>
              <tr><td>外部顧客に対するもの</td><td>1,010</td></tr>
              <tr><td>セグメント間取引</td><td>1</td></tr>
            </table>
            """
        #expect(tables(html).allSatisfy { SegmentInfoLLMNormalizer.isReportableSegmentInfoTable($0) })
    }

    /// 固定のラベル語にない行（表記ゆれ）も、Jev に出す候補には残る。
    @Test func candidateRowsIncludeRowsOutsideTheLabelLists() throws {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>流通</td><td>運輸</td><td>合計</td></tr>
              <tr><td>外部顧客への売上高</td><td>1,988</td><td>186</td><td>2,174</td></tr>
              <tr><td>報告セグメント損益額</td><td>27</td><td>31</td><td>58</td></tr>
            </table>
            """
        let table = try #require(RevenueRecognitionCandidates.parse(tables: tables(html)).first)
        let candidates = SegmentInfoLLMNormalizer.candidateMetricRows(in: table).map(\.label)
        #expect(candidates.contains("報告セグメント損益額"))
        #expect(candidates.contains("外部顧客への売上高"))
    }

    /// 8304 S100YCRO: 売上の行が無い銀行のセグメント表（連結粗利益・連結実質業務純益）も報告セグメントの表。
    /// 利益の調整表（報告セグメント合計 → 経常利益）を事業として取り込まない。
    @Test func bankSegmentMatrixWithoutSalesRowWinsOverReconciliationTable() async throws {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td></td><td>投資銀行ユニット</td><td>市場国際ユニット</td><td>報告セグメント合計</td></tr>
              <tr><td></td><td>連結粗利益</td><td>61,178</td><td>15,324</td><td>76,502</td></tr>
              <tr><td>連結実質業務純益</td><td>連結実質業務純益</td><td>38,637</td><td>3,923</td><td>42,560</td></tr>
              <tr><td>セグメント資産</td><td>セグメント資産</td><td>2,940,409</td><td>3,848,407</td><td>6,788,816</td></tr>
            </table>
            <table>
              <tr><td>連結実質業務純益</td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>報告セグメント合計</td><td>36,420</td><td>42,560</td></tr>
              <tr><td>与信関連費用等</td><td>△9,445</td><td>△8,465</td></tr>
              <tr><td>連結損益計算書の経常利益</td><td>17,561</td><td>27,183</td></tr>
            </table>
            """
        let snapshot = try #require(await normalized(html))
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        #expect(segments.map(\.labelRaw) == ["投資銀行ユニット", "市場国際ユニット"])
        #expect(segments.map(\.profit) == [38_637 * Financial.millionYen, 3_923 * Financial.millionYen])
    }
}
