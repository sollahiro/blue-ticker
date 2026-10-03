// SPEC_ORACLE: 収益分解表の行・列構造（ラベル域・見出しまわり・並行次元）。
// 候補を組む前の検出。ネットワークなし。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RevenueRecognitionTableStructureTests {
    @Test func telSingleLabelColumnTwoParallelDimensionBlocks() throws {
        let html = """
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
        let grid = BreakdownExtractor.expandTable(try XBRLTestSupport.parseFirstTable(html))
        let structure = RevenueRecognitionTableStructure.inspect(grid: grid)
        #expect(structure.labelColumnCount == 1)
        #expect(structure.blocks.count == 2)
        #expect(structure.blocks[0].heading == "地理的区分")
        #expect(structure.blocks[0].kind == .geography)
        #expect(structure.blocks[0].itemRows.count == 7)
        #expect(structure.blocks[1].heading == "製品及びサービス")
        #expect(structure.blocks[1].kind == .productOrBusiness)
        #expect(structure.blocks[1].itemRows.count == 2)
        let parallel = RevenueRecognitionTableStructure.parallelDimensionBlocks(
            in: structure, grid: grid, column: 2, tableTotal: 2_443_533)
        #expect(parallel.count == 2)
        let business = try #require(RevenueRecognitionTableStructure.businessBlock(in: parallel))
        #expect(business.heading == "製品及びサービス")
        #expect(!RevenueRecognitionCandidates.parallelDimensionsUnresolved(
            table: parsed(html), column: 2))
    }

    @Test func densoTwoColumnLabelAreaIsNotParallelDimensions() throws {
        let html = """
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
        let grid = BreakdownExtractor.expandTable(try XBRLTestSupport.parseFirstTable(html))
        let structure = RevenueRecognitionTableStructure.inspect(grid: grid)
        #expect(structure.labelColumnCount == 2)
        #expect(
            RevenueRecognitionTableStructure.parallelDimensionBlocks(
                in: structure, grid: grid, column: 2, tableTotal: 7_161_777
            ).isEmpty)
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
        let grid = BreakdownExtractor.expandTable(try XBRLTestSupport.parseFirstTable(html))
        let structure = RevenueRecognitionTableStructure.inspect(grid: grid)
        #expect(structure.labelColumnCount == 1)
        #expect(structure.blocks.count == 1)
        #expect(structure.blocks[0].heading == "家電製品")
        #expect(structure.blocks[0].itemRows.count == 2)
        #expect(
            RevenueRecognitionTableStructure.parallelDimensionBlocks(
                in: structure, grid: grid, column: 1, tableTotal: 150
            ).isEmpty)
    }

    @Test func twoProductBlocksSameTotalAreUnresolvedParallelDimensions() throws {
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
        let table = parsed(html)
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

    private func parsed(_ html: String) -> RevenueRecognitionCandidates.ParsedTable {
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係")
        return RevenueRecognitionCandidates.parse(tables: tables)[0]
    }
}
