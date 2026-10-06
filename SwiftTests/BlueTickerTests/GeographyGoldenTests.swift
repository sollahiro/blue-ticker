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

    /// キヤノン型: 売上高と長期性資産が同じ表。売上行だけ公開し資産行は落とす。
    @Test func salesRowPreferredOverLongLivedAssets() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>日本</td><td>米州</td><td>欧州</td><td>アジア・オセアニア</td><td>合計</td></tr>
              <tr><td>売上高</td><td>961,480</td><td>1,489,639</td><td>1,225,475</td><td>948,133</td><td>4,624,727</td></tr>
              <tr><td>長期性資産</td><td>1,027,857</td><td>800,000</td><td>400,000</td><td>300,000</td><td>2,527,857</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(4_624_727), docID: "S100XTLJ")
        let snapshot = try #require(snapshotOrNil)
        let labels = Set(segmentLabels(snapshot))
        #expect(labels.contains("日本"))
        #expect(labels.contains("米州"))
        #expect(!labels.contains("長期性資産"))
        #expect(snapshot.rows.first { $0.labelRaw == "日本" }?.amount == yen(961_480))
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// フジックス型: 行ラベルが空の転置表（列=地域、唯一の数値行が売上）。
    @Test func unlabeledTransposedSalesRowPublishesRegions() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：千円）</p>
            <table>
              <tr><td></td><td></td><td></td><td></td><td>(単位：千円)</td></tr>
              <tr><td>日本</td><td>中国</td><td>アジア(中国除く)</td><td>その他の地域</td><td>合計</td></tr>
              <tr><td>4,249,123</td><td>743,000</td><td>442,000</td><td>41,000</td><td>5,475,123</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: 5_475_123 * 1_000, docID: "S100YHMW-unlabeled")
        let snapshot = try #require(snapshotOrNil)
        let labels = Set(segmentLabels(snapshot))
        #expect(labels.contains("日本"))
        #expect(labels.contains("中国"))
        #expect(snapshot.rows.first { $0.labelRaw == "日本" }?.amount == 4_249_123_000.0)
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 7734 型: 日本 × 海外内訳（アジア/北米/欧州/その他）× 連結の入れ子見出し。
    /// Ⅰ売上高行を転置し、海外合計・連結は subtotal。
    @Test func nestedJapanOverseasConsolidatedPublishesLeaves() async throws {
        let html = """
            <p>当連結会計年度</p>
            <table>
              <tr>
                <td rowspan="2"></td>
                <td rowspan="2">日本</td>
                <td colspan="5">海外売上高</td>
                <td rowspan="2">連結売上高</td>
              </tr>
              <tr>
                <td>アジア</td><td>北米</td><td>欧州</td><td>その他の地域</td><td>合計</td>
              </tr>
              <tr>
                <td>Ⅰ売上高（千円）</td>
                <td>29,122,646</td><td>13,442,307</td><td>10,127,597</td>
                <td>2,143,634</td><td>376,049</td><td>26,089,588</td><td>55,212,234</td>
              </tr>
              <tr>
                <td>Ⅱ連結売上高に占める割合（％）</td>
                <td>52.7</td><td>24.3</td><td>18.3</td><td>3.9</td><td>0.7</td><td>47.3</td><td>100</td>
              </tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: 55_212_234 * 1_000, docID: "S100YIB1-nested")
        let snapshot = try #require(snapshotOrNil)
        #expect(Set(segmentLabels(snapshot)) == Set(["日本", "アジア", "北米", "欧州", "その他の地域"]))
        #expect(snapshot.rows.first { $0.labelRaw == "日本" }?.amount == 29_122_646_000.0)
        #expect(snapshot.rows.first { $0.labelRaw == "アジア" }?.amount == 13_442_307_000.0)
        #expect(!segmentLabels(snapshot).contains { $0.contains("合計") || $0.contains("連結") })
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 177A 型: 日本 | 海外（アジア/欧州）の入れ子。葉のアジア/欧州を出す。
    @Test func nestedOverseasLeavesDropCoarseOverseasParent() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：千円）</p>
            <table>
              <tr>
                <td rowspan="2">日本</td>
                <td colspan="2">海外</td>
                <td rowspan="2">合計</td>
              </tr>
              <tr><td>アジア</td><td>欧州</td></tr>
              <tr>
                <td>3,963,534</td><td>975,040</td><td>450</td><td>4,939,025</td>
              </tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: 4_939_025 * 1_000, docID: "S100YB5D")
        let snapshot = try #require(snapshotOrNil)
        #expect(Set(segmentLabels(snapshot)) == Set(["日本", "アジア", "欧州"]))
        #expect(snapshot.rows.first { $0.labelRaw == "アジア" }?.amount == 975_040_000.0)
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 1514 型: その他の地域（豪州 / その他）。豪州は葉、残余は親とつなげる。
    @Test func nestedOtherRegionAustraliaAndResidual() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr>
                <td rowspan="2">日本</td>
                <td colspan="2">その他の地域</td>
                <td rowspan="2">合計</td>
              </tr>
              <tr><td>豪州</td><td>その他</td></tr>
              <tr>
                <td>14,386</td><td>8,182</td><td>30</td><td>22,599</td>
              </tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(22_599), docID: "S100TVLR")
        let snapshot = try #require(snapshotOrNil)
        #expect(Set(segmentLabels(snapshot)) == Set(["日本", "豪州", "その他の地域その他"]))
        #expect(snapshot.rows.first { $0.labelRaw == "豪州" }?.amount == yen(8_182))
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 1887 型: 行が前期/当期、列が地域。当期行を転置する。
    @Test func periodAsRowsPrefersCurrentYear() async throws {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>日本</td><td>アジア</td><td>合計</td></tr>
              <tr>
                <td>前連結会計年度(自 2024年６月１日 至 2025年５月31日)</td>
                <td>113,009</td><td>10,339</td><td>123,349</td>
              </tr>
              <tr>
                <td>当連結会計年度(自 2025年６月１日 至 2026年５月31日)</td>
                <td>121,492</td><td>13,715</td><td>135,207</td>
              </tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(135_207), docID: "S100YXXI")
        let snapshot = try #require(snapshotOrNil)
        #expect(Set(segmentLabels(snapshot)) == Set(["日本", "アジア"]))
        #expect(snapshot.rows.first { $0.labelRaw == "日本" }?.amount == yen(121_492))
        #expect(snapshot.rows.first { $0.labelRaw == "アジア" }?.amount == yen(13_715))
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 3659 型: 行=地域、列=事業別＋合計。合計列の金額を公開する。
    @Test func regionRowsBusinessColumnsUseTotalColumn() async throws {
        let html = """
            <p>当連結会計年度(自 2025年1月1日 至 2025年12月31日)</p>
            <p>（単位：百万円）</p>
            <table>
              <tr>
                <td></td><td colspan="3">事業別の売上収益</td><td rowspan="2">合計</td>
              </tr>
              <tr>
                <td></td><td>PCオンライン</td><td>モバイル</td><td>その他</td>
              </tr>
              <tr><td>日本</td><td>8,235</td><td>5,733</td><td>46</td><td>14,014</td></tr>
              <tr><td>韓国</td><td>186,830</td><td>60,122</td><td>3,021</td><td>249,973</td></tr>
              <tr><td>中国</td><td>59,283</td><td>50,209</td><td>21</td><td>109,513</td></tr>
              <tr>
                <td>北米及び欧州</td><td>61,139</td><td>7,218</td><td>225</td><td>68,582</td>
              </tr>
              <tr><td>その他</td><td>19,826</td><td>12,000</td><td>1,194</td><td>33,020</td></tr>
              <tr><td>合計</td><td>335,313</td><td>135,282</td><td>4,507</td><td>475,102</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(475_102), docID: "S100XSM4")
        let snapshot = try #require(snapshotOrNil)
        #expect(Set(segmentLabels(snapshot)) == Set(["日本", "韓国", "中国", "北米及び欧州", "その他"]))
        #expect(snapshot.rows.first { $0.labelRaw == "韓国" }?.amount == yen(249_973))
        #expect(snapshot.rows.first { $0.labelRaw == "日本" }?.amount == yen(14_014))
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 6875 型: 先頭行が「(1) 売上高」の単位見出し。列0の日本を落とさない。
    @Test func sectionSalesHeaderKeepsJapanColumn() async throws {
        let html = """
            <p>当連結会計年度</p>
            <table>
              <tr><td>(1) 売上高</td><td></td><td></td><td>（単位：千円）</td></tr>
              <tr><td>日本</td><td>台湾</td><td>その他</td><td>合計</td></tr>
              <tr>
                <td>70,611,521</td><td>9,577,883</td><td>3,625,381</td><td>83,814,786</td>
              </tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: 83_814_786 * 1_000, docID: "S100O9OH")
        let snapshot = try #require(snapshotOrNil)
        #expect(Set(segmentLabels(snapshot)) == Set(["日本", "台湾", "その他"]))
        #expect(snapshot.rows.first { $0.labelRaw == "日本" }?.amount == 70_611_521_000.0)
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 4575 型: 米国のみの転置表のあとに主要顧客表があっても地域表を使う。
    @Test func singleUnitedStatesTableIgnoresFollowingCustomerTable() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：千円）</p>
            <table>
              <tr><td>米国</td><td>合計</td></tr>
              <tr><td>108,945</td><td>108,945</td></tr>
            </table>
            <table>
              <tr><td>顧客の氏名または名称</td><td>売上高</td><td>関連するセグメント名</td></tr>
              <tr><td>Stemline Therapeutics, Inc.</td><td>108,945</td><td>医薬品事業</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: 108_945 * 1_000, docID: "S100MHTV")
        let snapshot = try #require(snapshotOrNil)
        #expect(segmentLabels(snapshot) == ["米国"])
        #expect(snapshot.rows.first { $0.labelRaw == "米国" }?.amount == 108_945_000.0)
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 7211 型: 空の売上高見出しの下に顧客契約行と外部顧客合計行。うち米国列は落とす。
    @Test func emptySalesHeaderUsesExternalCustomerSubtotalAndDropsOfWhichUS() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr>
                <td></td><td>日本</td><td>北米</td><td>北米</td>
                <td>欧州</td><td>アジア</td><td>オセアニア</td><td>その他</td><td>合計</td>
              </tr>
              <tr>
                <td></td><td></td><td></td><td>内、米国</td>
                <td></td><td></td><td></td><td></td><td></td>
              </tr>
              <tr>
                <td>売上高</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td>
              </tr>
              <tr>
                <td>外部顧客に対する売上高</td>
                <td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td>
              </tr>
              <tr>
                <td>顧客との契約から生じる収益</td>
                <td>638,986</td><td>661,310</td><td>373,349</td><td>211,992</td>
                <td>623,566</td><td>286,015</td><td>452,846</td><td>2,874,718</td>
              </tr>
              <tr>
                <td>その他の収益</td>
                <td>20,414</td><td>405</td><td>405</td><td>－</td>
                <td>978</td><td>19</td><td>－</td><td>21,818</td>
              </tr>
              <tr>
                <td></td><td>659,400</td><td>661,715</td><td>373,754</td><td>211,992</td>
                <td>624,545</td><td>286,035</td><td>452,846</td><td>2,896,536</td>
              </tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(2_896_536), docID: "S100YCMC")
        let snapshot = try #require(snapshotOrNil)
        #expect(Set(segmentLabels(snapshot)) == Set(["日本", "北米", "欧州", "アジア", "オセアニア", "その他"]))
        #expect(snapshot.rows.first { $0.labelRaw == "日本" }?.amount == yen(659_400))
        #expect(!segmentLabels(snapshot).contains("米国"))
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 6963 型: 見出しが「日 本」「合 計」。空白を潰して日本を残し合計列で転置する。
    @Test func spacedJapanAndTotalHeadersPublishChina() async throws {
        let html = """
            <p>当連結会計年度</p>
            <table>
              <tr><td>日 本</td><td>中国</td><td>その他</td><td>合 計</td></tr>
              <tr><td>145,144</td><td>146,600</td><td>189,402</td><td>481,148</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(481_148), docID: "S100YF41")
        let snapshot = try #require(snapshotOrNil)
        #expect(Set(segmentLabels(snapshot)) == Set(["日本", "中国", "その他"]))
        #expect(snapshot.rows.first { $0.labelRaw == "中国" }?.amount == yen(146_600))
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 9412 型: 国内|海外|計 の2行表。海外列を全社列にしない。
    @Test func japanOverseasTwoRowTableKeepsOverseas() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td>国内</td><td>海外</td><td>計</td></tr>
              <tr><td>114,902</td><td>12,682</td><td>127,584</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(127_584), docID: "S100YBNS")
        let snapshot = try #require(snapshotOrNil)
        #expect(Set(segmentLabels(snapshot)) == Set(["国内", "海外"]))
        #expect(snapshot.rows.first { $0.labelRaw == "海外" }?.amount == yen(12_682))
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 8031 型: 列見出しが「日本（百万円）」。単位付き地域名を落とさない。
    @Test func regionHeadersWithYenUnitSuffixPublishDestinations() async throws {
        let html = """
            <p>当連結会計年度（2025年4月1日から2026年3月31日まで）</p>
            <table>
              <tr>
                <td></td>
                <td>日本（百万円）</td><td>シンガポール（百万円）</td>
                <td>アメリカ（百万円）</td><td>オーストラリア（百万円）</td>
                <td>その他（百万円）</td><td>連結合計（百万円）</td>
              </tr>
              <tr>
                <td>収益</td>
                <td>7,084,345</td><td>2,431,669</td><td>1,167,690</td>
                <td>767,524</td><td>2,543,994</td><td>13,995,222</td>
              </tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(13_995_222), docID: "S100YAVT")
        let snapshot = try #require(snapshotOrNil)
        #expect(Set(segmentLabels(snapshot)) == Set(["日本", "シンガポール", "アメリカ", "オーストラリア", "その他"]))
        #expect(snapshot.rows.first { $0.labelRaw == "日本" }?.amount == yen(7_084_345))
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 6645 型: 国別の残余表より、地域列の外部顧客売上表を使う。
    @Test func destinationSalesTablePreferredOverCountryRemainder() async throws {
        let html = """
            <p>３．当連結会計年度および翌連結会計年度以降の収益の金額を理解するための情報</p>
            <table>
              <tr><td></td><td>第89期（百万円）</td></tr>
              <tr><td>国内</td><td>8,183</td></tr>
              <tr><td>海外</td><td></td></tr>
              <tr><td>中国</td><td>8,572</td></tr>
              <tr><td>オランダ</td><td>1,024</td></tr>
              <tr><td>その他</td><td>3,066</td></tr>
              <tr><td>海外合計</td><td>12,662</td></tr>
              <tr><td>合計</td><td>20,845</td></tr>
            </table>
            <p>第89期（自 2025年4月1日 至 2026年3月31日）（単位：百万円）</p>
            <table>
              <tr>
                <td></td><td>日本</td><td>米州</td><td>欧州</td>
                <td>中華圏</td><td>東南アジア他</td><td>直接輸出</td><td>連結</td>
              </tr>
              <tr>
                <td>外部顧客に対する売上高</td>
                <td>348,638</td><td>73,283</td><td>116,770</td>
                <td>144,131</td><td>82,039</td><td>2,490</td><td>767,351</td>
              </tr>
              <tr>
                <td>有形固定資産</td>
                <td>75,657</td><td>2,485</td><td>4,004</td>
                <td>13,888</td><td>7,038</td><td>－</td><td>103,072</td>
              </tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(767_351), docID: "S100YG81")
        let snapshot = try #require(snapshotOrNil)
        #expect(Set(segmentLabels(snapshot)) == Set(["日本", "米州", "欧州", "中華圏", "東南アジア他", "直接輸出"]))
        #expect(snapshot.rows.first { $0.labelRaw == "日本" }?.amount == yen(348_638))
        #expect(!segmentLabels(snapshot).contains("オランダ"))
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 6301 型: 行=事業・列=地域。連結列の事業行ではなく地域の計を公開する。
    @Test func productRowsByRegionColumnsPublishRegionTotals() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr>
                <td></td><td></td><td></td><td></td><td></td><td>（百万円）</td>
              </tr>
              <tr>
                <td></td><td>米州</td><td>欧州・アフリカ・中近東</td>
                <td>オセアニア・アジア※・CIS</td><td>日本</td><td>連結</td>
              </tr>
              <tr>
                <td>建設機械・車両</td>
                <td>1,824,091</td><td>712,698</td><td>944,795</td><td>314,516</td><td>3,796,100</td>
              </tr>
              <tr>
                <td>リテールファイナンス</td>
                <td>70,906</td><td>13,972</td><td>14,154</td><td>1,488</td><td>100,520</td>
              </tr>
              <tr>
                <td>産業機械他</td>
                <td>38,674</td><td>12,417</td><td>76,461</td><td>108,579</td><td>236,131</td>
              </tr>
              <tr>
                <td>計</td>
                <td>1,933,671</td><td>739,087</td><td>1,035,410</td><td>424,583</td><td>4,132,751</td>
              </tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(4_132_751), docID: "S100YD25")
        let snapshot = try #require(snapshotOrNil)
        #expect(Set(segmentLabels(snapshot)) == Set(["米州", "欧州・アフリカ・中近東", "オセアニア・アジア・CIS", "日本"]))
        #expect(snapshot.rows.first { $0.labelRaw == "日本" }?.amount == yen(424_583))
        #expect(!segmentLabels(snapshot).contains("リテールファイナンス"))
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }

    /// 8591 型: 営業収益行を使い、税引前当期純利益や長期性資産は出さない。
    @Test func operatingRevenuePreferredOverPretaxProfitAndPpe() async throws {
        let html = """
            <p>当連結会計年度末</p>
            <table>
              <tr>
                <td>当連結会計年度</td><td>当連結会計年度</td>
                <td>当連結会計年度</td><td>当連結会計年度</td><td>当連結会計年度</td>
              </tr>
              <tr>
                <td></td>
                <td>日本（百万円）</td><td>米州地域（百万円）</td>
                <td>その他海外（百万円）</td><td>連結合計（百万円）</td>
              </tr>
              <tr>
                <td>営業収益</td>
                <td>2,423,388</td><td>405,209</td><td>502,234</td><td>3,330,831</td>
              </tr>
              <tr>
                <td>税引前当期純利益</td>
                <td>442,322</td><td>35,156</td><td>213,953</td><td>691,431</td>
              </tr>
              <tr>
                <td>長期性資産残高</td>
                <td>1,961,020</td><td>70,896</td><td>1,277,096</td><td>3,309,012</td>
              </tr>
            </table>
            """
        let (snapshotOrNil, _) = await normalize(
            html: html, sales: yen(3_330_831), docID: "S100YG5L")
        let snapshot = try #require(snapshotOrNil)
        #expect(Set(segmentLabels(snapshot)) == Set(["日本", "米州地域", "その他海外"]))
        #expect(snapshot.rows.first { $0.labelRaw == "日本" }?.amount == yen(2_423_388))
        #expect(!segmentLabels(snapshot).contains("税引前当期純利益"))
        #expect(!snapshot.needsReview)
        #expect(publiclyServable(snapshot))
    }
}
