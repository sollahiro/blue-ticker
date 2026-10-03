// SPEC_ORACLE: 収益分解表の構造検出。Jev 列選択の前に 4 段。
// (1) ラベル域は 1 または 2 列（rowspan/colspan 展開後）
// (2) 各行は category_group か category
// (3) 各行は subtotal か segment
// (4) 同じ全社合計で閉じる複数ブロックは並行次元（加算しない）
// ネットワークなし。macOS の #expect 型推論が倒れないよう、比較値は typed let に出す。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RevenueRecognitionTableStructureTests {
    /// デンソー S100Y9T1 0105100 前期表。2 列ラベル域。空 rowspan=6 の外側 +
    /// 内側カテゴリ、`自動車分野計` colspan=2 でグループを閉じる。
    static let densoHTML = """
        <table>
          <tr><td></td><td></td><td>(単位：百万円)</td></tr>
          <tr><td rowspan="6"></td><td>サーマルシステム</td><td>1,728,469</td></tr>
          <tr><td>パワトレインシステム</td><td>1,438,591</td></tr>
          <tr><td>モビリティエレクトロニクス</td><td>2,017,304</td></tr>
          <tr><td>エレクトリフィケーションシステム</td><td>1,354,426</td></tr>
          <tr><td>先進デバイス</td><td>388,803</td></tr>
          <tr><td>その他</td><td>113,659</td></tr>
          <tr><td colspan="2">自動車分野計</td><td>7,041,252</td></tr>
          <tr><td colspan="2">非車載事業分野</td><td>120,525</td></tr>
          <tr><td colspan="2">合計</td><td>7,161,777</td></tr>
        </table>
        """

    /// 東京エレクトロン S100YEOO 0105010。単一ラベル列。地理と製品が同じ全社合計。
    static let telHTML = """
        <table>
          <tr><td></td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
          <tr><td>地理的区分</td><td></td><td></td></tr>
          <tr><td>日本</td><td>189,979</td><td>239,427</td></tr>
          <tr><td>北米</td><td>242,964</td><td>166,446</td></tr>
          <tr><td>欧州</td><td>75,524</td><td>67,407</td></tr>
          <tr><td>韓国</td><td>409,009</td><td>543,858</td></tr>
          <tr><td>台湾</td><td>410,627</td><td>499,853</td></tr>
          <tr><td>中国</td><td>1,015,060</td><td>832,555</td></tr>
          <tr><td>その他</td><td>88,402</td><td>93,985</td></tr>
          <tr><td>外部顧客への売上高</td><td>2,431,568</td><td>2,443,533</td></tr>
          <tr><td></td><td></td><td></td></tr>
          <tr><td>製品及びサービス</td><td></td><td></td></tr>
          <tr><td>新規装置 (注)1</td><td>1,893,080</td><td>1,817,250</td></tr>
          <tr><td>フィールドソリューション他 (注)1</td><td>538,488</td><td>626,282</td></tr>
          <tr><td>外部顧客への売上高</td><td>2,431,568</td><td>2,443,533</td></tr>
        </table>
        """

    static func grid(_ html: String) throws -> [[String]] {
        BreakdownExtractor.expandTable(try XBRLTestSupport.parseFirstTable(html))
    }

    static func padded(_ html: String) throws -> [[String]] {
        RevenueRecognitionTableStructure.padded(try grid(html))
    }

    static func parsed(_ html: String) -> RevenueRecognitionCandidates.ParsedTable {
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係")
        return RevenueRecognitionCandidates.parse(tables: tables)[0]
    }

    static func amountKind(
        _ rows: [RevenueRecognitionTableStructure.ClassifiedRow],
        category: String? = nil,
        group: String? = nil
    ) -> RevenueRecognitionTableStructure.AmountKind? {
        rows.first { row in
            if let category { return row.category == category }
            if let group { return row.categoryGroup == group }
            return false
        }?.amountKind
    }

    @Suite struct Stage1LabelArea {
        @Test func telIsOneColumn() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.telHTML)
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            let columns: Int = area.columnCount
            #expect(columns == 1)
        }

        @Test func densoResolvesRowspanColspanToTwoColumns() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.densoHTML)
            let thermal = try #require(rows.first { $0.contains("サーマルシステム") })
            let thermalCount: Int = thermal.count
            let outer: String = RevenueRecognitionCandidates.compactCell(thermal[0])
            let inner: String = thermal[1]
            #expect(thermalCount >= 3)
            #expect(outer.isEmpty)
            #expect(inner == "サーマルシステム")
            let closer = try #require(rows.first { $0.contains("自動車分野計") })
            let closerOuter: String = closer[0]
            let closerInner: String = closer[1]
            #expect(closerOuter == "自動車分野計")
            #expect(closerInner == "自動車分野計")
            let columns: Int = RevenueRecognitionTableStructure.stage1LabelArea(rows).columnCount
            #expect(columns == 2)
        }

        @Test func threeLeadingLabelColumnsClampToTwo() throws {
            let html = """
                <table>
                  <tr><td></td><td></td><td></td><td>金額</td></tr>
                  <tr><td>外</td><td>中</td><td>内</td><td>10</td></tr>
                  <tr><td>外</td><td>中</td><td>別</td><td>20</td></tr>
                  <tr><td colspan="3">合計</td><td>30</td></tr>
                </table>
                """
            let rows = try RevenueRecognitionTableStructureTests.padded(html)
            let columns: Int = RevenueRecognitionTableStructure.stage1LabelArea(rows).columnCount
            #expect(columns == 2)
        }
    }

    @Suite struct Stage2CategoryGroupOrCategory {
        @Test func amountLessHeaderIsCategoryGroup() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.telHTML)
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            let labeled = RevenueRecognitionTableStructure.stage2ClassifyLabels(rows, area: area)
            let geo = try #require(labeled.first {
                $0.categoryGroup == "地理的区分" && $0.category == nil
            })
            let geoKind: RevenueRecognitionTableStructure.LabelKind? = geo.labelKind
            let geoHasAmount: Bool = geo.hasAmount
            #expect(geoKind == .categoryGroup)
            #expect(geoHasAmount == false)
            let product = try #require(labeled.first {
                $0.categoryGroup == "製品及びサービス" && $0.category == nil
            })
            let productKind: RevenueRecognitionTableStructure.LabelKind? = product.labelKind
            let productHasAmount: Bool = product.hasAmount
            #expect(productKind == .categoryGroup)
            #expect(productHasAmount == false)
        }

        @Test func oneColumnAmountRowInheritsLastHeaderAsGroup() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.telHTML)
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            let labeled = RevenueRecognitionTableStructure.stage2ClassifyLabels(rows, area: area)
            let japan = try #require(labeled.first { $0.category == "日本" })
            let japanKind: RevenueRecognitionTableStructure.LabelKind? = japan.labelKind
            let japanGroup: String? = japan.categoryGroup
            #expect(japanKind == .category)
            #expect(japanGroup == "地理的区分")
            let equipment = try #require(labeled.first { $0.category == "新規装置" })
            let equipmentKind: RevenueRecognitionTableStructure.LabelKind? = equipment.labelKind
            let equipmentGroup: String? = equipment.categoryGroup
            let equipmentHasAmount: Bool = equipment.hasAmount
            #expect(equipmentKind == .category)
            #expect(equipmentGroup == "製品及びサービス")
            #expect(equipmentHasAmount)
        }

        @Test func densoBlankOuterRowspanIsCategoryNotInheritedGroup() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.densoHTML)
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            let columns: Int = area.columnCount
            #expect(columns == 2)
            let labeled = RevenueRecognitionTableStructure.stage2ClassifyLabels(rows, area: area)
            let names: [String] = [
                "サーマルシステム", "パワトレインシステム", "モビリティエレクトロニクス",
                "エレクトリフィケーションシステム", "先進デバイス", "その他",
            ]
            for name in names {
                let row = try #require(labeled.first { $0.category == name })
                let kind: RevenueRecognitionTableStructure.LabelKind? = row.labelKind
                let group: String? = row.categoryGroup
                let hasAmount: Bool = row.hasAmount
                #expect(kind == .category)
                #expect(group == nil)
                #expect(hasAmount)
            }
        }

        @Test func densoColspanCloserAndGroupOnlyAreCategoryGroups() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.densoHTML)
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            let labeled = RevenueRecognitionTableStructure.stage2ClassifyLabels(rows, area: area)
            let closer = try #require(labeled.first { $0.categoryGroup == "自動車分野計" })
            let closerKind: RevenueRecognitionTableStructure.LabelKind? = closer.labelKind
            let closerCategory: String? = closer.category
            let closerHasAmount: Bool = closer.hasAmount
            #expect(closerKind == .categoryGroup)
            #expect(closerCategory == nil)
            #expect(closerHasAmount)
            let other = try #require(labeled.first { $0.categoryGroup == "非車載事業分野" })
            let otherKind: RevenueRecognitionTableStructure.LabelKind? = other.labelKind
            let otherCategory: String? = other.category
            #expect(otherKind == .categoryGroup)
            #expect(otherCategory == nil)
            let total = try #require(labeled.first { $0.categoryGroup == "合計" })
            let totalKind: RevenueRecognitionTableStructure.LabelKind? = total.labelKind
            #expect(totalKind == .categoryGroup)
        }

        @Test func twoColumnOuterTextIsGroupInnerIsCategory() throws {
            let html = """
                <table>
                  <tr><td></td><td></td><td>当期</td></tr>
                  <tr><td rowspan="2">製品及びサービス</td><td>新規装置</td><td>1,817,250</td></tr>
                  <tr><td>フィールドソリューション他</td><td>626,282</td></tr>
                  <tr><td colspan="2">合計</td><td>2,443,533</td></tr>
                </table>
                """
            let rows = try RevenueRecognitionTableStructureTests.padded(html)
            let columns: Int = RevenueRecognitionTableStructure.stage1LabelArea(rows).columnCount
            #expect(columns == 2)
            let labeled = RevenueRecognitionTableStructure.stage2ClassifyLabels(
                rows, area: RevenueRecognitionTableStructure.stage1LabelArea(rows))
            let equipment = try #require(labeled.first { $0.category == "新規装置" })
            let kind: RevenueRecognitionTableStructure.LabelKind? = equipment.labelKind
            let group: String? = equipment.categoryGroup
            #expect(kind == .category)
            #expect(group == "製品及びサービス")
        }
    }

    @Suite struct Stage3SubtotalOrSegment {
        @Test func subtotalVocabulary() {
            let groupCloser: Bool = RevenueRecognitionTableStructure.isSubtotalLabel("自動車分野計")
            let externalSales: Bool = RevenueRecognitionTableStructure.isSubtotalLabel("外部顧客への売上高")
            let externalRevenue: Bool = RevenueRecognitionTableStructure.isSubtotalLabel("外部顧客への収益")
            let total: Bool = RevenueRecognitionTableStructure.isSubtotalLabel("合計")
            let subtotal: Bool = RevenueRecognitionTableStructure.isSubtotalLabel("小計")
            let thermal: Bool = RevenueRecognitionTableStructure.isSubtotalLabel("サーマルシステム")
            let other: Bool = RevenueRecognitionTableStructure.isSubtotalLabel("非車載事業分野")
            let equipment: Bool = RevenueRecognitionTableStructure.isSubtotalLabel("新規装置")
            #expect(groupCloser)
            #expect(externalSales)
            #expect(externalRevenue)
            #expect(total)
            #expect(subtotal)
            #expect(thermal == false)
            #expect(other == false)
            #expect(equipment == false)
        }

        @Test func densoGroupCloserIsSubtotalCategoriesAreSegments() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.densoHTML)
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            let labeled = RevenueRecognitionTableStructure.stage2ClassifyLabels(rows, area: area)
            let classified = RevenueRecognitionTableStructure.stage3ClassifyAmounts(
                rows, labeled: labeled)
            let thermal = RevenueRecognitionTableStructureTests.amountKind(
                classified, category: "サーマルシステム")
            let closer = RevenueRecognitionTableStructureTests.amountKind(
                classified, group: "自動車分野計")
            let other = RevenueRecognitionTableStructureTests.amountKind(
                classified, group: "非車載事業分野")
            let total = RevenueRecognitionTableStructureTests.amountKind(
                classified, group: "合計")
            #expect(thermal == .segment)
            #expect(closer == .subtotal)
            #expect(other == .segment)
            #expect(total == .subtotal)
        }

        @Test func telExternalCustomerRowsAreSubtotals() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.telHTML)
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            let labeled = RevenueRecognitionTableStructure.stage2ClassifyLabels(rows, area: area)
            let classified = RevenueRecognitionTableStructure.stage3ClassifyAmounts(
                rows, labeled: labeled)
            let closers = classified.filter {
                ($0.category ?? $0.categoryGroup) == "外部顧客への売上高"
            }
            let closerCount: Int = closers.count
            let allSubtotals: Bool = closers.allSatisfy { $0.amountKind == .subtotal }
            let japan = RevenueRecognitionTableStructureTests.amountKind(classified, category: "日本")
            let equipment = RevenueRecognitionTableStructureTests.amountKind(
                classified, category: "新規装置")
            #expect(closerCount == 2)
            #expect(allSubtotals)
            #expect(japan == .segment)
            #expect(equipment == .segment)
        }
    }

    @Suite struct Stage4ParallelDimensions {
        @Test func telTwoBlocksEqualTableTotalAreParallelTakeBusiness() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.telHTML)
            let structure = RevenueRecognitionTableStructure.inspect(grid: rows)
            let labelColumns: Int = structure.labelColumnCount
            let blockCount: Int = structure.blocks.count
            let geoHeading: String? = structure.blocks[0].heading
            let geoKind: RevenueRecognitionTableStructure.DimensionKind = structure.blocks[0].kind
            let geoItems: Int = structure.blocks[0].itemRows.count
            let productHeading: String? = structure.blocks[1].heading
            let productKind: RevenueRecognitionTableStructure.DimensionKind =
                structure.blocks[1].kind
            let productItems: Int = structure.blocks[1].itemRows.count
            #expect(labelColumns == 1)
            #expect(blockCount == 2)
            #expect(geoHeading == "地理的区分")
            #expect(geoKind == .geography)
            #expect(geoItems == 7)
            #expect(productHeading == "製品及びサービス")
            #expect(productKind == .productOrBusiness)
            #expect(productItems == 2)
            let tableTotal: Double = 2_443_533
            let parallel = RevenueRecognitionTableStructure.stage4ParallelDimensions(
                in: structure, grid: rows, column: 2, tableTotal: tableTotal)
            let parallelCount: Int = parallel.count
            #expect(parallelCount == 2)
            let business = try #require(RevenueRecognitionTableStructure.businessBlock(in: parallel))
            let businessHeading: String? = business.heading
            #expect(businessHeading == "製品及びサービス")
            let table = RevenueRecognitionTableStructureTests.parsed(
                RevenueRecognitionTableStructureTests.telHTML)
            let unresolved: Bool = RevenueRecognitionCandidates.parallelDimensionsUnresolved(
                table: table, column: 2)
            #expect(unresolved == false)
        }

        @Test func densoGroupSubtotalIsNotTableTotalSoNotParallel() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.densoHTML)
            let structure = RevenueRecognitionTableStructure.inspect(grid: rows)
            let labelColumns: Int = structure.labelColumnCount
            #expect(labelColumns == 2)
            let tableTotal: Double = 7_161_777
            let parallel = RevenueRecognitionTableStructure.stage4ParallelDimensions(
                in: structure, grid: rows, column: 2, tableTotal: tableTotal)
            let empty: Bool = parallel.isEmpty
            #expect(empty)
        }

        @Test func sequentialGroupHeadersShareOneBlockUntilTableTotal() throws {
            let html = """
                <table>
                  <tr><td></td><td>金額</td></tr>
                  <tr><td>家電製品</td><td></td></tr>
                  <tr><td>ディスカウントストア</td><td>100</td></tr>
                  <tr><td>食品</td><td></td></tr>
                  <tr><td>スーパー</td><td>50</td></tr>
                  <tr><td>顧客との契約から生じる収益</td><td>150</td></tr>
                </table>
                """
            let rows = try RevenueRecognitionTableStructureTests.padded(html)
            let structure = RevenueRecognitionTableStructure.inspect(grid: rows)
            let labelColumns: Int = structure.labelColumnCount
            let blockCount: Int = structure.blocks.count
            let heading: String? = structure.blocks[0].heading
            let items: Int = structure.blocks[0].itemRows.count
            #expect(labelColumns == 1)
            #expect(blockCount == 1)
            #expect(heading == "家電製品")
            #expect(items == 2)
            let tableTotal: Double = 150
            let parallel = RevenueRecognitionTableStructure.stage4ParallelDimensions(
                in: structure, grid: rows, column: 1, tableTotal: tableTotal)
            let empty: Bool = parallel.isEmpty
            #expect(empty)
        }

        @Test func twoProductBlocksSameTotalAreUnresolvedNeedsReview() throws {
            let html = """
                <table>
                  <tr><td></td><td>当期</td></tr>
                  <tr><td>製品A</td><td></td></tr>
                  <tr><td>甲</td><td>60</td></tr>
                  <tr><td>乙</td><td>40</td></tr>
                  <tr><td>外部顧客への売上高</td><td>100</td></tr>
                  <tr><td>製品B</td><td></td></tr>
                  <tr><td>丙</td><td>55</td></tr>
                  <tr><td>丁</td><td>45</td></tr>
                  <tr><td>外部顧客への売上高</td><td>100</td></tr>
                </table>
                """
            let table = RevenueRecognitionTableStructureTests.parsed(html)
            let unresolved: Bool = RevenueRecognitionCandidates.parallelDimensionsUnresolved(
                table: table, column: 1)
            #expect(unresolved)
            let (rows, needsReview) = RevenueRecognitionCandidates.buildRows(table: table, column: 1)
            let empty: Bool = rows.isEmpty
            #expect(needsReview)
            #expect(empty)
        }

        @Test func geographyAndProductHeadingClassification() {
            let geo: Bool = RevenueRecognitionTableStructure.isGeographyHeading("地理的区分")
            let location: Bool = RevenueRecognitionTableStructure.isGeographyHeading("所在地別")
            let region: Bool = RevenueRecognitionTableStructure.isGeographyHeading("地域別")
            let product: Bool = RevenueRecognitionTableStructure.isProductOrBusinessHeading(
                "製品及びサービス")
            let business: Bool = RevenueRecognitionTableStructure.isProductOrBusinessHeading("事業")
            let productNotGeo: Bool = RevenueRecognitionTableStructure.isGeographyHeading(
                "製品及びサービス")
            let geoNotProduct: Bool = RevenueRecognitionTableStructure.isProductOrBusinessHeading(
                "地理的区分")
            #expect(geo)
            #expect(location)
            #expect(region)
            #expect(product)
            #expect(business)
            #expect(productNotGeo == false)
            #expect(geoNotProduct == false)
        }
    }
}
