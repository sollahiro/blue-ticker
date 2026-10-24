// SPEC_ORACLE: セグメント情報 html_table の類型。
// 1 事業別の報告セグメントはそのまま採る
// 2 地域別の報告セグメントで製品別もある → 製品を採り、地域は捨て、両方を足さない
// 3 地域別のみ → product_service は geography_only（地域は geography 軸。日本/アジアを product_service に載せない）
// 3b 報告セグメントが地域で製品は90％省略（省略文は製品表ではない） → 3 と同じ geography_only
// 4 単一セグメントと開示 → single_segment_disclosed
// 並行ブロック（同じ合計を地域と製品で分けた表）は 2。
// デンソー / 三菱商事 / 東京エレクトロン型がセグメント情報見出しで出たときも同じ規則。
// ネットワークなし。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct SegmentInfoGoldenTests {

    private static func snapshot(
        html: String,
        sales: Double,
        heading: String = "セグメント情報",
        caption: String? = nil,
        period: String = "当期"
    ) async -> (BreakdownSnapshot?, LLMBreakdownAudit?) {
        var tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: heading)
        if let caption, !tables.isEmpty {
            tables[0].precedingCaption = caption
        }
        if !tables.isEmpty {
            tables[0].period = period
        }
        return await SegmentInfoLLMNormalizer.normalize(
            ExtractedBreakdown(method: "html_table", tables: tables, facts: []),
            consolidatedSales: sales,
            decider: FakeRevenueRecognitionColumnDecider(),
            fiscalYearEnd: "2026-03-31",
            docID: "S-seg-golden")
    }

    /// 7752 S100LKDZ（US-GAAP 事業の種類別セグメント情報）: 子（オフィスプリンティング分野 /
    /// オフィスサービス分野）の直後に親の小計（オフィス分野）が来る。親は subtotal にして足さない。
    /// 金額は原本の当期列（その他分野は外部顧客向け、セグメント間取引の行は省き、期間見出しはテストの決算期に合わせた形）。
    // source: code=7752 fy_end=2021-03-31 doc_id=S100LKDZ page=121 field=product_service.オフィス分野
    @Test func trailingParentSubtotalIsNotAdded() async throws {
        let html = """
            <table>
              <tr><td></td><td>前連結会計年度(自2024年４月１日 至2025年３月31日)(百万円)</td><td>当連結会計年度(自2025年４月１日 至2026年３月31日)(百万円)</td></tr>
              <tr><td>損益情報：</td><td></td><td></td></tr>
              <tr><td>売上高：</td><td></td><td></td></tr>
              <tr><td>オフィスプリンティング分野</td><td>1,013,055</td><td>815,895</td></tr>
              <tr><td>オフィスサービス分野</td><td>557,191</td><td>532,307</td></tr>
              <tr><td>オフィス分野</td><td>1,570,246</td><td>1,348,202</td></tr>
              <tr><td>商用印刷分野</td><td>178,396</td><td>134,661</td></tr>
              <tr><td>産業印刷分野</td><td>23,006</td><td>24,689</td></tr>
              <tr><td>サーマル分野</td><td>61,896</td><td>56,874</td></tr>
              <tr><td>その他分野</td><td>175,036</td><td>117,643</td></tr>
              <tr><td>合計</td><td>2,008,580</td><td>1,682,069</td></tr>
            </table>
            """
        let sales = 1_682_069 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.snapshot(html: html, sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let segments: [String] = snapshot.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        #expect(segments == ["オフィスプリンティング分野", "オフィスサービス分野", "商用印刷分野", "産業印刷分野", "サーマル分野", "その他分野"])
        let office = snapshot.rows.first { $0.labelRaw == "オフィス分野" }
        let officeKind: String? = office?.rowKind
        #expect(officeKind == "subtotal")
        let warnings: [String] = snapshot.warnings
        #expect(!warnings.contains("llm_row_sum_mismatch"))
        let needsReview: Bool = snapshot.needsReview
        #expect(needsReview == false)
    }

    /// 合計が既に売上の許容幅にあるときは、直前 2 行の和に一致する行でも落とさない。
    @Test func rowEqualToPrecedingSumIsKeptWhenTotalAlreadyMatches() async throws {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>当連結会計年度</td></tr>
              <tr><td>売上高：</td><td></td></tr>
              <tr><td>A事業</td><td>100</td></tr>
              <tr><td>B事業</td><td>200</td></tr>
              <tr><td>C事業</td><td>300</td></tr>
              <tr><td>合計</td><td>600</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await Self.snapshot(html: html, sales: 600 * Financial.millionYen)
        let snapshot = try #require(snapshotOrNil)
        let segments: [String] = snapshot.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        #expect(segments == ["A事業", "B事業", "C事業"])
    }

    /// 4901 S100LV2D のセグメント損益と調整表、7062 S100YLVZ ののれん償却額及び未償却残高は
    /// 売上の行が無いので売上内訳の候補にしない。
    // source: code=7062 fy_end=2026-03-31 doc_id=S100YLVZ page=92 field=product_service.当期償却額
    @Test func profitAndGoodwillOnlyTablesAreNotSalesCandidates() {
        let profitHTML = """
            <table>
              <tr><td></td><td>前連結会計年度 (百万円)</td><td>当連結会計年度 (百万円)</td></tr>
              <tr><td>営業利益：</td><td></td><td></td></tr>
              <tr><td>イメージング ソリューション</td><td>25,076</td><td>15,591</td></tr>
              <tr><td>ドキュメント ソリューション</td><td>105,045</td><td>73,284</td></tr>
              <tr><td>計</td><td>130,121</td><td>88,875</td></tr>
              <tr><td>全社費用及びセグメント間取引消去</td><td>△35,953</td><td>△30,909</td></tr>
              <tr><td>営業外収益及び費用</td><td>△13,499</td><td>70,397</td></tr>
              <tr><td>税金等調整前当期純利益</td><td>80,669</td><td>128,363</td></tr>
            </table>
            """
        let goodwillHTML = """
            <table>
              <tr><td></td><td>マッサージ直営</td><td>メディカルケア</td><td>合計</td></tr>
              <tr><td>当期償却額</td><td>2,980</td><td>8,615</td><td>11,595</td></tr>
              <tr><td>当期末残高</td><td>5,489</td><td>－</td><td>5,489</td></tr>
            </table>
            """
        let salesHTML = """
            <table>
              <tr><td></td><td>マッサージ直営</td><td>メディカルケア</td><td>合計</td></tr>
              <tr><td>外部顧客への売上高</td><td>4,144,207</td><td>2,344,404</td><td>6,488,611</td></tr>
              <tr><td>セグメント利益</td><td>1,154,272</td><td>△184,337</td><td>969,935</td></tr>
            </table>
            """
        for (html, nonSales) in [(profitHTML, true), (goodwillHTML, true), (salesHTML, false)] {
            let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
            let parsed = RevenueRecognitionCandidates.parse(tables: tables)
            let table = parsed.first
            let flagged: Bool? = table.map(SegmentInfoLLMNormalizer.isNonSalesMetricTable)
            #expect(flagged == nonSales)
        }
    }

    /// 1. 事業別の報告セグメント（キヤノン注23型の列=事業マトリクス）。
    @Test func type1BusinessReportingSegmentsTakenAsIs() async throws {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>プリンティング</td><td>メディカル</td><td>その他及び全社</td><td>消去</td><td>連結</td></tr>
              <tr><td>売上高</td><td></td><td></td><td></td><td></td><td></td></tr>
              <tr><td>外部顧客向け</td><td>2,487,885</td><td>579,723</td><td>144,682</td><td>-</td><td>3,212,290</td></tr>
              <tr><td>営業利益</td><td>255,759</td><td>32,775</td><td>△69,451</td><td>0</td><td>219,083</td></tr>
            </table>
            """
        let sales = 3_212_290 * Financial.millionYen
        let (snapshotOrNil, audit) = await Self.snapshot(html: html, sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let labels: Set<String> = Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.map { $0.labelRaw })
        #expect(labels == Set(["プリンティング", "メディカル", "その他及び全社"]))
        #expect(audit?.profitDisclosed == true)
        #expect(snapshot.sourceKind == "segment_info")
        #expect(!snapshot.needsReview)
    }

    /// 2. 地域別の報告セグメントと製品別が同じ合計 → 製品だけ。
    @Test func type2GeographicSegmentsWithProductBreakdownTakesProduct() async throws {
        let html = RevenueRecognitionTableStructureTests.telHTML
        let sales = 2_443_533 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.snapshot(
            html: html, sales: sales, heading: "セグメント情報")
        let snapshot = try #require(snapshotOrNil)
        let labels: Set<String> = Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.map { $0.labelRaw })
        #expect(labels.contains("新規装置"))
        #expect(labels.contains("フィールドソリューション他"))
        #expect(!labels.contains("日本"))
        #expect(!labels.contains("北米"))
        #expect(!labels.contains("中国"))
        let equipment = try #require(
            snapshot.rows.first { $0.labelRaw.contains("新規装置") || $0.categoryGroup?.contains("新規装置") == true })
        #expect(equipment.amount == 1_817_250 * Financial.millionYen)
        #expect(!snapshot.needsReview)
    }

    /// 3b. 報告セグメントが日本/アジアで、製品別は90％省略 → product_service は geography_only。
    @Test func type3bOmittedProductIsGeographyOnlyNotJapanAsiaOnBusiness() async throws {
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
              <tr><td>日本</td><td>中国</td><td>アジア(中国除く)</td><td>その他の地域</td><td>合計</td></tr>
              <tr><td>4,249</td><td>743</td><td>442</td><td>41</td><td>5,475</td></tr>
            </table>
            """
        let sales = 5_475 * Financial.millionYen
        let (snapshot, audit) = await Self.snapshot(
            html: html, sales: sales, heading: "セグメント情報")
        #expect(snapshot == nil)
        #expect(audit?.notApplicableReason == breakdownNotApplicableGeographyOnly)
    }

    /// 3. 地域別のみ → product_service は geography_only（日本/海外を product_service に載せない）。
    @Test func type3GeographyOnlyIsNotApplicable() async throws {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>当連結会計年度</td></tr>
              <tr><td>日本</td><td>600</td></tr>
              <tr><td>海外</td><td>400</td></tr>
              <tr><td>合計</td><td>1,000</td></tr>
            </table>
            """
        let sales = 1_000 * Financial.millionYen
        let (snapshot, audit) = await Self.snapshot(html: html, sales: sales)
        #expect(snapshot == nil)
        #expect(audit?.notApplicableReason == breakdownNotApplicableGeographyOnly)
    }

    /// 4. 単一セグメントと開示。
    @Test func type4SingleSegmentDisclosed() async throws {
        let html = """
            <table>
              <tr><td>区分</td><td>当連結会計年度</td></tr>
              <tr><td>売上高</td><td>1,000</td></tr>
              <tr><td>合計</td><td>1,000</td></tr>
            </table>
            """
        let sales = 1_000 * Financial.millionYen
        let (snapshot, audit) = await Self.snapshot(
            html: html, sales: sales, caption: "当社の事業は単一セグメントであるため、記載を省略しております。")
        #expect(snapshot == nil)
        #expect(audit?.notApplicableReason == breakdownNotApplicableSingleSegmentDisclosed)
    }

    /// デンソー型（2 列ラベル域・分野計）がセグメント情報見出しでも製品行を採る。
    @Test func densoStyleProductRowsUnderSegmentInfoHeading() async throws {
        let html = RevenueRecognitionTableStructureTests.densoHTML
        let sales = 7_161_777 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.snapshot(html: html, sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let labels: Set<String> = Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.map { $0.labelRaw })
        #expect(labels.contains("サーマルシステム"))
        #expect(labels.contains("パワトレインシステム"))
        #expect(labels.contains("非車載事業分野"))
        #expect(!labels.contains("自動車分野計"))
    }

    /// 三菱商事型: 行が指標・列が事業のマトリクス。顧客契約行を転置する。
    @Test func mitsubishiStyleTransposedContractRevenueRow() async throws {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>地球環境エネルギー</td><td>金属資源</td><td>その他</td><td>調整・消去</td><td>連結金額</td></tr>
              <tr><td>顧客との契約から認識した収益</td><td>1,851,642</td><td>1,243,344</td><td>8,539</td><td>-40</td><td>3,103,485</td></tr>
              <tr><td>その他の源泉から認識した収益</td><td>100</td><td>200</td><td>0</td><td>0</td><td>300</td></tr>
            </table>
            """
        let sales = 3_103_485 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.snapshot(html: html, sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let labels: Set<String> = Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.map { $0.labelRaw })
        #expect(labels.contains("地球環境エネルギー"))
        #expect(labels.contains("金属資源"))
        let energy = try #require(snapshot.rows.first { $0.labelRaw == "地球環境エネルギー" })
        #expect(energy.amount == 1_851_642 * Financial.millionYen)
        #expect(!labels.contains(where: { $0.contains("その他の源泉") }))
    }

    /// US-GAAP セグメント情報で行が「セグメント収益」等の指標、列が事業のときも転置する。
    @Test func type1SegmentRevenueRowTransposesBusinessColumns() async throws {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>法人営業</td><td>不動産</td><td>銀行</td><td>連結</td></tr>
              <tr><td>セグメント収益</td><td>500</td><td>300</td><td>200</td><td>1,000</td></tr>
              <tr><td>セグメント利益</td><td>50</td><td>30</td><td>20</td><td>100</td></tr>
            </table>
            """
        let sales = 1_000 * Financial.millionYen
        let (snapshotOrNil, _) = await Self.snapshot(html: html, sales: sales)
        let snapshot = try #require(snapshotOrNil)
        let labels: Set<String> = Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.map { $0.labelRaw })
        #expect(labels == Set(["法人営業", "不動産", "銀行"]))
        #expect(!labels.contains("セグメント収益"))
        let leasing = try #require(snapshot.rows.first { $0.labelRaw == "法人営業" })
        #expect(leasing.amount == 500 * Financial.millionYen)
        #expect(leasing.profit == 50 * Financial.millionYen)
    }

    private static func segmentRows(_ snapshot: BreakdownSnapshot) -> [String: Double] {
        Dictionary(
            snapshot.rows.filter { $0.rowKind == "segment" }.map { ($0.labelRaw, $0.amount) },
            uniquingKeysWith: { first, _ in first })
    }

    /// 連結列だけに金額がある調整行（その他の営業収益〜税引前利益）は、ラベルがセグメント列側に
    /// 置かれる。ラベル域を 2 列と読んで金額をラベルにしない。
    /// 列見出しは原本の当年度表、行は売上と利益と調整行の一部。
    // source: code=2503 fy_end=2021-12-31 doc_id=S100NR8P page=117 field=product_service.国内飲料
    @Test func reconciliationRowsUnderSegmentColumnsKeepOneLabelColumn() async throws {
        let html = """
            <table>
              <tr><td>(単位：百万円)</td><td>報告セグメント</td><td>報告セグメント</td><td>報告セグメント</td><td>報告セグメント</td><td>その他(注１)</td><td>調整額(注２)</td><td>連結</td></tr>
              <tr><td></td><td>国内ビール・スピリッツ</td><td>国内飲料</td><td>オセアニア酒類</td><td>医薬</td><td>その他(注１)</td><td>調整額(注２)</td><td>連結</td></tr>
              <tr><td>外部顧客からの売上収益</td><td>661,326</td><td>244,386</td><td>216,258</td><td>351,696</td><td>347,902</td><td>－</td><td>1,821,570</td></tr>
              <tr><td>セグメント間売上収益</td><td>1,784</td><td>2,208</td><td>55</td><td>550</td><td>70,293</td><td>△74,890</td><td>－</td></tr>
              <tr><td>計</td><td>663,111</td><td>246,594</td><td>216,314</td><td>352,246</td><td>418,196</td><td>△74,890</td><td>1,821,570</td></tr>
              <tr><td>セグメント利益(注３)</td><td>70,541</td><td>21,099</td><td>26,562</td><td>61,197</td><td>31,334</td><td>△45,303</td><td>165,430</td></tr>
              <tr><td></td><td></td><td></td><td></td><td></td><td>その他の営業収益</td><td>その他の営業収益</td><td>8,239</td></tr>
              <tr><td></td><td></td><td></td><td></td><td></td><td>その他の営業費用</td><td>その他の営業費用</td><td>105,585</td></tr>
              <tr><td></td><td></td><td></td><td></td><td></td><td>金融収益</td><td>金融収益</td><td>4,087</td></tr>
              <tr><td></td><td></td><td></td><td></td><td></td><td>金融費用</td><td>金融費用</td><td>7,044</td></tr>
              <tr><td></td><td></td><td></td><td></td><td></td><td>持分法による投資利益</td><td>持分法による投資利益</td><td>34,490</td></tr>
              <tr><td></td><td></td><td></td><td></td><td></td><td>税引前利益</td><td>税引前利益</td><td>99,617</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await Self.snapshot(
            html: html, sales: 1_821_570 * Financial.millionYen)
        let snapshot = try #require(snapshotOrNil)
        let rows = Self.segmentRows(snapshot)
        #expect(rows["国内飲料"] == 244_386 * Financial.millionYen)
        #expect(rows["医薬"] == 351_696 * Financial.millionYen)
        #expect(rows.count == 5)
        let needsReview: Bool = snapshot.needsReview
        #expect(needsReview == false)
    }

    /// 左端の列にセグメント名、その下に指標が縦に並ぶ表。セグメントを行に畳み、外部顧客への
    /// 売上高を採る。続きの「連結」だけの表は候補にしない。セグメント間の行と資産の行は省いた形。
    // source: code=6981 fy_end=2021-03-31 doc_id=S100LPV9 page=98 field=product_service.コンポーネント
    @Test func verticalSegmentBlocksCollapseToRows() async throws {
        let html = """
            <table>
              <tr><td></td><td>項目</td><td>前連結会計年度（自 2019年４月１日 至 2020年３月31日）</td><td>前連結会計年度（自 2019年４月１日 至 2020年３月31日）</td><td>当連結会計年度（自 2020年４月１日 至 2021年３月31日）</td><td>当連結会計年度（自 2020年４月１日 至 2021年３月31日）</td></tr>
              <tr><td></td><td>項目</td><td>金額（百万円）</td><td>百分比（％）</td><td>金額（百万円）</td><td>百分比（％）</td></tr>
              <tr><td>コンポーネント</td><td>売上高</td><td></td><td></td><td></td><td></td></tr>
              <tr><td></td><td>（1）外部顧客に対する売上高</td><td>1,051,721</td><td></td><td>1,143,482</td><td></td></tr>
              <tr><td></td><td>事業利益（△損失）</td><td>249,651</td><td>22.7</td><td>312,998</td><td>26.6</td></tr>
              <tr><td>モジュール</td><td>売上高</td><td></td><td></td><td></td><td></td></tr>
              <tr><td></td><td>（1）外部顧客に対する売上高</td><td>478,619</td><td></td><td>484,099</td><td></td></tr>
              <tr><td></td><td>事業利益（△損失）</td><td>49,431</td><td>10.3</td><td>54,277</td><td>11.2</td></tr>
              <tr><td>その他</td><td>売上高</td><td></td><td></td><td></td><td></td></tr>
              <tr><td></td><td>（1）外部顧客に対する売上高</td><td>3,705</td><td></td><td>2,612</td><td></td></tr>
              <tr><td></td><td>事業利益（△損失）</td><td>5,717</td><td>9.7</td><td>7,778</td><td>12.7</td></tr>
            </table>
            <table>
              <tr><td></td><td>項目</td><td>前連結会計年度（自 2019年４月１日 至 2020年３月31日）</td><td>前連結会計年度（自 2019年４月１日 至 2020年３月31日）</td><td>当連結会計年度（自 2020年４月１日 至 2021年３月31日）</td><td>当連結会計年度（自 2020年４月１日 至 2021年３月31日）</td></tr>
              <tr><td></td><td>項目</td><td>金額（百万円）</td><td>百分比（％）</td><td>金額（百万円）</td><td>百分比（％）</td></tr>
              <tr><td>連結</td><td>売上高</td><td></td><td></td><td></td><td></td></tr>
              <tr><td></td><td>（1）外部顧客に対する売上高</td><td>1,534,045</td><td></td><td>1,630,193</td><td></td></tr>
              <tr><td></td><td>営業利益</td><td>253,247</td><td>16.5</td><td>313,240</td><td>19.2</td></tr>
            </table>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
        let collapsed = tables.map(SegmentInfoLLMNormalizer.collapsingSegmentBlocks)
        let parsed = RevenueRecognitionCandidates.parse(tables: collapsed)
        let labels = parsed.first?.items.map(\.label) ?? []
        #expect(labels == ["コンポーネント", "モジュール", "その他"])
        let preferred = SegmentInfoLLMNormalizer.preferredTables(parsed).map(\.tableIndex)
        #expect(preferred == [0])

        let (snapshotOrNil, _) = await SegmentInfoLLMNormalizer.normalize(
            ExtractedBreakdown(method: "html_table", tables: tables, facts: []),
            consolidatedSales: 1_630_193 * Financial.millionYen,
            decider: FakeRevenueRecognitionColumnDecider(selected: "t0_c4"),
            fiscalYearEnd: "2021-03-31", docID: "S-seg-golden")
        let snapshot = try #require(snapshotOrNil)
        let rows = Self.segmentRows(snapshot)
        #expect(rows["コンポーネント"] == 1_143_482 * Financial.millionYen)
        #expect(rows["モジュール"] == 484_099 * Financial.millionYen)
        #expect(rows["その他"] == 2_612 * Financial.millionYen)
        let needsReview: Bool = snapshot.needsReview
        #expect(needsReview == false)
    }

    /// 報告セグメントの列が 2 表に分かれ、後ろの表の最後に合計列がある。行ラベルが行ごとに一致する
    /// 同じ期間の 2 表を横につなぐ。原本の当連結会計年度の収益表から収益と利益の行を抜いた形。
    // source: code=8591 fy_end=2026-03-31 doc_id=S100YG5L page=255 field=product_service.ORIX USA
    @Test func segmentColumnsSplitAcrossTwoTablesAreJoined() async throws {
        func table(_ header: [String], _ rows: [(String, [String])]) -> BreakdownTable {
            let grid = [Array(repeating: "当連結会計年度", count: header.count + 1), [""] + header,
                [""] + header.map { _ in "（百万円）" }]
                + rows.map { [$0.0] + $0.1 }
            return BreakdownTable(
                heading: "セグメント情報", markdown: BreakdownExtractor.gridToMarkdown(grid),
                period: "当期", unitCaption: "百万円")
        }
        let domestic = table(
            ["法人営業・メンテナンスリース", "不動産", "事業投資・コンセッション", "環境エネルギー", "保険",
             "銀行・クレジット", "輸送機器"],
            [
                ("金融収益", ["68,600", "5,052", "15,243", "11,938", "141", "78,903", "3,853"]),
                ("サービス収入", ["111,288", "346,522", "87,063", "173,340", "－", "2,884", "21,971"]),
                ("セグメント収益（合計）",
                 ["487,842", "530,901", "441,953", "209,231", "643,045", "76,439", "130,016"]),
                ("セグメント費用（合計）",
                 ["398,791", "460,211", "398,448", "176,763", "540,154", "51,161", "88,888"]),
                ("セグメント利益",
                 ["100,740", "78,509", "125,611", "115,772", "102,891", "27,212", "66,608"]),
            ])
        let overseas = table(
            ["ORIX USA", "ORIX Europe", "アジア・豪州", "合計"],
            [
                ("金融収益", ["106,559", "3,360", "73,492", "367,141"]),
                ("サービス収入", ["71,030", "273,857", "24,421", "1,112,376"]),
                ("セグメント収益（合計）", ["272,219", "291,086", "243,414", "3,326,146"]),
                ("セグメント費用（合計）", ["259,993", "235,100", "207,244", "2,816,753"]),
                ("セグメント利益", ["954", "63,051", "51,249", "732,597"]),
            ])
        let merged = SegmentInfoLLMNormalizer.mergingSplitSegmentMatrices([domestic, overseas])
        #expect(merged[1].markdown.isEmpty)

        let (snapshotOrNil, _) = await SegmentInfoLLMNormalizer.normalize(
            ExtractedBreakdown(method: "html_table", tables: [domestic, overseas], facts: []),
            consolidatedSales: 3_330_831 * Financial.millionYen,
            decider: FakeRevenueRecognitionColumnDecider(),
            fiscalYearEnd: "2026-03-31", docID: "S-seg-golden")
        let snapshot = try #require(snapshotOrNil)
        let rows = Self.segmentRows(snapshot)
        #expect(rows.count == 10)
        #expect(rows["保険"] == 643_045 * Financial.millionYen)
        #expect(rows["ORIX USA"] == 272_219 * Financial.millionYen)
        #expect(rows["アジア・豪州"] == 243_414 * Financial.millionYen)
        let needsReview: Bool = snapshot.needsReview
        #expect(needsReview == false)
    }

    /// 丸数字の付いた売上行（①外部顧客に対する売上高）を売上行として拾う。
    /// 原本の第84期の表から資産等の行を除いた形。
    // source: code=6645 fy_end=2021-03-31 doc_id=S100LLFL page=132 field=product_service.IAB
    @Test func circledNumberSalesRowIsSalesMetric() async throws {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>IAB</td><td>EMC</td><td>SSB</td><td>HCB</td><td>計</td><td>消去調整他</td><td>連結</td></tr>
              <tr><td>Ⅰ　売上高及びセグメント損益</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
              <tr><td>①　外部顧客に対する売上高</td><td>346,446</td><td>86,028</td><td>95,663</td><td>123,087</td><td>651,224</td><td>4,305</td><td>655,529</td></tr>
              <tr><td>②　セグメント間の内部売上高</td><td>5,029</td><td>43,327</td><td>8,994</td><td>292</td><td>57,642</td><td>△57,642</td><td>－</td></tr>
              <tr><td>計</td><td>351,475</td><td>129,355</td><td>104,657</td><td>123,379</td><td>708,866</td><td>△53,337</td><td>655,529</td></tr>
              <tr><td>セグメント利益またはセグメント損失（△）</td><td>58,793</td><td>2,962</td><td>5,693</td><td>20,573</td><td>88,021</td><td>△25,541</td><td>62,480</td></tr>
            </table>
            """
        let (snapshotOrNil, _) = await Self.snapshot(html: html, sales: 655_529 * Financial.millionYen)
        let snapshot = try #require(snapshotOrNil)
        let rows = Self.segmentRows(snapshot)
        #expect(rows["IAB"] == 346_446 * Financial.millionYen)
        #expect(rows["HCB"] == 123_087 * Financial.millionYen)
        #expect(rows.count == 4)
        let needsReview: Bool = snapshot.needsReview
        #expect(needsReview == false)
    }

    /// 米国基準の積み上げ表。事業ごとに 外部顧客 / セグメント間 / 計 が並び、末尾の
    /// 全社（共通）及びセグメント間取引消去 △186,953 は「計」の和を連結合計へつなぐ。
    /// 外部顧客の行を採るときは、調整行を 連結合計 − 外部顧客の和 = 全社（共通）外部 11,034 にする。
    // source: code=6758 fy_end=2021-03-31 doc_id=S100LM4N page=207 field=segment.全社（共通）
    // source: code=6758 fy_end=2021-03-31 doc_id=S100LM4N page=207 field=segment.ゲーム＆ネットワークサービス
    @Test func stackedExternalBlocksRebaseCorporateAdjustment() async throws {
        let markdown = """
            |                         |           |           |
            |-------------------------|-----------|-----------|
            | 項目                      | 2019年度    | 2020年度    |
            | 項目                      | 金額（百万円）   | 金額（百万円）   |
            | 売上高及び営業収入：              |           |           |
            | ゲーム＆ネットワークサービス：         |           |           |
            | 外部顧客に対するもの              | 1,919,760 | 2,604,713 |
            | セグメント間取引                | 57,791    | 51,565    |
            | 計                       | 1,977,551 | 2,656,278 |
            | 音　楽：                    |           |           |
            | 外部顧客に対するもの              | 838,592   | 927,250   |
            | セグメント間取引                | 11,317    | 12,617    |
            | 計                       | 849,909   | 939,867   |
            | 映　画：                    |           |           |
            | 外部顧客に対するもの              | 1,010,714 | 757,580   |
            | セグメント間取引                | 1,140     | 1,187     |
            | 計                       | 1,011,854 | 758,767   |
            | エレクトロニクス・プロダクツ＆ソリューション： |           |           |
            | 外部顧客に対するもの              | 1,969,880 | 1,902,887 |
            | セグメント間取引                | 21,388    | 17,843    |
            | 計                       | 1,991,268 | 1,920,730 |
            | イメージング＆センシング・ソリューション：   |           |           |
            | 外部顧客に対するもの              | 985,259   | 937,859   |
            | セグメント間取引                | 85,317    | 74,638    |
            | 計                       | 1,070,576 | 1,012,497 |
            | 金　融：                    |           |           |
            | 外部顧客に対するもの              | 1,299,847 | 1,661,520 |
            | セグメント間取引                | 7,901     | 7,401     |
            | 計                       | 1,307,748 | 1,668,921 |
            | その他：                    |           |           |
            | 外部顧客に対するもの              | 214,999   | 196,517   |
            | セグメント間取引                | 36,421    | 32,736    |
            | 計                       | 251,420   | 229,253   |
            | 全社（共通）及びセグメント間取引消去      | △200,441  | △186,953  |
            | 連結合計                    | 8,259,885 | 8,999,360 |
            """
        let table = BreakdownTable(heading: "セグメント情報", markdown: markdown, period: "当期")
        let rebased = SegmentInfoLLMNormalizer.rebasingStackedExternalBlocks(table)
        let grid = BreakdownExtractor.markdownToGrid(rebased.markdown)
        let corporate = try #require(grid.first { $0.first?.contains("消去") == true })
        #expect(corporate.last == "11,034")
        #expect(grid.contains { $0.first == "ゲーム＆ネットワークサービス" && $0.last == "2,604,713" })
        #expect(!grid.contains { $0.first == "計" })

        let yen = Financial.millionYen
        let (snapshotOrNil, _) = await SegmentInfoLLMNormalizer.normalize(
            ExtractedBreakdown(method: "html_table", tables: [table], facts: []),
            consolidatedSales: 8_999_360 * yen,
            decider: FakeRevenueRecognitionColumnDecider(selected: "t0_c2"),
            fiscalYearEnd: "2021-03-31", docID: "S100LM4N-golden",
            publishedAxis: breakdownAxisSegment)
        let snapshot = try #require(snapshotOrNil)
        let rows = Self.segmentRows(snapshot)
        #expect(rows["ゲーム＆ネットワークサービス"] == 2_604_713 * yen)
        #expect(rows["金融"] == 1_661_520 * yen)
        #expect(rows["その他"] == 196_517 * yen)
        let reconciling = snapshot.rows.filter { $0.rowKind == "reconciling" }
        #expect(reconciling.map(\.amount) == [11_034 * yen])
        #expect(snapshot.denominator == 8_999_360 * yen)
    }
}
