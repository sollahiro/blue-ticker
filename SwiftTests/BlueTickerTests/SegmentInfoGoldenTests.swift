// SPEC_ORACLE: セグメント情報 html_table の類型。
// 1 事業別の報告セグメントはそのまま採る
// 2 地域別の報告セグメントで製品別もある → 製品を採り、地域は捨て、両方を足さない
// 3 地域別のみ → business は geography_only（地域は geography 軸。日本/アジアを business に載せない）
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

    /// 3b. 報告セグメントが日本/アジアで、製品別は90％省略 → business は geography_only。
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

    /// 3. 地域別のみ → business は geography_only（日本/海外を business に載せない）。
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
}
