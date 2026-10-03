// SPEC_ORACLE: 収益分解表の構造検出。Jev 列選択の前に 4 段。
// (1) ラベル域は 1 または 2 列（rowspan/colspan 展開後）
// (2) 各行は category_group か category
// (3) 各行は subtotal か segment
// (4) 同じ全社合計で閉じる複数ブロックは並行次元（加算しない）
// ネットワークなし。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RevenueRecognitionTableStructureTests {
    // MARK: - fixtures (DENSO S100Y9T1 / TEL S100YEOO)

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

    // MARK: - (1) label area is 1 or 2 columns

    @Suite struct Stage1LabelArea {
        @Test func telIsOneColumn() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.telHTML)
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            #expect(area.columnCount == 1)
        }

        @Test func densoResolvesRowspanColspanToTwoColumns() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.densoHTML)
            let thermal = try #require(rows.first { $0.contains("サーマルシステム") })
            #expect(thermal.count >= 3)
            #expect(RevenueRecognitionCandidates.compactCell(thermal[0]).isEmpty)
            #expect(thermal[1] == "サーマルシステム")
            let closer = try #require(rows.first { $0.contains("自動車分野計") })
            #expect(closer[0] == "自動車分野計")
            #expect(closer[1] == "自動車分野計")
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            #expect(area.columnCount == 2)
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
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            #expect(area.columnCount == 2)
        }
    }

    // MARK: - (2) each row is category_group or category

    @Suite struct Stage2CategoryGroupOrCategory {
        @Test func amountLessHeaderIsCategoryGroup() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.telHTML)
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            let labeled = RevenueRecognitionTableStructure.stage2ClassifyLabels(rows, area: area)
            let geo = try #require(labeled.first {
                $0.categoryGroup == "地理的区分" && $0.category == nil
            })
            #expect(geo.labelKind == .categoryGroup)
            #expect(!geo.hasAmount)
            let product = try #require(labeled.first {
                $0.categoryGroup == "製品及びサービス" && $0.category == nil
            })
            #expect(product.labelKind == .categoryGroup)
            #expect(!product.hasAmount)
        }

        @Test func oneColumnAmountRowInheritsLastHeaderAsGroup() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.telHTML)
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            let labeled = RevenueRecognitionTableStructure.stage2ClassifyLabels(rows, area: area)
            let japan = try #require(labeled.first { $0.category == "日本" })
            #expect(japan.labelKind == .category)
            #expect(japan.categoryGroup == "地理的区分")
            let equipment = try #require(labeled.first { $0.category == "新規装置" })
            #expect(equipment.labelKind == .category)
            #expect(equipment.categoryGroup == "製品及びサービス")
            #expect(equipment.hasAmount)
        }

        @Test func densoBlankOuterRowspanIsCategoryNotInheritedGroup() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.densoHTML)
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            #expect(area.columnCount == 2)
            let labeled = RevenueRecognitionTableStructure.stage2ClassifyLabels(rows, area: area)
            let names = [
                "サーマルシステム", "パワトレインシステム", "モビリティエレクトロニクス",
                "エレクトリフィケーションシステム", "先進デバイス", "その他",
            ]
            for name in names {
                let row = try #require(labeled.first { $0.category == name })
                #expect(row.labelKind == .category)
                #expect(row.categoryGroup == nil)
                #expect(row.hasAmount)
            }
        }

        @Test func densoColspanCloserAndGroupOnlyAreCategoryGroups() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.densoHTML)
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            let labeled = RevenueRecognitionTableStructure.stage2ClassifyLabels(rows, area: area)
            let closer = try #require(labeled.first { $0.categoryGroup == "自動車分野計" })
            #expect(closer.labelKind == .categoryGroup)
            #expect(closer.category == nil)
            #expect(closer.hasAmount)
            let other = try #require(labeled.first { $0.categoryGroup == "非車載事業分野" })
            #expect(other.labelKind == .categoryGroup)
            #expect(other.category == nil)
            let total = try #require(labeled.first { $0.categoryGroup == "合計" })
            #expect(total.labelKind == .categoryGroup)
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
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            #expect(area.columnCount == 2)
            let labeled = RevenueRecognitionTableStructure.stage2ClassifyLabels(rows, area: area)
            let equipment = try #require(labeled.first { $0.category == "新規装置" })
            #expect(equipment.labelKind == .category)
            #expect(equipment.categoryGroup == "製品及びサービス")
        }
    }

    // MARK: - (3) each row is subtotal or segment

    @Suite struct Stage3SubtotalOrSegment {
        @Test func subtotalVocabulary() {
            #expect(RevenueRecognitionTableStructure.isSubtotalLabel("自動車分野計"))
            #expect(RevenueRecognitionTableStructure.isSubtotalLabel("外部顧客への売上高"))
            #expect(RevenueRecognitionTableStructure.isSubtotalLabel("外部顧客への収益"))
            #expect(RevenueRecognitionTableStructure.isSubtotalLabel("合計"))
            #expect(RevenueRecognitionTableStructure.isSubtotalLabel("小計"))
            #expect(!RevenueRecognitionTableStructure.isSubtotalLabel("サーマルシステム"))
            #expect(!RevenueRecognitionTableStructure.isSubtotalLabel("非車載事業分野"))
            #expect(!RevenueRecognitionTableStructure.isSubtotalLabel("新規装置"))
        }

        @Test func densoGroupCloserIsSubtotalCategoriesAreSegments() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.densoHTML)
            let area = RevenueRecognitionTableStructure.stage1LabelArea(rows)
            let labeled = RevenueRecognitionTableStructure.stage2ClassifyLabels(rows, area: area)
            let classified = RevenueRecognitionTableStructure.stage3ClassifyAmounts(
                rows, labeled: labeled)
            #expect(classified.first { $0.category == "サーマルシステム" }?.amountKind == .segment)
            #expect(
                classified.first { $0.categoryGroup == "自動車分野計" }?.amountKind == .subtotal)
            #expect(
                classified.first { $0.categoryGroup == "非車載事業分野" }?.amountKind == .segment)
            #expect(classified.first { $0.categoryGroup == "合計" }?.amountKind == .subtotal)
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
            #expect(closers.count == 2)
            #expect(closers.allSatisfy { $0.amountKind == .subtotal })
            #expect(classified.first { $0.category == "日本" }?.amountKind == .segment)
            #expect(classified.first { $0.category == "新規装置" }?.amountKind == .segment)
        }
    }

    // MARK: - (4) parallel dimensions: never sum; business only; else needs_review

    @Suite struct Stage4ParallelDimensions {
        @Test func telTwoBlocksEqualTableTotalAreParallelTakeBusiness() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.telHTML)
            let structure = RevenueRecognitionTableStructure.inspect(grid: rows)
            #expect(structure.labelColumnCount == 1)
            #expect(structure.blocks.count == 2)
            #expect(structure.blocks[0].heading == "地理的区分")
            #expect(structure.blocks[0].kind == .geography)
            #expect(structure.blocks[0].itemRows.count == 7)
            #expect(structure.blocks[1].heading == "製品及びサービス")
            #expect(structure.blocks[1].kind == .productOrBusiness)
            #expect(structure.blocks[1].itemRows.count == 2)
            let parallel = RevenueRecognitionTableStructure.stage4ParallelDimensions(
                in: structure, grid: rows, column: 2, tableTotal: 2_443_533)
            #expect(parallel.count == 2)
            let business = try #require(RevenueRecognitionTableStructure.businessBlock(in: parallel))
            #expect(business.heading == "製品及びサービス")
            #expect(
                !RevenueRecognitionCandidates.parallelDimensionsUnresolved(
                    table: RevenueRecognitionTableStructureTests.parsed(
                        RevenueRecognitionTableStructureTests.telHTML),
                    column: 2))
        }

        @Test func densoGroupSubtotalIsNotTableTotalSoNotParallel() throws {
            let rows = try RevenueRecognitionTableStructureTests.padded(
                RevenueRecognitionTableStructureTests.densoHTML)
            let structure = RevenueRecognitionTableStructure.inspect(grid: rows)
            #expect(structure.labelColumnCount == 2)
            let parallel = RevenueRecognitionTableStructure.stage4ParallelDimensions(
                in: structure, grid: rows, column: 2, tableTotal: 7_161_777)
            #expect(parallel.isEmpty)
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
            #expect(structure.labelColumnCount == 1)
            #expect(structure.blocks.count == 1)
            #expect(structure.blocks[0].heading == "家電製品")
            #expect(structure.blocks[0].itemRows.count == 2)
            #expect(
                RevenueRecognitionTableStructure.stage4ParallelDimensions(
                    in: structure, grid: rows, column: 1, tableTotal: 150
                ).isEmpty)
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
            #expect(RevenueRecognitionCandidates.parallelDimensionsUnresolved(table: table, column: 1))
            let (rows, needsReview) = RevenueRecognitionCandidates.buildRows(table: table, column: 1)
            #expect(needsReview)
            #expect(rows.isEmpty)
        }

        @Test func geographyAndProductHeadingClassification() {
            #expect(RevenueRecognitionTableStructure.isGeographyHeading("地理的区分"))
            #expect(RevenueRecognitionTableStructure.isGeographyHeading("所在地別"))
            #expect(RevenueRecognitionTableStructure.isGeographyHeading("地域別"))
            #expect(RevenueRecognitionTableStructure.isProductOrBusinessHeading("製品及びサービス"))
            #expect(RevenueRecognitionTableStructure.isProductOrBusinessHeading("事業"))
            #expect(!RevenueRecognitionTableStructure.isGeographyHeading("製品及びサービス"))
            #expect(!RevenueRecognitionTableStructure.isProductOrBusinessHeading("地理的区分"))
        }
    }
}
