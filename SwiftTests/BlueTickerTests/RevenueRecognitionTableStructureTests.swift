// SPEC_ORACLE: 収益分解表の構造検出。Jev 列選択の前に 4 段。
// (1) ラベル域は 1 または 2 列（rowspan/colspan 展開後）
// (2) 各行は category_group か category
// (3) 各行は subtotal か segment
// (4) 全てのブロックが同じ全社合計で閉じるときだけ並行次元（加算しない）
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
            let kei: Bool = RevenueRecognitionTableStructure.isSubtotalLabel("計")
            let thermal: Bool = RevenueRecognitionTableStructure.isSubtotalLabel("サーマルシステム")
            let other: Bool = RevenueRecognitionTableStructure.isSubtotalLabel("非車載事業分野")
            let equipment: Bool = RevenueRecognitionTableStructure.isSubtotalLabel("新規装置")
            let otherRevenue: Bool = RevenueRecognitionTableStructure.isSubtotalLabel("その他収益")
            #expect(groupCloser)
            #expect(externalSales)
            #expect(externalRevenue)
            #expect(total)
            #expect(subtotal)
            #expect(kei)
            #expect(thermal == false)
            #expect(other == false)
            #expect(equipment == false)
            #expect(otherRevenue)
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
            let business = try #require(
                RevenueRecognitionTableStructure.businessBlock(
                    in: parallel, rows: structure.rows))
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
            let kind: Bool = RevenueRecognitionTableStructure.isProductOrBusinessHeading("品種別")
            let itemKind: Bool = RevenueRecognitionTableStructure.isProductOrBusinessHeading("品目別")
            let productNotGeo: Bool = RevenueRecognitionTableStructure.isGeographyHeading(
                "製品及びサービス")
            let geoNotProduct: Bool = RevenueRecognitionTableStructure.isProductOrBusinessHeading(
                "地理的区分")
            #expect(geo)
            #expect(location)
            #expect(region)
            #expect(product)
            #expect(business)
            #expect(kind)
            #expect(itemKind)
            #expect(productNotGeo == false)
            #expect(geoNotProduct == false)
        }

        @Test func otherRevenueCloserDoesNotMakeSubsetParallel() throws {
            let html = """
                <table>
                  <tr><td></td><td>当期</td></tr>
                  <tr><td>サイバートレーニングソリューション</td><td>389,248</td></tr>
                  <tr><td>セキュリティ診断・調査ソリューション</td><td>438,605</td></tr>
                  <tr><td>セキュリティコンサルティングソリューション</td><td>537,970</td></tr>
                  <tr><td>その他</td><td>－</td></tr>
                  <tr><td>顧客との契約から生じる収益</td><td>1,365,823</td></tr>
                  <tr><td>その他収益</td><td>－</td></tr>
                  <tr><td>外部顧客への売上高</td><td>1,365,823</td></tr>
                </table>
                """
            let rows = try RevenueRecognitionTableStructureTests.padded(html)
            let structure = RevenueRecognitionTableStructure.inspect(grid: rows)
            let tableTotal: Double = 1_365_823
            let parallel = RevenueRecognitionTableStructure.stage4ParallelDimensions(
                in: structure, grid: rows, column: 1, tableTotal: tableTotal)
            let empty: Bool = parallel.isEmpty
            let otherIsTotal: Bool = RevenueRecognitionCandidates.isTotalLabel("その他収益")
            let otherProductIsTotal: Bool = RevenueRecognitionCandidates.isTotalLabel("その他")
            let blockCount: Int = structure.blocks.count
            #expect(empty)
            #expect(otherIsTotal)
            #expect(otherProductIsTotal == false)
            #expect(blockCount == 1)
        }

        @Test func dashOnlySecondBlockIsNotADimension() throws {
            let html = """
                <table>
                  <tr><td></td><td>当期</td></tr>
                  <tr><td>製品A</td><td>60</td></tr>
                  <tr><td>製品B</td><td>40</td></tr>
                  <tr><td>顧客との契約から生じる収益</td><td>100</td></tr>
                  <tr><td>空の次元</td><td></td></tr>
                  <tr><td>幽霊</td><td>－</td></tr>
                  <tr><td>外部顧客への売上高</td><td>100</td></tr>
                </table>
                """
            let rows = try RevenueRecognitionTableStructureTests.padded(html)
            let structure = RevenueRecognitionTableStructure.inspect(grid: rows)
            let parallel = RevenueRecognitionTableStructure.stage4ParallelDimensions(
                in: structure, grid: rows, column: 1, tableTotal: 100)
            let empty: Bool = parallel.isEmpty
            #expect(empty)
        }

        @Test func timingItemLabelsAreNotTheProductBlock() throws {
            let html = """
                <table>
                  <tr><td colspan="2">セグメント</td><td>合計</td></tr>
                  <tr><td colspan="2">主要な財又はサービスのライン</td><td></td></tr>
                  <tr><td></td><td>メカトロ製品</td><td>66,453</td></tr>
                  <tr><td></td><td>サプライ製品</td><td>96,981</td></tr>
                  <tr><td></td><td>計</td><td>163,434</td></tr>
                  <tr><td colspan="2">収益認識の時期</td><td></td></tr>
                  <tr><td></td><td>一時点で移転される財又はサービス</td><td>153,316</td></tr>
                  <tr><td></td><td>一定の期間にわたり移転される財又はサービス</td><td>10,118</td></tr>
                  <tr><td></td><td>計</td><td>163,434</td></tr>
                  <tr><td colspan="2">外部顧客への売上高</td><td>163,434</td></tr>
                </table>
                """
            let rows = try RevenueRecognitionTableStructureTests.padded(html)
            let structure = RevenueRecognitionTableStructure.inspect(grid: rows)
            let parallel = RevenueRecognitionTableStructure.stage4ParallelDimensions(
                in: structure, grid: rows, column: 2, tableTotal: 163_434)
            let parallelCount: Int = parallel.count
            #expect(parallelCount >= 2)
            let chosen = try #require(
                RevenueRecognitionTableStructure.businessBlock(
                    in: parallel, rows: structure.rows))
            let labels = RevenueRecognitionTableStructure.itemLabels(
                of: chosen, rows: structure.rows)
            let hasMechatro: Bool = labels.contains("メカトロ製品")
            let hasTiming: Bool = labels.contains(where: {
                RevenueRecognitionTableStructure.isTimingAxisLabel($0)
            })
            let unresolved: Bool = RevenueRecognitionCandidates.parallelDimensionsUnresolved(
                table: RevenueRecognitionTableStructureTests.parsed(html), column: 2)
            #expect(hasMechatro)
            #expect(hasTiming == false)
            #expect(unresolved == false)
        }

        @Test func productOmissionProseIsNotAProductAxisLabel() {
            let omitted: Bool = RevenueRecognitionTableStructure.isDisclosureOmissionProse(
                "単一の製品・サービスの区分の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。")
            let axis: Bool = RevenueRecognitionTableStructure.isProductAxisLabel(
                "単一の製品・サービスの区分の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。")
            let heading: Bool = RevenueRecognitionTableStructure.isProductOrBusinessHeading(
                "製品及びサービスごとの情報")
            #expect(omitted)
            #expect(axis == false)
            #expect(heading)
        }

        @Test func geographicReportingSegmentColumnsAreGeographyAxis() {
            let html = """
                <table>
                  <tr><td></td><td>報告セグメント</td><td>報告セグメント</td><td>報告セグメント</td><td>調整額</td><td>連結財務諸表計上額</td></tr>
                  <tr><td></td><td>日本</td><td>アジア</td><td>計</td><td></td><td></td></tr>
                  <tr><td>外部顧客に対する売上高</td><td>4,334</td><td>1,141</td><td>5,475</td><td>-</td><td>5,475</td></tr>
                </table>
                """
            let parsed = RevenueRecognitionTableStructureTests.parsed(html)
            let axis: RevenueRecognitionTableStructure.TableAxis =
                RevenueRecognitionTableStructure.tableAxis(of: parsed)
            let constraint: RevenueRecognitionTableStructure.AxisConstraint =
                RevenueRecognitionTableStructure.axisConstraint(tables: [parsed])
            #expect(axis == .geography)
            #expect(constraint == .geographyOnly)
        }

        @Test func productRowsByGeographyColumnsStayProductAxis() {
            let html = """
                <table>
                  <tr>
                    <td></td>
                    <td>日本</td><td>米国</td><td>アジア</td><td>欧州</td><td>合計</td>
                  </tr>
                  <tr>
                    <td>
                      <p>製品及びサービス別</p>
                      <p>ロボット</p>
                      <p>特注機</p>
                      <p>部品・保守サービス</p>
                    </td>
                    <td>
                      <p></p>
                      <p>7,445,494</p>
                      <p>1,482,554</p>
                      <p>2,124,545</p>
                    </td>
                    <td>
                      <p></p>
                      <p>2,236,732</p>
                      <p>758,274</p>
                      <p>1,084,411</p>
                    </td>
                    <td>
                      <p></p>
                      <p>4,111,695</p>
                      <p>202,153</p>
                      <p>962,796</p>
                    </td>
                    <td>
                      <p></p>
                      <p>1,153,399</p>
                      <p>718,954</p>
                      <p>820,362</p>
                    </td>
                    <td>
                      <p></p>
                      <p>14,947,321</p>
                      <p>3,161,936</p>
                      <p>4,992,115</p>
                    </td>
                  </tr>
                  <tr><td>顧客との契約から生じる収益</td><td>11,052,594</td><td>4,079,418</td><td>5,276,645</td><td>2,692,715</td><td>23,101,373</td></tr>
                </table>
                """
            let parsed = RevenueRecognitionTableStructureTests.parsed(html)
            let axis: RevenueRecognitionTableStructure.TableAxis =
                RevenueRecognitionTableStructure.tableAxis(of: parsed)
            let constraint: RevenueRecognitionTableStructure.AxisConstraint =
                RevenueRecognitionTableStructure.axisConstraint(tables: [parsed])
            let expectedAxis: RevenueRecognitionTableStructure.TableAxis = .productOrBusiness
            let expectedConstraint: RevenueRecognitionTableStructure.AxisConstraint = .productOnly
            #expect(axis == expectedAxis)
            #expect(constraint == expectedConstraint)
        }

        @Test func timingLabelWinsOverServiceKeyword() {
            let timing: Bool = RevenueRecognitionTableStructure.isTimingAxisLabel(
                "一時点で移転される財又はサービス")
            let product: Bool = RevenueRecognitionTableStructure.isProductAxisLabel(
                "一時点で移転される財又はサービス")
            let heading: Bool = RevenueRecognitionTableStructure.isProductOrBusinessHeading(
                "一時点で移転される財又はサービス")
            #expect(timing)
            #expect(product == false)
            #expect(heading == false)
        }

        @Test func salesChannelHeaderIsCustomerAxis() {
            let header: Bool = RevenueRecognitionTableStructure.isCustomerAxisLabel("主たる販売経路")
            let channel: Bool = RevenueRecognitionTableStructure.isCustomerAxisLabel("販売チャネル")
            let destination: Bool = RevenueRecognitionTableStructure.isCustomerAxisLabel("販売先")
            let productSale: Bool = RevenueRecognitionTableStructure.isCustomerAxisLabel("ソフトウェア販売")
            #expect(header)
            #expect(channel)
            #expect(destination)
            #expect(productSale == false)
            let html = """
                <table>
                  <tr><td>主たる販売経路</td><td>金額（千円）</td></tr>
                  <tr><td>生活協同組合</td><td>2,471,069</td></tr>
                  <tr><td>自動販売機オペレーター</td><td>1,844,578</td></tr>
                  <tr><td>量販店</td><td>980,838</td></tr>
                  <tr><td>卸問屋</td><td>648,023</td></tr>
                  <tr><td>その他</td><td>1,379,243</td></tr>
                  <tr><td>合計</td><td>7,323,751</td></tr>
                </table>
                """
            let parsed = RevenueRecognitionTableStructureTests.parsed(html)
            let axis: RevenueRecognitionTableStructure.TableAxis =
                RevenueRecognitionTableStructure.tableAxis(of: parsed)
            let constraint: RevenueRecognitionTableStructure.AxisConstraint =
                RevenueRecognitionTableStructure.axisConstraint(tables: [parsed])
            #expect(axis == .customer)
            #expect(constraint == .customerOrTimingOnly)
        }

        @Test func governmentAndPrivateLabelsAreCustomerAxis() {
            let ministry: Bool = RevenueRecognitionTableStructure.isCustomerAxisLabel("中央省庁")
            let local: Bool = RevenueRecognitionTableStructure.isCustomerAxisLabel("地方自治体")
            let privateOther: Bool = RevenueRecognitionTableStructure.isCustomerAxisLabel("民間その他")
            let publicSector: Bool = RevenueRecognitionTableStructure.isCustomerAxisLabel("官公庁")
            let government: Bool = RevenueRecognitionTableStructure.isCustomerAxisLabel("政府")
            let civic: Bool = RevenueRecognitionTableStructure.isCustomerAxisLabel("公共")
            let product: Bool = RevenueRecognitionTableStructure.isCustomerAxisLabel("ソフトウェア販売")
            #expect(ministry)
            #expect(local)
            #expect(privateOther)
            #expect(publicSector)
            #expect(government)
            #expect(civic)
            #expect(product == false)
        }

        @Test func destinationAndAsiaExChinaAreGeographyOnly() {
            let heading: Bool = RevenueRecognitionTableStructure.isGeographyHeading("仕向地別売上高")
            let asia: Bool = RevenueRecognitionTableStructure.isBareGeographyLabel("アジア(中国を除く)")
            let kikkoman: Bool = RevenueRecognitionTableStructure.isBareGeographyLabel(
                "国内食料品製造・販売")
            let leftover: String = RevenueRecognitionTableStructure.geographyLeftoverStem(
                "アジア(中国を除く)")
            #expect(heading)
            #expect(asia)
            #expect(kikkoman == false)
            #expect(leftover.isEmpty)
            let html = """
                <table>
                  <tr><td></td><td>大型・中型車</td><td>小型車他</td><td>合計</td></tr>
                  <tr><td>国内</td><td>332,066</td><td>116,163</td><td>878,486</td></tr>
                  <tr><td>海外</td><td>394,775</td><td>1,479,463</td><td>2,205,383</td></tr>
                </table>
                """
            let parsed = RevenueRecognitionTableStructureTests.parsed(html)
            let axis: RevenueRecognitionTableStructure.TableAxis =
                RevenueRecognitionTableStructure.tableAxis(of: parsed)
            let constraint: RevenueRecognitionTableStructure.AxisConstraint =
                RevenueRecognitionTableStructure.axisConstraint(tables: [parsed])
            #expect(axis == .geography)
            #expect(constraint == .geographyOnly)
        }

        @Test func customerIndustryAndGyohanAreCustomerAxis() {
            let finance: Bool = RevenueRecognitionTableStructure.isCustomerAxisLabel(
                "金融(銀行・証券・保険等)")
            let telecom: Bool = RevenueRecognitionTableStructure.isCustomerAxisLabel(
                "情報通信・メディア・ハイテク")
            let gyohan: Bool = RevenueRecognitionTableStructure.isCustomerAxisLabel("業販")
            let guarantee: Bool = RevenueRecognitionTableStructure.isCustomerAxisLabel(
                "金融法人向け保証サービス")
            #expect(finance)
            #expect(telecom)
            #expect(gyohan)
            #expect(guarantee == false)
        }

        @Test func mixedProductAndCustomerOnSameTableIsCustomer() {
            let html = """
                <table>
                  <tr><td></td><td>金額</td></tr>
                  <tr><td>ソフトウェア製品</td><td>100</td></tr>
                  <tr><td>業販</td><td>20</td></tr>
                  <tr><td>合計</td><td>120</td></tr>
                </table>
                """
            let parsed = RevenueRecognitionTableStructureTests.parsed(html)
            let axis: RevenueRecognitionTableStructure.TableAxis =
                RevenueRecognitionTableStructure.tableAxis(of: parsed)
            #expect(axis == .customer)
        }

        @Test func wholesaleAndRetailPairIsCustomerAxis() {
            let html = """
                <table>
                  <tr><td></td><td>金額</td></tr>
                  <tr><td>電力小売</td><td>93,890</td></tr>
                  <tr><td>電力卸売</td><td>133,308</td></tr>
                  <tr><td>その他</td><td>3,302</td></tr>
                  <tr><td>合計</td><td>230,500</td></tr>
                </table>
                """
            let parsed = RevenueRecognitionTableStructureTests.parsed(html)
            let axis: RevenueRecognitionTableStructure.TableAxis =
                RevenueRecognitionTableStructure.tableAxis(of: parsed)
            #expect(axis == .customer)
        }
    }
}
