// SPEC_ORACLE: geography 公開形（REST/publish）。html_table → Jev 列選択 + 決定論の行。
// Fake 列スタブ。ネットワークなし。Linux CI で走る。
//
// 類型:
// 1 通常の複数地域
// 2 日本のみ / 単一地域（単一行でも公開する。収益認識の単一行 NR とは別）
// 3 geography_only（フジックス型: product_service は geography_only NA。地域は geography だけ）
// 4 うち内数 / 脚注 / クレディセゾン分母 / 転置（列=地域）
// 5 fail-closed NR（低確信、none_of_these、小計不一致、分母不一致）

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct GeographyGoldenTests {

    private func yen(_ n: Int) -> Double { Double(n) * Financial.millionYen }

    private func publiclyServable(_ snapshot: BreakdownSnapshot) -> Bool {
        isPubliclyServableBreakdown(
            source: breakdownSourceGeographyLLM,
            needsReview: snapshot.needsReview,
            warnings: snapshot.warnings)
    }

    private func segmentLabels(_ snapshot: BreakdownSnapshot) -> [String] {
        snapshot.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw)
    }

    private func normalize(
        html: String,
        sales: Double,
        heading: String = "地域ごとの情報",
        selected: String? = nil,
        confidence: Double = 0.9,
        pNone: Double? = nil,
        probabilities: [String: Double] = [:],
        docID: String = "S-geo-golden"
    ) async -> (BreakdownSnapshot?, LLMBreakdownAudit?) {
        var tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: heading)
        if !tables.isEmpty {
            tables[0].period = "当期"
        }
        return await GeographyBreakdownLLMNormalizer.normalize(
            ExtractedBreakdown(method: "html_table", tables: tables, facts: []),
            consolidatedSales: sales,
            decider: FakeRevenueRecognitionColumnDecider(
                selected: selected, confidence: confidence, pNone: pNone,
                probabilities: probabilities),
            fiscalYearEnd: "2026-03-31",
            docID: docID)
    }

    /// 1. 通常の複数地域（行=地域）。公開形は日本/北米/欧州/その他。
    @Test func multiRegionPublishedShape() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>600</td></tr>
              <tr><td>北米</td><td>250</td></tr>
              <tr><td>欧州</td><td>100</td></tr>
              <tr><td>その他</td><td>50</td></tr>
              <tr><td>合計</td><td>1,000</td></tr>
            </table>
            """
        let (snapshotOrNil, audit) = await normalize(html: html, sales: yen(1_000))
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.axis == breakdownAxisGeography)
        #expect(snapshot.sourceKind == "html_table")
        #expect(segmentLabels(snapshot) == ["日本", "北米", "欧州", "その他"])
        #expect(snapshot.rows.first { $0.labelRaw == "日本" }?.amount == yen(600))
        #expect(snapshot.denominator == yen(1_000))
        #expect(snapshot.denominatorTag == "income_statement.sales")
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
        #expect(audit?.columnJev != nil)
        let shareSum = snapshot.rows.filter { $0.rowKind == "segment" }.compactMap(\.share).reduce(0, +)
        #expect(abs(shareSum - 1.0) < 0.01)
    }

    /// 2. 日本のみ。単一地域でも公開する。
    @Test func japanOnlySingleRegionIsPublished() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>1,000</td></tr>
              <tr><td>合計</td><td>1,000</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(html: html, sales: yen(1_000), docID: "S-japan-only")
        let snapshot = try #require(snapshotOrNil)
        #expect(segmentLabels(snapshot) == ["日本"])
        #expect(snapshot.rows[0].amount == yen(1_000))
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 3. フジックス型: 報告セグメントは日本/アジア、製品は90％省略。
    /// product_service は geography_only。仕向地（日本/中国/アジア(中国除く)/その他）は geography。
    @Test func fujixGeographyOnlyKeepsRegionsOnGeographyAxis() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>報告セグメント</td><td>報告セグメント</td><td>報告セグメント</td><td>調整額</td><td>連結財務諸表計上額</td></tr>
              <tr><td></td><td>日本</td><td>アジア</td><td>計</td><td></td><td></td></tr>
              <tr><td>外部顧客に対する売上高</td><td>4,334</td><td>1,141</td><td>5,475</td><td>-</td><td>5,475</td></tr>
              <tr><td>セグメント損失</td><td>△193</td><td>△31</td><td>△224</td><td>1</td><td>△222</td></tr>
            </table>
            <p>１．製品及びサービスごとの情報 単一の製品・サービスの区分の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。</p>
            <p>２．地域ごとの情報</p>
            <table>
              <tr><td></td><td>日本</td><td>中国</td><td>アジア(中国除く)</td><td>その他の地域</td><td>合計</td></tr>
              <tr><td>外部顧客への売上高</td><td>4,249</td><td>743</td><td>442</td><td>41</td><td>5,475</td></tr>
            </table>
            """
        let sales = yen(5_475)
        let (product, productAudit) = await SegmentInfoLLMNormalizer.normalize(
            ExtractedBreakdown(
                method: "html_table",
                tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報"),
                facts: []),
            consolidatedSales: sales,
            decider: FakeRevenueRecognitionColumnDecider(),
            fiscalYearEnd: "2026-03-31",
            docID: "S100YHMW")
        #expect(product == nil)
        #expect(productAudit?.notApplicableReason == breakdownNotApplicableGeographyOnly)

        let geoHTML = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>日本</td><td>中国</td><td>アジア(中国除く)</td><td>その他の地域</td><td>合計</td></tr>
              <tr><td>外部顧客への売上高</td><td>4,249</td><td>743</td><td>442</td><td>41</td><td>5,475</td></tr>
            </table>
            """
        let (geoOrNil, _) = await normalize(html: geoHTML, sales: sales, docID: "S100YHMW")
        let geo = try #require(geoOrNil)
        let labels = Set(segmentLabels(geo))
        #expect(labels.contains("日本"))
        #expect(labels.contains("中国"))
        #expect(labels.contains(where: { $0.contains("アジア") }))
        #expect(labels.contains(where: { $0.contains("その他") }))
        #expect(geo.rows.first { $0.labelRaw == "日本" }?.amount == yen(4_249))
        #expect(!geo.needsReview)
        #expect(publiclyServable(geo))
    }

    /// 4. うち内数は親だけ公開。米国は北米の内数。
    @Test func ofWhichChildIsDroppedFromPublishedRows() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>254,181</td></tr>
              <tr><td>北米</td><td>37,897</td></tr>
              <tr><td>米国</td><td>37,220</td></tr>
              <tr><td>欧州</td><td>38,201</td></tr>
              <tr><td>その他</td><td>21,084</td></tr>
              <tr><td>合計</td><td>351,363</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(html: html, sales: yen(351_363))
        let snapshot = try #require(snapshotOrNil)
        #expect(segmentLabels(snapshot) == ["日本", "北米", "欧州", "その他"])
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 4. 脚注マーカーは公開ラベルから落ちる。
    @Test func footnoteMarkersStrippedFromPublishedLabels() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>395,472</td></tr>
              <tr><td>アメリカ</td><td>92,074</td></tr>
              <tr><td>米州（注）2</td><td>8,482</td></tr>
              <tr><td>欧州他（注）3</td><td>110,982</td></tr>
              <tr><td>中国</td><td>170,772</td></tr>
              <tr><td>アジア</td><td>95,409</td></tr>
              <tr><td>合計</td><td>873,191</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(873_190), docID: "S-teijin-geo")
        let snapshot = try #require(snapshotOrNil)
        #expect(segmentLabels(snapshot) == ["日本", "アメリカ", "米州", "欧州他", "中国", "アジア"])
        #expect(publiclyServable(snapshot) || snapshot.needsReview == false)
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 4. クレディセゾン型: 地域注記合計で分母を揃えて公開する。
    @Test func creditSaisonStyleDenominatorFromTableSubtotal() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>484,060</td></tr>
              <tr><td>インド</td><td>56,056</td></tr>
              <tr><td>その他</td><td>6,154</td></tr>
              <tr><td>合計</td><td>546,271</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(472_770), docID: "S-saison")
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.denominatorTag == "llm_table_subtotal")
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 4. 列=地域の転置表。合計列を選び行へ展開する。
    @Test func transposedRegionColumnsPublishDestinationRows() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>日本</td><td>中国</td><td>アジア(中国除く)</td><td>その他の地域</td><td>合計</td></tr>
              <tr><td>外部顧客への売上高</td><td>4,249</td><td>743</td><td>442</td><td>41</td><td>5,475</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(html: html, sales: yen(5_475), docID: "S-transposed")
        let snapshot = try #require(snapshotOrNil)
        let labels = Set(segmentLabels(snapshot))
        #expect(labels.contains("日本"))
        #expect(labels.contains("中国"))
        #expect(snapshot.rows.first { $0.labelRaw == "日本" }?.amount == yen(4_249))
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 5. 低確信は fail-closed NR。公開しない。
    @Test func lowConfidenceIsNeedsReviewAndHidden() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>600</td></tr>
              <tr><td>海外</td><td>400</td></tr>
              <tr><td>合計</td><td>1,000</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(1_000), confidence: 0.49, docID: "S-low-conf")
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains(RevenueRecognitionColumnNormalizer.warningLowConfidence))
        #expect(!publiclyServable(snapshot))
    }

    /// 5. none_of_these を高確信で受理したらスナップショット無し。
    @Test func noneOfTheseHighConfidenceYieldsNoSnapshot() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>1,000</td></tr>
              <tr><td>合計</td><td>1,000</td></tr>
            </table>
            """
        let (snapshot, audit) = await normalize(
            html: html, sales: yen(1_000),
            selected: RevenueRecognitionColumnNormalizer.noneOfThese,
            confidence: 0.9, pNone: 0.9, docID: "S-none")
        #expect(snapshot == nil)
        #expect(audit?.jev != nil)
    }

    /// 5. none_of_these が弱いときは実列へ落として NR（fail-closed）。
    @Test func weakNoneOfTheseFallsBackToRealColumnNeedsReview() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>600</td></tr>
              <tr><td>海外</td><td>400</td></tr>
              <tr><td>合計</td><td>1,000</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(1_000),
            selected: RevenueRecognitionColumnNormalizer.noneOfThese,
            confidence: 0.6, pNone: 0.2, docID: "S-none-weak")
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningNoneOfTheseOverridden))
        #expect(!publiclyServable(snapshot))
        #expect(!segmentLabels(snapshot).isEmpty)
    }

    /// 5. 7734 型: 海外計と構成行が合わない HTML は subtotal_mismatch NR。
    @Test func overseasSubtotalMismatchIsNeedsReview() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>29,122,646</td></tr>
              <tr><td>アジア</td><td>13,442,307</td></tr>
              <tr><td>北米</td><td>10,127,597</td></tr>
              <tr><td>欧州</td><td>2,143,634</td></tr>
              <tr><td>その他の地域</td><td>3,760,490</td></tr>
              <tr><td>海外合計</td><td>26,089,588</td></tr>
              <tr><td>連結売上高</td><td>55,212,234</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(55_212_234), docID: "S100YIB1-mismatch")
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains(GeographyBreakdownLLMNormalizer.subtotalMismatchWarning))
        #expect(!publiclyServable(snapshot))
    }

    /// 5. 7734 正しい海外計は公開する。
    @Test func matchingOverseasSubtotalPublishes() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>29,122,646</td></tr>
              <tr><td>アジア</td><td>13,442,307</td></tr>
              <tr><td>北米</td><td>10,127,597</td></tr>
              <tr><td>欧州</td><td>2,143,634</td></tr>
              <tr><td>その他の地域</td><td>376,049</td></tr>
              <tr><td>海外合計</td><td>26,089,588</td></tr>
              <tr><td>連結売上高</td><td>55,212,234</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(55_212_234), docID: "S100YIB1")
        let snapshot = try #require(snapshotOrNil)
        #expect(segmentLabels(snapshot).contains("日本"))
        #expect(snapshot.rows.first { $0.labelRaw.contains("その他") }?.amount == yen(376_049))
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 5. 分母が IS とも表小計とも合わないときは NR（fail-closed）。
    @Test func denominatorMismatchWithoutSubtotalIsNeedsReview() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>400,000</td></tr>
              <tr><td>海外</td><td>100,000</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(1_000_000), docID: "S-denom-nr")
        let snapshot = try #require(snapshotOrNil)
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains("llm_row_sum_mismatch"))
        #expect(!publiclyServable(snapshot))
    }

    /// アサヒ型: 日本 / 海外の2区分。うち内数は出さない。
    @Test func asahiStyleJapanOverseasPublished() async throws {
        let html = """
            <p>当年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>対外部売上収益</td></tr>
              <tr><td>日本</td><td>1,281,768</td></tr>
              <tr><td>海外</td><td>1,229,340</td></tr>
              <tr><td>（うちオーストラリア）</td><td>500,000</td></tr>
              <tr><td>合計</td><td>2,511,108</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(2_511_108), docID: "S100QG09")
        let snapshot = try #require(snapshotOrNil)
        #expect(Set(segmentLabels(snapshot)) == Set(["日本", "海外"]))
        #expect(snapshot.rows.first { $0.labelRaw == "日本" }?.amount == yen(1_281_768))
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }
}
