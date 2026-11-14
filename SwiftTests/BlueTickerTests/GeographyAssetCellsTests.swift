// geography 行のセル assets（地域ごとの有形固定資産／非流動資産）の決定論読み取り。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct GeographyAssetCellsTests {
    private func row(_ label: String, _ amount: Double) -> BreakdownRowPayload {
        BreakdownRowPayload(labelRaw: label, label: label, amount: amount, profit: nil, rowKind: "segment")
    }

    private func geographyPayload(_ labels: [String]) -> BreakdownSnapshotPayload {
        BreakdownSnapshotPayload(
            axis: breakdownAxisGeography, denominator: 1_000, denominatorTag: "income_statement.sales",
            rows: labels.map { row($0, 100) }, sourceKind: breakdownSourceGeographyLLM,
            needsReview: false, warnings: [])
    }

    /// 日本基準「(2) 有形固定資産」の横の表。期間は TextBlock の contextRef。
    @Test func japaneseGaapHorizontalTable() throws {
        let html = """
            <p>(1) 売上高</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td>日本</td><td>北米</td><td>アジア</td><td>合計</td></tr>
              <tr><td>500</td><td>300</td><td>200</td><td>1,000</td></tr>
            </table>
            <p>(2) 有形固定資産</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>日本</td><td>北米</td><td>アジア</td><td>合計</td></tr>
              <tr><td></td><td>120</td><td>50</td><td>30</td><td>200</td></tr>
            </table>
            """
        let tables = GeographyAssetCells.candidates(html: html, contextPeriod: "当期", fiscalYearEnd: nil)
        let table = try #require(GeographyAssetCells.select(tables))
        #expect(table.metric == geographyAssetsMetricPropertyPlantEquipment)
        #expect(table.parsed.total == 200_000_000)
        #expect(table.parsed.entries.map(\.label) == ["日本", "北米", "アジア"])
        #expect(table.parsed.entries.first?.value == 120_000_000)

        let payload = GeographyAssetCells.attach(table, to: geographyPayload(["日本", "北米", "アジア"]))
        #expect(payload.assets?.denominator == 200_000_000)
        #expect(payload.assets?.denominatorTag == GeographyAssetCells.denominatorTagTableTotal)
        #expect(payload.assetsMetric == geographyAssetsMetricPropertyPlantEquipment)
        #expect(payload.rows.map(\.assets) == [120_000_000, 50_000_000, 30_000_000])
        #expect(payload.warnings.isEmpty)
        let json = payload.jsonObject()
        #expect((json[geographyCellAssets] as? [String: Any])?["denominator"] as? Double == 200_000_000)
        #expect(json[geographyAssetsMetricKey] as? String == geographyAssetsMetricPropertyPlantEquipment)
        let rows = try #require(json["rows"] as? [[String: Any]])
        #expect(rows.first?[geographyCellAssets] as? Double == 120_000_000)
    }

    /// 売上と有形固定資産を1表に並べた型（S100YG81）。資産行だけ読み、「－」は 0。
    @Test func assetRowInSalesTable() throws {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>日本</td><td>米州</td><td>欧州</td><td>直接輸出</td><td>連結</td></tr>
              <tr><td>外部顧客に対する売上高</td><td>348,638</td><td>73,283</td><td>116,770</td><td>2,490</td><td>541,181</td></tr>
              <tr><td>有形固定資産</td><td>75,657</td><td>2,485</td><td>4,004</td><td>－</td><td>82,146</td></tr>
            </table>
            """
        let tables = GeographyAssetCells.candidates(html: html, contextPeriod: "当期", fiscalYearEnd: nil)
        let table = try #require(GeographyAssetCells.select(tables))
        #expect(table.metric == geographyAssetsMetricPropertyPlantEquipment)
        #expect(table.parsed.total == 82_146_000_000)
        #expect(table.parsed.entries.map(\.value) == [75_657_000_000, 2_485_000_000, 4_004_000_000, 0])
    }

    /// IFRS「非流動資産」の縦の表。前期・当期の2列から当期の列を取る。
    @Test func ifrsVerticalTablePicksCurrentColumn() throws {
        let html = """
            <p>② 非流動資産</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>日本</td><td>1,000</td><td>1,100</td></tr>
              <tr><td>米国</td><td>400</td><td>500</td></tr>
              <tr><td>その他</td><td>100</td><td>150</td></tr>
              <tr><td>合計</td><td>1,500</td><td>1,750</td></tr>
            </table>
            """
        let tables = GeographyAssetCells.candidates(html: html, contextPeriod: nil, fiscalYearEnd: nil)
        let table = try #require(GeographyAssetCells.select(tables))
        #expect(table.metric == geographyAssetsMetricNoncurrentAssets)
        #expect(table.parsed.pickedCurrentColumn)
        #expect(table.parsed.total == 1_750_000_000)
        #expect(table.parsed.entries.map(\.value) == [1_100_000_000, 500_000_000, 150_000_000])
    }

    /// 地域の和が合計と合わない表、単位の無い表は読まない。
    @Test func mismatchedTotalOrMissingUnitIsRejected() {
        let mismatched = """
            <p>(2) 有形固定資産</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>日本</td><td>北米</td><td>合計</td></tr>
              <tr><td></td><td>120</td><td>50</td><td>400</td></tr>
            </table>
            """
        #expect(GeographyAssetCells.candidates(html: mismatched, contextPeriod: "当期", fiscalYearEnd: nil).isEmpty)
        let noUnit = """
            <p>(2) 有形固定資産</p>
            <table>
              <tr><td></td><td>日本</td><td>北米</td><td>合計</td></tr>
              <tr><td></td><td>120</td><td>50</td><td>170</td></tr>
            </table>
            """
        #expect(GeographyAssetCells.candidates(html: noUnit, contextPeriod: "当期", fiscalYearEnd: nil).isEmpty)
    }

    /// 小計（海外計）は和が合うときだけ落とす。
    @Test func subtotalIsDroppedWhenSumMatches() throws {
        let grid = [
            ["", "日本", "北米", "アジア", "海外計", "合計"],
            ["", "100", "60", "40", "100", "200"],
        ]
        let parsed = try #require(GeographyAssetCells.parseWhole(grid: grid, unit: 1_000_000))
        #expect(parsed.entries.map(\.label) == ["日本", "北米", "アジア"])
    }

    /// 増加額・減損の表は残高ではないので指標にしない。
    @Test func nonBalanceCaptionIsNotAMetric() {
        #expect(GeographyAssetCells.assetMetric("有形固定資産及び無形固定資産の増加額") == nil)
        #expect(GeographyAssetCells.assetMetric("(2) 有形固定資産") == geographyAssetsMetricPropertyPlantEquipment)
    }

    /// 当期の表が2つ（中身が違う）なら決めない。期間の分からない表が2つでも決めない。
    @Test func selectRequiresSingleCurrentTable() {
        let a = GeographyAssetCells.Table(
            metric: geographyAssetsMetricPropertyPlantEquipment,
            parsed: .init(entries: [.init(label: "日本", value: 1), .init(label: "米国", value: 2)], total: 3,
                          pickedCurrentColumn: false),
            period: "当期")
        var b = a
        b.parsed.total = 4
        #expect(GeographyAssetCells.select([a, b]) == nil)
        #expect(GeographyAssetCells.select([a, a]) == a)
        var unknown = a
        unknown.period = nil
        #expect(GeographyAssetCells.select([unknown]) == unknown)
        var otherUnknown = unknown
        otherUnknown.parsed.total = 5
        #expect(GeographyAssetCells.select([unknown, otherUnknown]) == nil)
        var prior = a
        prior.period = "前期"
        #expect(GeographyAssetCells.select([prior, a]) == a)
    }

    /// geography 行に無い地域は捨てて警告。1つも合わなければ付けない。
    @Test func attachWarnsOnUnmatchedRegions() {
        let table = GeographyAssetCells.Table(
            metric: geographyAssetsMetricPropertyPlantEquipment,
            parsed: .init(entries: [.init(label: "日本(注1)", value: 10), .init(label: "欧州", value: 5)], total: nil,
                          pickedCurrentColumn: false),
            period: "当期")
        let payload = GeographyAssetCells.attach(table, to: geographyPayload(["日本", "北米"]))
        #expect(payload.rows.map(\.assets) == [10, nil])
        #expect(payload.warnings == [GeographyAssetCells.warningUnmatchedRows])
        #expect(payload.assets?.denominator == 15)
        #expect(payload.assets?.denominatorTag == GeographyAssetCells.denominatorTagRowSum)
        let none = GeographyAssetCells.attach(table, to: geographyPayload(["中国"]))
        #expect(none.assets == nil)
        #expect(none.jsonObject()[geographyCellAssets] == nil)
    }
}
